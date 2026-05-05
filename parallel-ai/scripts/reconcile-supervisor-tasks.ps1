param(
    [string]$Project,
    [string]$Workspace = "",
    [switch]$AutoRedispatch,
    [switch]$ForceExpensive
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "supervisor-lib.ps1")

if (-not $Project) { $Project = Read-Host "Project slug" }

$taskList = @(Get-TaskList $Project)
if (-not $taskList) {
    Write-Host "No tasks found for project $Project." -ForegroundColor Yellow
    exit 0
}

Write-Host ""
Write-Host "=== Reconciling tasks for $Project ===" -ForegroundColor Cyan

$now = Get-Date
$staleTasks = @()
$failedTasks = @()

foreach ($taskData in $taskList) {
    Write-Host ""
    Write-Host "--- $($taskData.id): $($taskData.title) [status=$($taskData.status)] ---"

    # Check for stale leases
    if ($taskData.status -eq "dispatched") {
        $expiry = Get-TaskLeaseExpiry $taskData
        if ($expiry -and $now -gt $expiry) {
            Write-Host "  STALE: lease expired at $expiry, $($taskData.owner) on $($taskData.lastProvider)" -ForegroundColor Yellow
            $taskData.status = "ready"
            $taskData.updatedAt = Get-IsoNow
            $taskData = Clear-TaskLease $taskData
            $taskData = Add-AssignmentHistoryEntry -Task $taskData -Worker $taskData.owner -Outcome "stale" -Reason "lease-expired"
            $taskData.notes = @($taskData.notes) + ("[" + (Get-IsoNow) + "] RECONCILED: stale lease expired")
            $failedProviderSlug = [string]$taskData.lastProvider
            $taskFile = Get-TaskFile -ProjectSlug $Project -TaskId $taskData.id
            Write-JsonFile -Path $taskFile -Data $taskData
            Clear-LocalLock -Project $Project -Task $taskData.id
            Register-ProviderFailure -ProviderSlug $failedProviderSlug -Reason "worker-exited"
            Write-SupervisorEvent -Type "task-reconciled" -Project $Project -Task $taskData.id -Worker $taskData.owner -Status "stale" -Summary "lease-expired" -FilesTouched "" | Out-Null
            $staleTasks += $taskData
        } else {
            Write-Host "  OK: lease active, expires at $expiry"
        }
    }

    # Check for tasks that need redispatch
    if ($taskData.status -eq "ready" -and $taskData.lastFailureReason) {
        $failedTasks += $taskData
    }
}

Write-Host ""
Write-Host "=== Summary ===" -ForegroundColor Cyan
Write-Host "Stale tasks cleared: $($staleTasks.Count)"
Write-Host "Failed tasks ready for retry: $($failedTasks.Count)"

if ($AutoRedispatch -and $failedTasks.Count -gt 0) {
    Write-Host ""
    Write-Host "Auto-redispatching failed tasks..." -ForegroundColor Green
    foreach ($taskData in $failedTasks) {
        if ($taskData.attemptCount -ge $taskData.maxAttempts) {
            Write-Host "  SKIP $($taskData.id): max attempts ($($taskData.maxAttempts)) reached" -ForegroundColor Red
            continue
        }
        Write-Host "  DISPATCH $($taskData.id)..." -ForegroundColor Green
        try {
            & (Join-Path $PSScriptRoot "open-claude-task.ps1") -Project $Project -Task $taskData.id -Workspace $Workspace -AutoFallback -ForceExpensive:$ForceExpensive
        } catch {
            Write-Host "  FAILED to dispatch $($taskData.id): $_" -ForegroundColor Red
        }
    }
}
