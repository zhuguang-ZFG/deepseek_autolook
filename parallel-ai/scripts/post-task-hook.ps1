param(
  [string]$Project,
  [string]$Task,
  [string]$EventType,
  [string]$Worker,
  [string]$Summary,
  [string]$FilesTouched,
  [string]$Workspace,
  [switch]$ForceExpensive
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "supervisor-lib.ps1")

if (-not $Project) { throw "Project is required." }
if (-not $Task) { throw "Task is required." }
if (-not $EventType) { throw "EventType is required." }

$taskFile = Get-TaskFile -ProjectSlug $Project -TaskId $Task
if (-not (Test-Path $taskFile)) { throw "Task not found: $taskFile" }

$taskData = Ensure-TaskSchema (Read-JsonFile $taskFile)
$projectData = Ensure-ProjectSchema (Read-JsonFile (Get-ProjectFile $Project))

function Invoke-TaskReview {
  param([string]$ProjectSlug, [string]$TaskId)
  & (Join-Path $PSScriptRoot "review-supervisor-task.ps1") -Project $ProjectSlug -Task $TaskId -AutoReview | Out-Null
}

function Invoke-Reconcile {
  param([string]$ProjectSlug, [string]$ResolvedWorkspace)
  $args = @{ Project = $ProjectSlug }
  if (-not [string]::IsNullOrWhiteSpace($ResolvedWorkspace)) { $args["Workspace"] = $ResolvedWorkspace }
  if ($ForceExpensive) { $args["ForceExpensive"] = $true }
  & (Join-Path $PSScriptRoot "reconcile-supervisor-tasks.ps1") @args | Out-Null
}

function Invoke-NextDispatch {
  param([string]$ProjectSlug, [string]$ResolvedWorkspace)
  $readyTasks = @(Get-ReadyDispatchTasks -ProjectSlug $ProjectSlug)
  if ($readyTasks.Count -eq 0) { return $null }
  $nextTask = $readyTasks[0]
  $dispatchArgs = @{ Project = $ProjectSlug; Task = $nextTask.id; AutoFallback = $true }
  if (-not [string]::IsNullOrWhiteSpace($ResolvedWorkspace)) { $dispatchArgs["Workspace"] = $ResolvedWorkspace }
  if ($ForceExpensive) { $dispatchArgs["ForceExpensive"] = $true }
  & (Join-Path $PSScriptRoot "open-claude-task.ps1") @dispatchArgs | Out-Null
  return $nextTask.id
}

$resolvedWorkspace = if ($Workspace) { $Workspace } elseif ($projectData.workspace) { $projectData.workspace } else { "" }
$dispatchedTask = $null

switch ($EventType) {
  "task-submitted" {
    if ($taskData.status -eq "submitted") {
      Invoke-TaskReview -ProjectSlug $Project -TaskId $Task
      $taskData = Ensure-TaskSchema (Read-JsonFile $taskFile)
    }
    Invoke-Reconcile -ProjectSlug $Project -ResolvedWorkspace $resolvedWorkspace
    $taskData = Ensure-TaskSchema (Read-JsonFile $taskFile)
    if ($taskData.status -eq "done") {
      $dispatchedTask = Invoke-NextDispatch -ProjectSlug $Project -ResolvedWorkspace $resolvedWorkspace
    }
  }
  "task-reviewed" {
    Invoke-Reconcile -ProjectSlug $Project -ResolvedWorkspace $resolvedWorkspace
    $taskData = Ensure-TaskSchema (Read-JsonFile $taskFile)
    if ($taskData.status -eq "done") {
      $dispatchedTask = Invoke-NextDispatch -ProjectSlug $Project -ResolvedWorkspace $resolvedWorkspace
    }
  }
  "task-failed" {
    Invoke-Reconcile -ProjectSlug $Project -ResolvedWorkspace $resolvedWorkspace
    if ($taskData.status -eq "ready") {
      $dispatchedTask = Invoke-NextDispatch -ProjectSlug $Project -ResolvedWorkspace $resolvedWorkspace
    }
  }
}

if ($dispatchedTask) {
  $extra = @{ sourceEvent = $EventType; sourceTask = $Task }
  Write-SupervisorEvent -Type "task-auto-dispatched" -Project $Project -Task $dispatchedTask -Worker "" -Status "dispatched" -Summary ("auto-dispatched after " + $EventType) -FilesTouched "" -Extra $extra | Out-Null
  try {
    & (Join-Path $PSScriptRoot "invoke-task-desktop-alert.ps1") `
      -Title "DeepSeek Autolook Next Task" `
      -Message ("Task {0} finished review flow. Auto-dispatched next task: {1}" -f $Task, $dispatchedTask) `
      -TimeoutSeconds 8
  } catch {
    Write-Host ("Next-task alert failed: " + $_.Exception.Message) -ForegroundColor Yellow
  }
  Write-Host ("Post-hook dispatched next task: {0}" -f $dispatchedTask) -ForegroundColor Green
} else {
  Write-Host ("Post-hook complete: {0}/{1} event={2}" -f $Project, $Task, $EventType) -ForegroundColor DarkCyan
}
