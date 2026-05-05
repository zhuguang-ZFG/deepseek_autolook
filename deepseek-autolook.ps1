# =============================================================================
# deepseek-autolook.ps1 -- Top-level entry point / One-command bootstrap
# =============================================================================
# Usage:
#   powershell -ExecutionPolicy Bypass -File .\deepseek-autolook.ps1
#   powershell -ExecutionPolicy Bypass -File .\deepseek-autolook.ps1 status
#   powershell -ExecutionPolicy Bypass -File .\deepseek-autolook.ps1 rd -Name fix-bug
# =============================================================================

param(
    [Parameter(Position = 0)]
    [ValidateSet("sync","start","stop","status","dashboard","hub","panel","rd","verify","check","clean","help")]
    [string]$Command = "help",
    [string]$Project,
    [string]$Workspace = (Get-Location).Path,
    [string]$Name
)

$ErrorActionPreference = "Continue"
$Root = $PSScriptRoot
$ScriptsDir = Join-Path $Root "parallel-ai\scripts"

# ---- prerequisite check ----------------------------------------------------
function Test-Prerequisites {
    $ok = $true
    if (-not (Get-Command python -ErrorAction SilentlyContinue)) {
        Write-Host "[FAIL] Python not found (need C:\Python311\python.exe)" -ForegroundColor Red
        $ok = $false
    } else { Write-Host "[ OK ] Python" -ForegroundColor Green }
    if (-not (Get-Command claude -ErrorAction SilentlyContinue)) {
        Write-Host "[FAIL] claude not found" -ForegroundColor Red
        $ok = $false
    } else { Write-Host "[ OK ] claude" -ForegroundColor Green }
    $ccDb = "$env:USERPROFILE\.cc-switch\cc-switch.db"
    if (Test-Path $ccDb) { Write-Host "[ OK ] cc-switch.db" -ForegroundColor Green }
    else { Write-Host "[WARN] cc-switch.db not found" -ForegroundColor Yellow }
    return $ok
}

# ---- command implementations ------------------------------------------------
function Invoke-Sync {
    & C:\Python311\python.exe (Join-Path $ScriptsDir "sync-parallel-providers.py")
}
function Invoke-Start {
    Invoke-Sync
    & powershell.exe -ExecutionPolicy Bypass -File (Join-Path $ScriptsDir "start-stable-providers.ps1")
}
function Invoke-Dashboard {
    & powershell.exe -NoExit -ExecutionPolicy Bypass -File (Join-Path $ScriptsDir "start-dashboard.ps1") -Workspace $Workspace
}
function Invoke-Hub {
    $a = @(); if ($Project) { $a += "-Project", $Project }
    & powershell.exe -NoExit -ExecutionPolicy Bypass -File (Join-Path $ScriptsDir "hub.ps1") @a
}
function Invoke-RD {
    $a = @("-Workspace", $Workspace); if ($Name) { $a += "-Name", $Name }
    & powershell.exe -NoExit -ExecutionPolicy Bypass -File (Join-Path $ScriptsDir "start-rd-task.ps1") @a
}
function Invoke-Verify {
    Invoke-Sync | Out-Null
    & powershell.exe -ExecutionPolicy Bypass -File (Join-Path $ScriptsDir "verify-parallel-ai.ps1")
}
function Invoke-Stop {
    & powershell.exe -ExecutionPolicy Bypass -File (Join-Path $ScriptsDir "stop-parallel-ai.ps1")
}
function Invoke-Panel {
    & powershell.exe -NoExit -ExecutionPolicy Bypass -File (Join-Path $ScriptsDir "open-supervisor-panel.ps1") -Workspace $Workspace
}
function Invoke-Check {
    & powershell.exe -ExecutionPolicy Bypass -File (Join-Path $ScriptsDir "check-isolation.ps1")
}
function Invoke-Clean {
    Write-Host "Stopping proxies..." -ForegroundColor Cyan
    & powershell.exe -ExecutionPolicy Bypass -File (Join-Path $ScriptsDir "stop-parallel-ai.ps1") | Out-Null
    Write-Host "Removing runtime state..." -ForegroundColor Yellow
    foreach ($d in @("settings","logs","tasks\runtime","tasks\projects")) {
        $p = Join-Path $Root "parallel-ai\$d"
        if (Test-Path $p) { Remove-Item $p -Recurse -Force -ErrorAction SilentlyContinue }
    }
    Get-ChildItem (Join-Path $Root "parallel-ai\scripts\open-claude-*.ps1") -ErrorAction SilentlyContinue | Remove-Item -Force
    Get-ChildItem (Join-Path $Root "parallel-ai\scripts\parallel-*.cmd") -ErrorAction SilentlyContinue | Remove-Item -Force
    Remove-Item (Join-Path $Root "parallel-ai\providers.manifest.json") -Force -ErrorAction SilentlyContinue
    Write-Host "Done. Run 'sync' to rebuild." -ForegroundColor Green
}

