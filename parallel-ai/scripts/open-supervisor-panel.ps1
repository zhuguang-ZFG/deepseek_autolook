param(
    [string]$Project,
    [string]$Workspace = (Get-Location).Path
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "supervisor-lib.ps1")

Ensure-SupervisorLayout | Out-Null

function Select-ProjectInteractive {
    $projects = @(Get-ProjectList)
    if (-not $projects) {
        Write-Host "No supervisor projects found." -ForegroundColor Yellow
        return $null
    }

    Write-Host ""
    Write-Host "Supervisor Projects" -ForegroundColor Cyan
    for ($i = 0; $i -lt $projects.Count; $i++) {
        $item = $projects[$i]
        Write-Host ("[{0}] {1} ({2})" -f ($i + 1), $item.name, $item.id)
    }
    $choice = Read-Host "Choose project index or slug"
    if (-not $choice) { return $null }

    $byIndex = $null
    if ($choice -match "^\d+$") {
        $index = [int]$choice
        if ($index -ge 1 -and $index -le $projects.Count) {
            $byIndex = $projects[$index - 1]
        }
    }
    if ($byIndex) { return $byIndex.id }
    $match = $projects | Where-Object { $_.id -ieq $choice -or $_.name -ieq $choice } | Select-Object -First 1
    if ($match) { return $match.id }
    Write-Host "Unknown project." -ForegroundColor Yellow
    return $null
}

function Show-Tasks {
    param([string]$ProjectSlug)
    $tasks = @(Get-TaskList $ProjectSlug)
    if (-not $tasks) {
        Write-Host "No tasks yet." -ForegroundColor Yellow
        return
    }
    Write-Host ""
    Write-Host ("Tasks for {0}" -f $ProjectSlug) -ForegroundColor Cyan
    foreach ($task in $tasks) {
        Write-Host ("[{0}] {1}" -f $task.id, $task.title) -ForegroundColor White
        Write-Host ("     priority={0} owner={1} status={2} role={3} provider={4}" -f $task.priority, $task.owner, $task.status, $task.role, $task.lastProvider) -ForegroundColor DarkCyan
        if (@($task.preferredWorkers).Count -gt 0 -or @($task.fallbackWorkers).Count -gt 0) {
            Write-Host ("     preferred={0} fallback={1}" -f (@($task.preferredWorkers) -join ","), (@($task.fallbackWorkers) -join ",")) -ForegroundColor DarkGray
        }
    }
}

function Show-DispatchHints {
    $providers = @(Get-DispatchableProviders)
    Write-Host ""
    Write-Host "Dispatch hints" -ForegroundColor Cyan
    foreach ($provider in $providers | Sort-Object runtime_group, cost_tier, name) {
        Write-Host ("- {0} [{1}/{2}] {3}" -f $provider.name, $provider.runtime_group, $provider.cost_tier, $provider.strengths) -ForegroundColor DarkCyan
    }
    Write-Host ("- Cursor [local/manual] editor execution, manual review, hands-on coding") -ForegroundColor DarkCyan
}

if (-not $Project) {
    $Project = Select-ProjectInteractive
}

