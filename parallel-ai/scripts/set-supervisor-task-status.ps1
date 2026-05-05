param(
    [string]$Project,
    [string]$Task,
    [string]$Status,
    [string]$Note = ""
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "supervisor-lib.ps1")

if (-not $Project) { $Project = Read-Host "Project slug" }
if (-not $Task) { $Task = Read-Host "Task ID" }
if (-not $Status) { $Status = Read-Host "Status (ready/dispatched/submitted/review/rework/done/blocked)" }

$taskFile = Get-TaskFile -ProjectSlug $Project -TaskId $Task
if (-not (Test-Path $taskFile)) {
    throw "Task not found: $taskFile"
}

$taskData = Ensure-TaskSchema (Read-JsonFile $taskFile)
$oldStatus = $taskData.status
$taskData.status = $Status
$taskData.updatedAt = Get-IsoNow

if ($Note) {
    $taskData.notes = @($taskData.notes) + ("[" + (Get-IsoNow) + "] status: " + $oldStatus + " -> " + $Status + " | " + $Note)
}

# If marked done, clear the lease
if ($Status -eq "done") {
    $taskData = Clear-TaskLease $taskData
    $taskData.lastRecoveredAt = Get-IsoNow
}

# If marked blocked, clear the lease
if ($Status -eq "blocked") {
    $taskData = Clear-TaskLease $taskData
}

# If re-dispatched, start a new lease
if ($Status -eq "ready") {
    $taskData = Clear-TaskLease $taskData
    $taskData.lastFailureReason = ""
    $taskData.attemptCount = 0
}

Write-JsonFile -Path $taskFile -Data $taskData
Write-SupervisorEvent -Type "status-change" -Project $Project -Task $Task -Worker $taskData.owner -Status $Status -Summary ($oldStatus + " -> " + $Status) -FilesTouched "" | Out-Null
Write-Host "Task $Task : $oldStatus -> $Status" -ForegroundColor Green