function Invoke-Status {
    Write-Host ""
    Write-Host "=== DeepSeek Autolook Status ===" -ForegroundColor Cyan

    # Provider manifest
    $manifestPath = Join-Path $Root "parallel-ai\providers.manifest.json"
    if (Test-Path $manifestPath) {
        $manifest = Get-Content $manifestPath -Raw | ConvertFrom-Json
        Write-Host "Providers: $($manifest.providers.Count) configured" -ForegroundColor Green

        $running = @()
        $ports = @($manifest.providers | ForEach-Object { [int]$_.port })
        $connections = Get-NetTCPConnection -State Listen -LocalPort $ports -ErrorAction SilentlyContinue
        foreach ($p in $manifest.providers) {
            $up = $connections | Where-Object { $_.LocalPort -eq [int]$p.port }
            $icon = if ($up) { "[UP]" } else { "[--]" }
            $color = if ($up) { "Green" } else { "DarkGray" }
            Write-Host "  $icon $($p.name) :$($p.port) [$($p.stability_tier)/$($p.cost_tier)]" -ForegroundColor $color
            if ($up) { $running += $p }
        }
        Write-Host "Running: $($running.Count)/$($manifest.providers.Count)" -ForegroundColor $(if ($running.Count -gt 0) { "Green" } else { "Yellow" })

        $stable = @($manifest.providers | Where-Object { $_.stable_candidate })
        $stableUp = @($running | Where-Object { $_.stable_candidate })
        Write-Host "Stable: $($stableUp.Count)/$($stable.Count) up" -ForegroundColor $(if ($stableUp.Count -eq $stable.Count) { "Green" } else { "Yellow" })
    } else {
        Write-Host "No manifest found. Run 'sync' first." -ForegroundColor Yellow
    }

    # Projects
    Write-Host ""
    Write-Host "=== Projects ===" -ForegroundColor Cyan
    $projectsDir = Join-Path $Root "parallel-ai\tasks\projects"
    if (Test-Path $projectsDir) {
        $projects = Get-ChildItem $projectsDir -Directory -ErrorAction SilentlyContinue
        if ($projects.Count -eq 0) {
            Write-Host "No projects yet. Create: deepseek-autolook.ps1 rd" -ForegroundColor DarkGray
        }
        foreach ($projDir in $projects) {
            $projFile = Join-Path $projDir.FullName "project.json"
            if (Test-Path $projFile) {
                $proj = Get-Content $projFile -Raw | ConvertFrom-Json
                $taskCount = @(Get-ChildItem (Join-Path $projDir.FullName "tasks") -Filter "*.json" -ErrorAction SilentlyContinue).Count
                Write-Host "  [$($proj.status)] $($proj.id): $($proj.name) -- $taskCount tasks" -ForegroundColor $(if ($proj.status -eq "complete") { "Green" } else { "White" })
            }
        }
    } else {
        Write-Host "No projects directory." -ForegroundColor DarkGray
    }

    # Provider health
    Write-Host ""
    Write-Host "=== Provider Health ===" -ForegroundColor Cyan
    $healthPath = Join-Path $Root "parallel-ai\tasks\runtime\provider-health.json"
    if (Test-Path $healthPath) {
        $health = Get-Content $healthPath -Raw | ConvertFrom-Json
        $disabled = @($health.providers.PSObject.Properties | Where-Object {
            $_.Value.disabledUntil -and (Get-Date) -lt [datetime]::Parse($_.Value.disabledUntil)
        })
        if ($disabled.Count -gt 0) {
            foreach ($d in $disabled) {
                Write-Host "  [!!] $($d.Name): disabled until $($d.Value.disabledUntil) -- $($d.Value.disabledReason)" -ForegroundColor Red
            }
        } else {
            Write-Host "  All providers healthy." -ForegroundColor Green
        }
    } else {
        Write-Host "  No health data yet." -ForegroundColor DarkGray
    }

    Write-Host ""
}

function Show-Help {
    Write-Host ""
    Write-Host "DeepSeek Autolook -- Multi-AI Parallel Programming Workbench" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "Commands:" -ForegroundColor Yellow
    Write-Host "  sync      Sync providers from cc-switch.db"
    Write-Host "  start     Start stable provider proxies (sync first)"
    Write-Host "  stop      Stop all proxies"
    Write-Host "  status    Show system status (providers/projects/health)"
    Write-Host "  dashboard Launch tiled dashboard (TUI hub + worker windows)"
    Write-Host "  hub       Start interactive hub panel"
    Write-Host "  panel     Start supervisor panel (20 options menu)"
    Write-Host "  rd        Create RD task chain (4 seed tasks)"
    Write-Host "  verify    Run system verification"
    Write-Host "  check     Verify isolation (ports/settings/data)"
    Write-Host "  clean     Remove all runtime state (does NOT touch cc-switch)"
    Write-Host "  help      Show this help"
    Write-Host ""
    Write-Host "Examples:" -ForegroundColor DarkCyan
    Write-Host "  .\deepseek-autolook.ps1 status"
    Write-Host "  .\deepseek-autolook.ps1 rd -Name fix-login-bug"
    Write-Host "  .\deepseek-autolook.ps1 dashboard"
    Write-Host "  .\deepseek-autolook.ps1 hub -Project my-project"
    Write-Host ""
}

# ---- entry ----------------------------------------------------------------
Write-Host ""
Write-Host "+============================================+" -ForegroundColor Cyan
Write-Host "|     DeepSeek Autolook                      |" -ForegroundColor Cyan
Write-Host "+============================================+" -ForegroundColor Cyan

switch ($Command) {
    "sync"      { Invoke-Sync }
    "start"     { Invoke-Start }
    "stop"      { Invoke-Stop }
    "status"    { Invoke-Status }
    "dashboard" { Invoke-Dashboard }
    "hub"       { Invoke-Hub }
    "panel"     { Invoke-Panel }
    "rd"        { Invoke-RD }
    "verify"    { Invoke-Verify }
    "check"     { Invoke-Check }
    "clean"     { Invoke-Clean }
    "help"      { Test-Prerequisites | Out-Null; Show-Help }
    default     { Test-Prerequisites | Out-Null; Show-Help }
}