while ($true) {
    Write-Host ""
    Write-Host "Supervisor Panel" -ForegroundColor Cyan
    Write-Host ("Current project: {0}" -f ($(if ($Project) { $Project } else { "(none)" })))
    Write-Host "[1] Create project"
    Write-Host "[2] Select project"
    Write-Host "[3] List tasks"
    Write-Host "[4] Create task"
    Write-Host "[5] Dispatch task to provider"
    Write-Host "[6] Update task status"
    Write-Host "[7] Submit task for review"
    Write-Host "[8] Review task"
    Write-Host "[9] Show dashboard"
    Write-Host "[10] Reconcile stale/failed tasks"
    Write-Host "[11] Mark task failure"
    Write-Host "[12] Close project check"
    Write-Host "[13] Open project folder"
    Write-Host "[14] Start stable providers only"
    Write-Host "[15] Check provider health"
    Write-Host "[16] Open provider browser"
    Write-Host "[17] Auto-chain (post-task-hook)"
    Write-Host "[18] Launch dashboard (tiled layout)"
    Write-Host "[19] Start hub (DeepSeek TUI as orchestrator)"
    Write-Host "[20] OpenCode dispatch (free agent auto-select)"
    Write-Host "[0] Exit"
    $action = Read-Host "Choose"

    switch ($action) {
        "1" {
            & powershell.exe -NoExit -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot "new-supervisor-project.ps1")
        }
        "2" {
            $selected = Select-ProjectInteractive
            if ($selected) { $Project = $selected }
        }
        "3" {
            if (-not $Project) { Write-Host "Select or create a project first." -ForegroundColor Yellow }
            else { Show-Tasks -ProjectSlug $Project }
        }
        "4" {
            if (-not $Project) { Write-Host "Select or create a project first." -ForegroundColor Yellow }
            else { & powershell.exe -NoExit -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot "new-supervisor-task.ps1") -Project $Project }
        }
        "5" {
            if (-not $Project) { Write-Host "Select or create a project first." -ForegroundColor Yellow }
            else {
                Show-Tasks -ProjectSlug $Project
                Show-DispatchHints
                $taskId = Read-Host "Task ID"
                $provider = Read-Host "Provider slug, name, cursor, or leave blank for auto"
                $forceExpensive = Read-Host "Force expensive provider? (y/N)"
                $preferCursorCli = Read-Host "Prefer cursor CLI mode when using cursor? (Y/n)"
                if ($taskId) {
                    if (-not $provider) {
                        if ($forceExpensive -match "^(y|yes)$") {
                            & (Join-Path $PSScriptRoot "open-claude-task.ps1") -Project $Project -Task $taskId -Workspace $Workspace -AutoFallback -ForceExpensive
                        } else {
                            & (Join-Path $PSScriptRoot "open-claude-task.ps1") -Project $Project -Task $taskId -Workspace $Workspace -AutoFallback
                        }
                    } elseif ($provider -ieq "cursor") {
                        if ($preferCursorCli -match "^(n|no)$") {
                            & (Join-Path $PSScriptRoot "open-cursor-task.ps1") -Project $Project -Task $taskId -Workspace $Workspace
                        } else {
                            & (Join-Path $PSScriptRoot "open-cursor-task.ps1") -Project $Project -Task $taskId -Workspace $Workspace -PreferCli
                        }
                    } else {
                        if ($forceExpensive -match "^(y|yes)$") {
                            & (Join-Path $PSScriptRoot "open-claude-task.ps1") -Project $Project -Task $taskId -Provider $provider -Workspace $Workspace -ForceExpensive
                        } else {
                            & (Join-Path $PSScriptRoot "open-claude-task.ps1") -Project $Project -Task $taskId -Provider $provider -Workspace $Workspace
                        }
                    }
                }
            }
        }
        "6" {
            if (-not $Project) { Write-Host "Select or create a project first." -ForegroundColor Yellow }
            else {
                Show-Tasks -ProjectSlug $Project
                $taskId = Read-Host "Task ID"
                $status = Read-Host "Status (ready/dispatched/submitted/review/rework/done/blocked)"
                $note = Read-Host "Note (optional)"
                if ($taskId -and $status) {
                    & (Join-Path $PSScriptRoot "set-supervisor-task-status.ps1") -Project $Project -Task $taskId -Status $status -Note $note
                }
            }
        }
        "7" {
            if (-not $Project) { Write-Host "Select or create a project first." -ForegroundColor Yellow }
            else {
                Show-Tasks -ProjectSlug $Project
                $taskId = Read-Host "Task ID"
                $worker = Read-Host "Worker"
                $summary = Read-Host "Summary (optional)"
                if ($taskId) {
                    & (Join-Path $PSScriptRoot "submit-supervisor-task.ps1") -Project $Project -Task $taskId -Worker $worker -Summary $summary
                }
            }
        }
        "8" {
            if (-not $Project) { Write-Host "Select or create a project first." -ForegroundColor Yellow }
            else {
                Show-Tasks -ProjectSlug $Project
                $taskId = Read-Host "Task ID"
                if ($taskId) {
                    & (Join-Path $PSScriptRoot "review-supervisor-task.ps1") -Project $Project -Task $taskId
                }
            }
        }
        "9" {
            if (-not $Project) { Write-Host "Select or create a project first." -ForegroundColor Yellow }
            else { & (Join-Path $PSScriptRoot "show-supervisor-dashboard.ps1") -Project $Project }
        }
        "10" {
            if (-not $Project) { Write-Host "Select or create a project first." -ForegroundColor Yellow }
            else {
                $auto = Read-Host "Auto-redispatch recoverable tasks? (y/N)"
                $forceExpensive = Read-Host "Allow expensive fallback while reconciling? (y/N)"
                if ($auto -match "^(y|yes)$") {
                    if ($forceExpensive -match "^(y|yes)$") {
                        & (Join-Path $PSScriptRoot "reconcile-supervisor-tasks.ps1") -Project $Project -Workspace $Workspace -AutoRedispatch -ForceExpensive
                    } else {
                        & (Join-Path $PSScriptRoot "reconcile-supervisor-tasks.ps1") -Project $Project -Workspace $Workspace -AutoRedispatch
                    }
                } else {
                    & (Join-Path $PSScriptRoot "reconcile-supervisor-tasks.ps1") -Project $Project -Workspace $Workspace
                }
            }
        }
        "11" {
            if (-not $Project) { Write-Host "Select or create a project first." -ForegroundColor Yellow }
            else {
                Show-Tasks -ProjectSlug $Project
                $taskId = Read-Host "Task ID"
                $reason = Read-Host "Reason (worker-exited/rate-limited/provider-unavailable/partial-output/local-busy/manual-stop/context-limited/permission-blocked/unknown)"
                $note = Read-Host "Note (optional)"
                $auto = Read-Host "Auto-redispatch now? (y/N)"
                if ($taskId -and $reason) {
                    if ($auto -match "^(y|yes)$") {
                        & (Join-Path $PSScriptRoot "fail-supervisor-task.ps1") -Project $Project -Task $taskId -Reason $reason -Note $note -Workspace $Workspace -AutoRedispatch
                    } else {
                        & (Join-Path $PSScriptRoot "fail-supervisor-task.ps1") -Project $Project -Task $taskId -Reason $reason -Note $note -Workspace $Workspace
                    }
                }
            }
        }
        "12" {
            if (-not $Project) { Write-Host "Select or create a project first." -ForegroundColor Yellow }
            else {
                $apply = Read-Host "Apply project status if complete? (y/N)"
                if ($apply -match "^(y|yes)$") {
                    & (Join-Path $PSScriptRoot "close-supervisor-project.ps1") -Project $Project -ApplyStatus
                } else {
                    & (Join-Path $PSScriptRoot "close-supervisor-project.ps1") -Project $Project
                }
            }
        }
        "13" {
            if (-not $Project) { Write-Host "Select or create a project first." -ForegroundColor Yellow }
            else { Start-Process explorer.exe -ArgumentList (Get-ProjectRoot $Project) }
        }
        "14" {
            & powershell.exe -NoExit -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot "start-stable-providers.ps1")
        }
        "15" {
            & powershell.exe -NoExit -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot "check-stable-providers.ps1")
        }
        "16" {
            & powershell.exe -NoExit -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot "open-provider.ps1") -Workspace $Workspace
        }
        "17" {
            if (-not $Project) { Write-Host "Select or create a project first." -ForegroundColor Yellow }
            else {
                Show-Tasks -ProjectSlug $Project
                $taskId = Read-Host "Task ID"
                $eventType = Read-Host "Event type (task-submitted/task-reviewed/task-failed)"
                if ($taskId -and $eventType) {
                    & (Join-Path $PSScriptRoot "post-task-hook.ps1") -Project $Project -Task $taskId -EventType $eventType -Workspace $Workspace
                }
            }
        }
        "18" {
            & powershell.exe -NoExit -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot "start-dashboard.ps1") -Workspace $Workspace
        }
        "19" {
            & powershell.exe -NoExit -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot "hub.ps1")
        }
        "20" {
            if (-not $Project) { Write-Host "Select or create a project first." -ForegroundColor Yellow }
            else {
                Show-Tasks -ProjectSlug $Project
                $taskId = Read-Host "Task ID"
                if ($taskId) {
                    & (Join-Path $PSScriptRoot "open-opencode-task.ps1") -Project $Project -Task $taskId -Workspace $Workspace -Free
                }
            }
        }
        "0" { exit 0 }
        default { Write-Host "Unknown action." -ForegroundColor Yellow }
    }
}
