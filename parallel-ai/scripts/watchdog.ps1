# =============================================================================
# watchdog.ps1 -- Persistent orchestrator loop (fully autonomous)
# =============================================================================
# Usage:
#   powershell -ExecutionPolicy Bypass -File .\watchdog.ps1 -Project my-project
#   powershell -ExecutionPolicy Bypass -File .\watchdog.ps1 -Project my-project -Interval 60
# =============================================================================

param(
    [string]$Project,
    [string]$Workspace = (Get-Location).Path,
    [int]$Interval = 30,
    [int]$MaxRounds = 0,
    [switch]$ForceExpensive
)

$ErrorActionPreference = "Continue"
. (Join-Path $PSScriptRoot "supervisor-lib.ps1")

if (-not $Project) { $Project = Read-Host "Project slug" }

$projectFile = Get-ProjectFile $Project
if (-not (Test-Path $projectFile)) { Write-Host "Project not found: $Project" -ForegroundColor Red; exit 1 }

Write-Host ""
Write-Host "+============================================+" -ForegroundColor Cyan
Write-Host "|  DeepSeek Autolook Watchdog                |" -ForegroundColor Cyan
Write-Host "|  Project: $Project" -ForegroundColor Cyan
Write-Host "|  Interval: ${Interval}s" -ForegroundColor Cyan
Write-Host "+============================================+" -ForegroundColor Cyan
Write-Host ""

