param(
    [string]$Project,
    [string]$Name,
    [string]$Goal,
    [string]$Workspace = (Get-Location).Path,
    [string]$ReferenceWorkspace = ""
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "supervisor-lib.ps1")

Ensure-SupervisorLayout | Out-Null

if (-not $Project) { $Project = Read-Host "Project slug" }
if (-not $Name) { $Name = Read-Host "Project name" }
if (-not $Goal) { $Goal = Read-Host "Project goal (one line)" }

$projectSlug = ConvertTo-Slug $Project
$projectFile = Get-ProjectFile $projectSlug

if (Test-Path $projectFile) {
    Write-Host "Project already exists: $projectFile" -ForegroundColor Yellow
    $overwrite = Read-Host "Overwrite? (y/N)"
    if ($overwrite -notmatch "^(y|yes)$") {
        exit 0
    }
}

Ensure-ProjectStructure $projectSlug | Out-Null

$now = Get-IsoNow
$projectData = [pscustomobject]@{
    id                 = $projectSlug
    name               = $Name
    goal               = $Goal
    workspace          = $Workspace
    referenceWorkspace = $ReferenceWorkspace
    status             = "active"
    createdAt          = $now
    updatedAt          = $now
    closeout           = [pscustomobject]@{
        decision        = ""
        checkedAt       = ""
        summary         = ""
        incompleteTasks = @()
        blockedTasks    = @()
    }
}

Write-JsonFile -Path $projectFile -Data $projectData
Write-Host "Project created: $projectSlug ($Name)" -ForegroundColor Green
Write-Host "Path: $projectFile"
Write-Host "Slug: $projectSlug  (use this for all task commands)"
