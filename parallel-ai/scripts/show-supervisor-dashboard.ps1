param(
    [string]$Project
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "supervisor-lib.ps1")

if (-not $Project) { $Project = Read-Host "Project slug (or blank to list all)" }

if ($Project) {
    $projectFile = Get-ProjectFile $Project
    if (-not (Test-Path $projectFile)) { throw "Project not found: $Project" }
    $projectData = Ensure-ProjectSchema (Read-JsonFile $projectFile)
    $taskList = @(Get-TaskList $Project)
    $providers = @(Get-DispatchableProviders)
    $usage = Get-ProviderUsage

    Write-Host ""
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host " DASHBOARD: $($projectData.name) ($Project)" -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host "Goal: $($projectData.goal)"
    Write-Host "Workspace: $($projectData.workspace)"
    Write-Host "Status: $($projectData.status)"
    Write-Host "Closeout: $($projectData.closeout.decision)"

    Write-Host ""
    Write-Host "--- Task Summary ---" -ForegroundColor DarkCyan
    $byStatus = $taskList | Group-Object status
    foreach ($group in $byStatus) {
        $color = switch ($group.Name) {
            "done" { "Green" }
            "blocked" { "Red" }
            "dispatched" { "Yellow" }
            "submitted" { "Cyan" }
            "rework" { "Magenta" }
            default { "White" }
        }
        Write-Host "  $($group.Name): $($group.Count)" -ForegroundColor $color
    }

    Write-Host ""
    Write-Host "--- Tasks ---" -ForegroundColor DarkCyan
    foreach ($t in ($taskList | Sort-Object priority, id)) {
        $color = switch ($t.status) {
            "done" { "Green" }
            "blocked" { "Red" }
            "dispatched" { "Yellow" }
            "submitted" { "Cyan" }
            "rework" { "Magenta" }
            default { "White" }
        }
        Write-Host "  [$($t.priority)] $($t.id) [$($t.status)] $($t.title) — owner=$($t.owner) provider=$($t.lastProvider) attempt=$($t.attemptCount)/$($t.maxAttempts)" -ForegroundColor $color
    }

    Write-Host ""
    Write-Host "--- Provider Usage ---" -ForegroundColor DarkCyan
    foreach ($slug in ($usage.providers.PSObject.Properties.Name | Sort-Object)) {
        $entry = $usage.providers.$slug
        Write-Host "  $slug : count=$($entry.dispatchCount) runtime=$($entry.runtimeGroup) cost=$($entry.costTier)"
    }

    Write-Host ""
    Write-Host "--- Available Providers (Dispatchable) ---" -ForegroundColor DarkCyan
    foreach ($provider in ($providers | Sort-Object runtime_group, cost_tier, name)) {
        Write-Host "  [{0}/{1}] {2} : {3}" -f $provider.runtime_group, $provider.cost_tier, $provider.name, $provider.strengths
    }

} else {
    $projects = @(Get-ProjectList)
    Write-Host ""
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host " ALL PROJECTS" -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor Cyan
    if (-not $projects) {
        Write-Host "No projects found."
        exit 0
    }
    foreach ($p in $projects) {
        $tasks = @(Get-TaskList $p.id)
        $done = ($tasks | Where-Object { $_.status -eq "done" }).Count
        $total = $tasks.Count
        Write-Host "  $($p.id) [$($p.status)] $($p.name) — tasks: $done/$total done"
    }
}