$round = 0
while ($true) {
    $round++
    $stamp = Get-Date -Format "HH:mm:ss"

    # Reload project state
    $projectData = Ensure-ProjectSchema (Read-JsonFile $projectFile)
    if ($projectData.status -eq "complete") {
        Write-Host "[$stamp] Project complete. Exiting." -ForegroundColor Green
        break
    }

    # Reload tasks
    $tasks = @(Get-TaskList $Project)
    $ready = @(Get-ReadyDispatchTasks -ProjectSlug $Project)
    $submitted = $tasks | Where-Object { $_.status -eq "submitted" }
    $rework = $tasks | Where-Object { $_.status -eq "rework" -and $_.attemptCount -lt $_.maxAttempts }
    $dispatched = $tasks | Where-Object { $_.status -eq "dispatched" }
    $done = $tasks | Where-Object { $_.status -eq "done" }
    $blocked = $tasks | Where-Object { $_.status -eq "blocked" }

    Write-Host "[$stamp] Round $round | ready=$($ready.Count) submitted=$($submitted.Count) rework=$($rework.Count) dispatched=$($dispatched.Count) done=$($done.Count) blocked=$($blocked.Count)" -ForegroundColor DarkCyan

    $acted = $false

    # 1. Reconcile stale leases
    $staleCount = 0
    foreach ($t in $dispatched) {
        $expiry = Get-TaskLeaseExpiry $t
        if ($expiry -and (Get-Date) -gt $expiry) {
            Write-Host "  [reconcile] $($t.id): stale lease expired" -ForegroundColor Yellow
            $taskFile = Get-TaskFile -ProjectSlug $Project -TaskId $t.id
            $td = Ensure-TaskSchema (Read-JsonFile $taskFile)
            $fp = [string]$td.lastProvider
            $td.status = "ready"
            $td = Clear-TaskLease $td
            $td.notes += ("[$stamp] WATCHDOG: stale lease expired")
            $td = Add-AssignmentHistoryEntry -Task $td -Worker $td.owner -Outcome "stale" -Reason "watchdog-lease-expired"
            Write-JsonFile -Path $taskFile -Data $td
            Clear-LocalLock -Project $Project -Task $t.id
            Register-ProviderFailure -ProviderSlug $fp -Reason "worker-exited"
            $acted = $true
            $staleCount++
        }
    }
    if ($staleCount -gt 0) { Write-Host "  Reconciled $staleCount stale leases" -ForegroundColor Green }

    # 2. Review submitted tasks
    foreach ($t in $submitted) {
        Write-Host "  [review] $($t.id)..." -ForegroundColor DarkGray
        $reportDir = Join-Path (Get-ProjectRoot $Project) "reports"
        $reports = @(Get-ChildItem $reportDir -Filter "$($t.id)--*.md" -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending)
        if ($reports) {
            $reportContent = Get-Content $reports[0].FullName -Raw
            $taskFile = Get-TaskFile -ProjectSlug $Project -TaskId $t.id
            $td = Ensure-TaskSchema (Read-JsonFile $taskFile)
            $reviewResult = Invoke-AutoReview -Project $Project -Task $td -ReportContent $reportContent -ReviewerProvider "github-gpt-5-mini"
            if ($reviewResult) {
                Apply-AutoReviewResult -Project $Project -Task $td -ReviewResult $reviewResult
                Write-Host "    -> $($reviewResult.decision)" -ForegroundColor $(if ($reviewResult.decision -eq "done") { "Green" } else { "Magenta" })
            }
            $acted = $true
        }
    }

    # 3. Redispatch rework tasks
    foreach ($t in $rework) {
        Write-Host "  [redispatch] $($t.id)..." -ForegroundColor DarkGray
        $ws = if ($projectData.workspace) { $projectData.workspace } else { $Workspace }
        $dpArgs = @{
            Project = $Project; Task = $t.id; Workspace = $ws; AutoFallback = $true
        }
        if ($ForceExpensive) { $dpArgs.ForceExpensive = $true }
        try {
            & (Join-Path $PSScriptRoot "open-claude-task.ps1") @dpArgs
            Write-Host "    dispatched" -ForegroundColor Green
        } catch {
            Write-Host "    dispatch failed: $_" -ForegroundColor Red
        }
        $acted = $true
        Start-Sleep -Seconds 1
    }

    # 4. Dispatch ready tasks (one at a time to avoid overloading)
    if ($ready.Count -gt 0) {
        $next = $ready[0]
        Write-Host "  [dispatch] $($next.id) ($($next.priority))..." -ForegroundColor DarkGray
        $ws = if ($projectData.workspace) { $projectData.workspace } else { $Workspace }
        $dpArgs = @{
            Project = $Project; Task = $next.id; Workspace = $ws; AutoFallback = $true
        }
        if ($ForceExpensive) { $dpArgs.ForceExpensive = $true }
        try {
            & (Join-Path $PSScriptRoot "open-claude-task.ps1") @dpArgs
            Write-Host "    dispatched" -ForegroundColor Green
        } catch {
            Write-Host "    dispatch failed: $_" -ForegroundColor Red
        }
        $acted = $true
    }

    # Idle check
    if (-not $acted) {
        if ($ready.Count -eq 0 -and $submitted.Count -eq 0 -and $rework.Count -eq 0 -and $dispatched.Count -eq 0) {
            if ($blocked.Count -gt 0) {
                Write-Host "[$stamp] IDLE: all tasks done or blocked. Waiting for manual unblock." -ForegroundColor Yellow
            } elseif ($done.Count -eq $tasks.Count) {
                Write-Host "[$stamp] ALL DONE: $($done.Count)/$($tasks.Count) tasks complete." -ForegroundColor Green
                break
            } else {
                Write-Host "[$stamp] IDLE: waiting for task state changes." -ForegroundColor DarkGray
            }
        } else {
            Write-Host "[$stamp] WAIT: $($dispatched.Count) dispatched, waiting for completion." -ForegroundColor DarkGray
        }
    }

    # Check exit condition
    if ($MaxRounds -gt 0 -and $round -ge $MaxRounds) {
        Write-Host "Max rounds ($MaxRounds) reached. Exiting." -ForegroundColor Yellow
        break
    }

    Start-Sleep -Seconds $Interval
}

Write-Host ""
Write-Host "Watchdog finished. Run '.\deepseek-autolook.ps1 status' to see final state." -ForegroundColor Cyan
