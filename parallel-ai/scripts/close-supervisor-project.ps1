param(
    [string]$Project,
    [switch]$ApplyStatus
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "supervisor-lib.ps1")

if (-not $Project) { $Project = Read-Host "Project slug" }

$projectFile = Get-ProjectFile $Project
if (-not (Test-Path $projectFile)) { throw "Project not found: $projectFile" }

$projectData = Ensure-ProjectSchema (Read-JsonFile $projectFile)
$taskList = @(Get-TaskList $Project)

Write-Host ""
Write-Host "=== Closeout Check: $($projectData.name) ($Project) ===" -ForegroundColor Cyan

$incomplete = @()
$blocked = @()
$done = @()

foreach ($taskData in $taskList) {
    switch ($taskData.status) {
        "done" { $done += $taskData }
        "blocked" { $blocked += $taskData }
        default { $incomplete += $taskData }
    }
}

Write-Host ""
Write-Host "Done: $($done.Count)"
Write-Host "Blocked: $($blocked.Count)"
Write-Host "Incomplete: $($incomplete.Count)"

if ($incomplete.Count -gt 0) {
    Write-Host ""
    Write-Host "Incomplete tasks:" -ForegroundColor Yellow
    foreach ($t in $incomplete) {
        Write-Host "  [$($t.priority)] $($t.id): $($t.title) — $($t.status)" -ForegroundColor Yellow
    }
}

if ($blocked.Count -gt 0) {
    Write-Host ""
    Write-Host "Blocked tasks:" -ForegroundColor Red
    foreach ($t in $blocked) {
        Write-Host "  [$($t.priority)] $($t.id): $($t.title)" -ForegroundColor Red
    }
}

$p0Incomplete = $incomplete | Where-Object { $_.priority -eq "P0" }
$p1Incomplete = $incomplete | Where-Object { $_.priority -eq "P1" }

$canClose = ($p0Incomplete.Count -eq 0) -and ($p1Incomplete.Count -eq 0) -and ($blocked.Count -eq 0)

$projectData.closeout = [pscustomobject]@{
    decision        = if ($canClose) { "complete" } else { "open" }
    checkedAt       = Get-IsoNow
    summary         = "done=$($done.Count) blocked=$($blocked.Count) incomplete=$($incomplete.Count)"
    incompleteTasks = @($incomplete | ForEach-Object { $_.id })
    blockedTasks    = @($blocked | ForEach-Object { $_.id })
}
$projectData.updatedAt = Get-IsoNow

if ($ApplyStatus -and $canClose) {
    $projectData.status = "complete"
    Write-Host ""
    Write-Host "Project marked as COMPLETE" -ForegroundColor Green
} elseif ($ApplyStatus -and -not $canClose) {
    Write-Host ""
    Write-Host "Cannot close: P0/P1 tasks remain incomplete or blocked tasks exist." -ForegroundColor Red
    if ($p0Incomplete.Count -gt 0) {
        Write-Host "P0 incomplete: $($p0Incomplete.Count)"
    }
    if ($p1Incomplete.Count -gt 0) {
        Write-Host "P1 incomplete: $($p1Incomplete.Count)"
    }
} else {
    Write-Host ""
    if ($canClose) {
        Write-Host "All P0/P1 tasks are done. Project can be closed." -ForegroundColor Green
        Write-Host "Run with -ApplyStatus to mark as complete."
    } else {
        Write-Host "Project cannot be closed yet. Resolve P0/P1 tasks first." -ForegroundColor Yellow
    }
}

Write-JsonFile -Path $projectFile -Data $projectData
