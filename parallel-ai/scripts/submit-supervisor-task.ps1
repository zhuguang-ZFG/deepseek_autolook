param(
    [string]$Project,
    [string]$Task,
    [string]$Worker = "",
    [string]$Summary = "",
    [string]$FilesTouched = ""
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
