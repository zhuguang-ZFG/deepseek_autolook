param(
    [string]$Project,
    [string]$Task,
    [string]$Reason = "unknown",
    [string]$Note = "",
    [string]$Workspace = "",
    [switch]$AutoRedispatch
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "supervisor-lib.ps1")

if (-not $Project) { $Project = Read-Host "Project slug" }
if (-not $Task) { $Task = Read-Host "Task ID" }
if (-not $Reason) { $Reason = Read-Host "Reason (worker-exited/rate-limited/provider-unavailable/partial-output/local-busy/manual-stop/context-limited/permission-blocked/unknown)" }

$taskFile = Get-TaskFile -ProjectSlug $Project -TaskId $Task
if (-not (Test-Path $taskFile)) { throw "Task not found: $taskFile" }

$taskData = Ensure-TaskSchema (Read-JsonFile $taskFile)
$failedProviderSlug = [string]$taskData.lastProvider

$taskData.status = "ready"
$taskData.updatedAt = Get-IsoNow
$taskData.lastFailureReason = $Reason
$taskData.lastRecoveredAt = Get-IsoNow
$taskData = Clear-TaskLease $taskData

$noteText = if ($Note) { $Note } else { "failure: " + $Reason }
$taskData.notes = @($taskData.notes) + ("[" + (Get-IsoNow) + "] FAILED: " + $noteText)
$taskData = Add-AssignmentHistoryEntry -Task $taskData -Worker $taskData.owner -Outcome "failed" -Reason $Reason

Write-JsonFile -Path $taskFile -Data $taskData
Clear-LocalLock -Project $Project -Task $Task
Register-ProviderFailure -ProviderSlug $failedProviderSlug -Reason $Reason
Write-SupervisorEvent -Type "task-failed" -Project $Project -Task $Task -Worker $taskData.owner -Status "failed" -Summary $Reason -FilesTouched "" | Out-Null
Write-Host "Task $Task marked as failed ($Reason)" -ForegroundColor Yellow

if ($AutoRedispatch -and $taskData.attemptCount -lt $taskData.maxAttempts) {
    Write-Host "Auto-redispatching task $Task..." -ForegroundColor Green
    $provider = if ($taskData.lastProvider) { $taskData.lastProvider } else { "" }
    & (Join-Path $PSScriptRoot "open-claude-task.ps1") -Project $Project -Task $Task -Provider $provider -Workspace $Workspace -AutoFallback
} elseif ($AutoRedispatch) {
    Write-Host "Max attempts ($($taskData.maxAttempts)) reached for task $Task. Will not auto-redispatch." -ForegroundColor Red
}
