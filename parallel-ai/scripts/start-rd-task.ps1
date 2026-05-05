param(
    [string]$Workspace = (Get-Location).Path,
    [string]$Name = "rd-task",
    [string]$Goal = "Research and development task"
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "supervisor-lib.ps1")

$projectSlug = ConvertTo-Slug $Name
$now = Get-IsoNow

# Create project
& (Join-Path $PSScriptRoot "new-supervisor-project.ps1") -Project $projectSlug -Name $Name -Goal $Goal -Workspace $Workspace

# Create seed task pack
$tasks = @(
    @{
        id = "baseline-comparison"
        title = "Baseline comparison"
        role = "analysis"
        objective = "Analyze the current state of the workspace. Compare against any reference workspace. Identify gaps, risks, and priorities."
        priority = "P0"
        preferredWorkers = @("deepseek")
        fallbackWorkers = @("longcat-flash-thinking-2601", "openrouter-owl-alpha")
        acceptanceCriteria = @(
            "Current state is documented",
            "Key gaps and risks are identified",
            "Priorities are ranked P0-P3"
        )
        allowedPaths = @($Workspace)
        constraints = @("Do not modify any files", "Output analysis only")
    }
    @{
        id = "implementation-plan"
        title = "Implementation plan"
        role = "planning"
        objective = "Based on the baseline comparison, create an implementation plan with concrete steps, estimates, and dependencies."
        priority = "P0"
        preferredWorkers = @("longcat-flash-thinking-2601")
        fallbackWorkers = @("deepseek")
        acceptanceCriteria = @(
            "Plan has concrete actionable steps",
            "Each step has an owner recommendation",
            "Dependencies between steps are documented",
            "Risk mitigation is addressed"
        )
        dependsOn = @("baseline-comparison")
    }
    @{
        id = "execution-lane"
        title = "Execution lane"
        role = "execution"
        objective = "Execute the first implementation step from the plan. Produce a working deliverable."
        priority = "P1"
        preferredWorkers = @("deepseek")
        fallbackWorkers = @("github-gpt-5-mini", "longcat-flash-lite")
        acceptanceCriteria = @(
            "Code changes are functional",
            "Tests pass (if applicable)",
            "Changes are documented"
        )
        dependsOn = @("implementation-plan")
    }
    @{
        id = "review-and-regression"
        title = "Review and regression check"
        role = "review"
        objective = "Review the execution output. Run any existing tests. Check for regressions."
        priority = "P1"
        preferredWorkers = @("github-gpt-5-mini")
        fallbackWorkers = @("github-claude-haiku-4-5", "deepseek")
        acceptanceCriteria = @(
            "All changes reviewed",
            "No regressions found",
            "Review report written"
        )
        dependsOn = @("execution-lane")
    }
)

foreach ($taskDef in $tasks) {
    & (Join-Path $PSScriptRoot "new-supervisor-task.ps1") `
        -Project $projectSlug `
        -TaskId $taskDef.id `
        -Title $taskDef.title `
        -Role $taskDef.role `
        -Objective $taskDef.objective `
        -Priority $taskDef.priority `
        -PreferredWorkers $taskDef.preferredWorkers `
        -FallbackWorkers $taskDef.fallbackWorkers `
        -AcceptanceCriteria $taskDef.acceptanceCriteria `
        -AllowedPaths $taskDef.allowedPaths `
        -Constraints $taskDef.constraints `
        -DependsOn $taskDef.dependsOn
}

Write-Host ""
Write-Host "=== RD Task Pack Created ===" -ForegroundColor Green
Write-Host "Project: $projectSlug"
Write-Host "Tasks: $($tasks.Count)"
Write-Host ""
Write-Host "Next steps:"
Write-Host "  1. Start parallel AI services: start-parallel-ai.ps1"
Write-Host "  2. Open supervisor panel: open-supervisor-panel.ps1"
Write-Host "  3. Dispatch 'baseline-comparison' to DeepSeek"
Write-Host "  4. After baseline done, dispatch 'implementation-plan' to LongCat"
