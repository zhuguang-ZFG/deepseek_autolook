param(
    [string]$Project,
    [string]$TaskId,
    [string]$Title,
    [string]$Role = "worker",
    [string]$Objective = "",
    [string]$Priority = "P1",
    [string]$Owner = "",
    [string]$ExpectedOutput = "report",
    [string[]]$AcceptanceCriteria = @(),
    [string[]]$AllowedPaths = @(),
    [string[]]$DependsOn = @(),
    [string[]]$Constraints = @(),
    [string[]]$ContextFiles = @(),
    [string[]]$ReferenceAnchors = @(),
    [string[]]$SupervisorNotes = @(),
    [string[]]$PreferredWorkers = @(),
    [string[]]$FallbackWorkers = @()
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "supervisor-lib.ps1")

if (-not $Project) { $Project = Read-Host "Project slug" }
if (-not $TaskId) { $TaskId = Read-Host "Task ID (slug)" }
if (-not $Title) { $Title = Read-Host "Task title" }
if (-not $Objective) { $Objective = Read-Host "Objective (one line)" }

$projectFile = Get-ProjectFile $Project
if (-not (Test-Path $projectFile)) {
    throw "Project not found: $Project. Create it first with new-supervisor-project.ps1"
}

$taskSlug = ConvertTo-Slug $TaskId
$taskFile = Get-TaskFile -ProjectSlug $Project -TaskId $taskSlug

if (Test-Path $taskFile) {
    Write-Host "Task already exists: $taskFile" -ForegroundColor Yellow
    $overwrite = Read-Host "Overwrite? (y/N)"
    if ($overwrite -notmatch "^(y|yes)$") {
        exit 0
    }
}

$now = Get-IsoNow
$taskData = [pscustomobject]@{
    id                 = $taskSlug
    title              = $Title
    role               = $Role
    objective          = $Objective
    priority           = $Priority
    owner              = $Owner
    expectedOutput     = $ExpectedOutput
    status             = "ready"
    acceptanceCriteria = @($AcceptanceCriteria)
    allowedPaths       = @($AllowedPaths)
    dependsOn          = @($DependsOn)
    constraints        = @($Constraints)
    contextFiles       = @($ContextFiles)
    referenceAnchors   = @($ReferenceAnchors)
    supervisorNotes    = @($SupervisorNotes)
    preferredWorkers   = @($PreferredWorkers)
    fallbackWorkers    = @($FallbackWorkers)
    createdAt          = $now
    updatedAt          = $now
}
$taskData = Ensure-TaskSchema $taskData

Write-JsonFile -Path $taskFile -Data $taskData
Write-Host "Task created: $taskSlug ($Title)" -ForegroundColor Green
Write-Host "  Project: $Project"
Write-Host "  Priority: $Priority"
Write-Host "  Status: ready"
Write-Host "  Workers: preferred=$PreferredWorkers fallback=$FallbackWorkers"
