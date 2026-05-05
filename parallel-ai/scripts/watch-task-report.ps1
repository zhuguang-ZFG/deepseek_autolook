param(
  [string]$Project,
  [string]$Task,
  [string]$ReportPath,
  [string]$Worker,
  [string]$NotBefore,
  [int]$PollSeconds = 5,
  [int]$TimeoutMinutes = 180
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "supervisor-lib.ps1")

if (-not $Project) { throw "Project is required." }
if (-not $Task) { throw "Task is required." }
if (-not $ReportPath) { throw "ReportPath is required." }
if (-not $Worker) { $Worker = "cursor" }

$deadline = (Get-Date).AddMinutes($TimeoutMinutes)
$notBeforeTime = Get-DateOrNull $NotBefore
$lastSize = -1
$stableCount = 0
$notifyScript = Join-Path $PSScriptRoot "invoke-task-desktop-alert.ps1"

while ((Get-Date) -lt $deadline) {
  $taskFile = Get-TaskFile -ProjectSlug $Project -TaskId $Task
  if (-not (Test-Path $taskFile)) { exit 0 }
  $taskData = Ensure-TaskSchema (Read-JsonFile $taskFile)
  if ($taskData.status -notin @("dispatched", "submitted")) { exit 0 }

  if (Test-Path $ReportPath) {
    $item = Get-Item $ReportPath
    $writeOk = $true
    if ($notBeforeTime) { $writeOk = $item.LastWriteTime -ge $notBeforeTime }
    if ($writeOk) {
      if ($item.Length -gt 0 -and $item.Length -eq $lastSize) { $stableCount++ } else { $stableCount = 0 }
      $lastSize = $item.Length

      if ($item.Length -gt 0 -and $stableCount -ge 1) {
        & (Join-Path $PSScriptRoot "submit-supervisor-task.ps1") -Project $Project -Task $Task -Worker $Worker -Summary "report-detected-by-watcher" -AutoReview
        exit 0
      }
    }
  }

  Start-Sleep -Seconds $PollSeconds
}

try {
  if (Test-Path $notifyScript) {
    & $notifyScript `
      -Title "DeepSeek Autolook Timeout" `
      -Message ("Task {0} ({1}) timed out waiting for a report from {2}." -f $Task, $Project, $Worker) `
      -TimeoutSeconds 10
  }
} catch {
  Write-Host ("Timeout alert failed: " + $_.Exception.Message) -ForegroundColor Yellow
}
