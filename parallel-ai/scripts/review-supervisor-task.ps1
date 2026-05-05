param(
    [string]$Project,
    [string]$Task
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "supervisor-lib.ps1")

if (-not $Project) { $Project = Read-Host "Project slug" }
if (-not $Task) { $Task = Read-Host "Task ID" }

$taskFile = Get-TaskFile -ProjectSlug $Project -TaskId $Task
if (-not (Test-Path $taskFile)) { throw "Task not found: $taskFile" }

$taskData = Ensure-TaskSchema (Read-JsonFile $taskFile)

Write-Host ""
Write-Host "=== Review: $($taskData.id) — $($taskData.title) ===" -ForegroundColor Cyan
Write-Host "Status: $($taskData.status)"
Write-Host "Role: $($taskData.role)"
Write-Host "Owner: $($taskData.owner)"
Write-Host "Priority: $($taskData.priority)"
Write-Host "Attempt: $($taskData.attemptCount)/$($taskData.maxAttempts)"
Write-Host ""

if ($taskData.acceptanceCriteria) {
    Write-Host "--- Acceptance Criteria ---" -ForegroundColor DarkCyan
    foreach ($c in $taskData.acceptanceCriteria) {
        Write-Host "  [ ] $c"
    }
    Write-Host ""
}

Write-Host "--- Reports ---" -ForegroundColor DarkCyan
$reportDir = Join-Path (Get-ProjectRoot $Project) "reports"
$reports = Get-ChildItem $reportDir -Filter "$Task--*.md" -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending
if ($reports) {
    foreach ($report in $reports) {
        Write-Host ""
        Write-Host "  === $($report.Name) ===" -ForegroundColor Yellow
        Write-Host (Get-Content $report.FullName -Raw)
        Write-Host ""
        Write-Host "  --- End $($report.Name) ---" -ForegroundColor Yellow
    }
} else {
    Write-Host "  No reports found." -ForegroundColor Yellow
}

Write-Host ""
Write-Host "--- Assignment History ---" -ForegroundColor DarkCyan
foreach ($entry in $taskData.assignmentHistory) {
    Write-Host "  $($entry.at) | $($entry.worker) | $($entry.outcome) | $($entry.reason)"
}

Write-Host ""
Write-Host "--- Notes ---" -ForegroundColor DarkCyan
foreach ($note in $taskData.notes) {
    Write-Host "  $note"
}

Write-Host ""
$decision = Read-Host "Decision (done/rework/blocked/leave)"
if (-not $decision) { exit 0 }

$summary = ""
if ($decision -eq "done") {
    $summary = Read-Host "Review summary (optional)"
    $missing = Read-Host "Missing criteria (comma-separated, optional)"
    $taskData.status = "done"
    $taskData.review = [pscustomobject]@{
        decision        = "done"
        reviewedAt      = Get-IsoNow
        reviewer        = "manual"
        summary         = $summary
        missingCriteria = @(($missing -split "," | ForEach-Object { $_.Trim() } | Where-Object { $_ }))
    }
} elseif ($decision -eq "rework") {
    $summary = Read-Host "Rework notes"
    $taskData.status = "rework"
    $taskData.review = [pscustomobject]@{
        decision        = "rework"
        reviewedAt      = Get-IsoNow
        reviewer        = "manual"
        summary         = $summary
        missingCriteria = @()
    }
} elseif ($decision -eq "blocked") {
    $summary = Read-Host "Block reason"
    $taskData.status = "blocked"
} else {
    Write-Host "No change made."
    exit 0
}

$taskData.updatedAt = Get-IsoNow
Write-JsonFile -Path $taskFile -Data $taskData
Clear-LocalLock -Project $Project -Task $Task
Write-SupervisorEvent -Type "task-reviewed" -Project $Project -Task $Task -Worker $taskData.owner -Status $decision -Summary $summary -FilesTouched "" | Out-Null
Write-Host "Task $Task -> $decision" -ForegroundColor Green
