param(
    [string]$Project,
    [string]$Task,
    [string]$Worker = "",
    [string]$Summary = "",
    [string]$FilesTouched = "",
    [switch]$AutoReview,
    [string]$ReviewerProvider = "github-gpt-5-mini"
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "supervisor-lib.ps1")

if (-not $Project) { $Project = Read-Host "Project slug" }
if (-not $Task) { $Task = Read-Host "Task ID" }
if (-not $Worker) { $Worker = Read-Host "Worker (provider slug)" }

$taskFile = Get-TaskFile -ProjectSlug $Project -TaskId $Task
if (-not (Test-Path $taskFile)) { throw "Task not found: $taskFile" }

$taskData = Ensure-TaskSchema (Read-JsonFile $taskFile)

if ($taskData.status -notin @("dispatched", "rework")) {
    Write-Host "Warning: task is in '$($taskData.status)' status, expected 'dispatched' or 'rework'" -ForegroundColor Yellow
}

$taskData.status = "submitted"
$taskData.updatedAt = Get-IsoNow
$taskData = Clear-TaskLease $taskData
$taskData.notes = @($taskData.notes) + ("[" + (Get-IsoNow) + "] submitted by " + $Worker + " | " + $Summary)

Write-JsonFile -Path $taskFile -Data $taskData
Clear-LocalLock -Project $Project -Task $Task
Write-SupervisorEvent -Type "task-submitted" -Project $Project -Task $Task -Worker $Worker -Status "submitted" -Summary $Summary -FilesTouched $FilesTouched | Out-Null
Write-Host "Task $Task submitted for review" -ForegroundColor Green

# Auto-review: read the latest report and dispatch a reviewer
if ($AutoReview) {
    $reportDir = Join-Path (Get-ProjectRoot $Project) "reports"
    $reports = @(Get-ChildItem $reportDir -Filter "$Task--*.md" -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending)
    if ($reports) {
        $reportContent = Get-Content $reports[0].FullName -Raw
        $reviewResult = Invoke-AutoReview -Project $Project -Task $taskData -ReportContent $reportContent -ReviewerProvider $ReviewerProvider
        if ($reviewResult) {
            Apply-AutoReviewResult -Project $Project -Task $taskData -ReviewResult $reviewResult
        }
        else {
            Write-Host "Auto-review returned no result. Task remains 'submitted' for manual review." -ForegroundColor Yellow
        }
    }
    else {
        Write-Host "Auto-review skipped: no report found for task $Task" -ForegroundColor Yellow
    }
}
