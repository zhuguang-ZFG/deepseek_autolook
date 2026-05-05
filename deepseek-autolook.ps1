# =============================================================================
# deepseek-autolook.ps1 — 顶层入口 / 一键 Bootstrap
# =============================================================================
# 用法:
#   powershell -ExecutionPolicy Bypass -File .\deepseek-autolook.ps1
#   powershell -ExecutionPolicy Bypass -File .\deepseek-autolook.ps1 sync
#   powershell -ExecutionPolicy Bypass -File .\deepseek-autolook.ps1 start
#   powershell -ExecutionPolicy Bypass -File .\deepseek-autolook.ps1 dashboard
#   powershell -ExecutionPolicy Bypass -File .\deepseek-autolook.ps1 hub -Project my-project
#   powershell -ExecutionPolicy Bypass -File .\deepseek-autolook.ps1 rd -Workspace C:\myproject
#   powershell -ExecutionPolicy Bypass -File .\deepseek-autolook.ps1 verify
#   powershell -ExecutionPolicy Bypass -File .\deepseek-autolook.ps1 stop
#   powershell -ExecutionPolicy Bypass -File .\deepseek-autolook.ps1 status
# =============================================================================

param(
    [Parameter(Position = 0)]
    [ValidateSet("sync", "start", "dashboard", "hub", "rd", "verify", "stop", "status", "panel", "check", "clean", "help")]
    [string]$Command = "help",

    [string]$Project,
    [string]$Workspace = (Get-Location).Path,
    [string]$Name
)

$ErrorActionPreference = "Continue"
$Root = Split-Path -Parent $PSCommandPath
$ScriptsDir = Join-Path $Root "parallel-ai\scripts"

# ---- 环境检查 ---------------------------------------------------------------
function Test-Prerequisites {
    $ok = $true

    # Python
    $py = Get-Command python -ErrorAction SilentlyContinue
    if (-not $py) {
        Write-Host "[FAIL] Python not found (need C:\Python311\python.exe)" -ForegroundColor Red
        $ok = $false
    } else {
        Write-Host "[ OK ] Python: $($py.Source)" -ForegroundColor Green
    }

    # Claude Code
    $claude = Get-Command claude -ErrorAction SilentlyContinue
    if (-not $claude) {
        Write-Host "[FAIL] claude not found" -ForegroundColor Red
        $ok = $false
    } else {
        Write-Host "[ OK ] claude: $($claude.Source)" -ForegroundColor Green
    }

    # cc-switch.db
    $ccDb = "$env:USERPROFILE\.cc-switch\cc-switch.db"
    if (Test-Path $ccDb) {
        Write-Host "[ OK ] cc-switch.db: $ccDb" -ForegroundColor Green
    } else {
        Write-Host "[WARN] cc-switch.db not found" -ForegroundColor Yellow
    }

    # Git
    $git = Get-Command git -ErrorAction SilentlyContinue
    if (-not $git) {
        Write-Host "[WARN] git not found (optional)" -ForegroundColor Yellow
    } else {
        Write-Host "[ OK ] git: present" -ForegroundColor Green
    }

    return $ok
}

# ---- 命令实现 ---------------------------------------------------------------

function Invoke-Sync {
    Write-Host "Syncing providers from cc-switch.db..." -ForegroundColor Cyan
    $syncScript = Join-Path $ScriptsDir "sync-parallel-providers.py"
    & C:\Python311\python.exe $syncScript
}

function Invoke-Start {
    Invoke-Sync
    Write-Host ""
    & powershell.exe -ExecutionPolicy Bypass -File (Join-Path $ScriptsDir "start-stable-providers.ps1")
    Write-Host ""
    Write-Host "Stable providers started. Verify with: deepseek-autolook.ps1 status" -ForegroundColor Green
}

function Invoke-Dashboard {
    & powershell.exe -NoExit -ExecutionPolicy Bypass -File (Join-Path $ScriptsDir "start-dashboard.ps1") -Workspace $Workspace
}

function Invoke-Hub {
    $args = @()
    if ($Project) { $args += "-Project", $Project }
    & powershell.exe -NoExit -ExecutionPolicy Bypass -File (Join-Path $ScriptsDir "hub.ps1") @args
}

function Invoke-RD {
    $args = @("-Workspace", $Workspace)
    if ($Name) { $args += "-Name", $Name }
    & powershell.exe -NoExit -ExecutionPolicy Bypass -File (Join-Path $ScriptsDir "start-rd-task.ps1") @args
}

function Invoke-Verify {
    Write-Host "Running verification..." -ForegroundColor Cyan
    Invoke-Sync | Out-Null
    & powershell.exe -ExecutionPolicy Bypass -File (Join-Path $ScriptsDir "verify-parallel-ai.ps1")
}

function Invoke-Stop {
    & powershell.exe -ExecutionPolicy Bypass -File (Join-Path $ScriptsDir "stop-parallel-ai.ps1")
}

function Invoke-Status {
    Write-Host ""
    Write-Host "═══ DeepSeek Autolook Status ═══" -ForegroundColor Cyan

    # Provider manifest
    $manifestPath = Join-Path $Root "parallel-ai\providers.manifest.json"
    if (Test-Path $manifestPath) {
        $manifest = Get-Content $manifestPath -Raw | ConvertFrom-Json
        Write-Host "Providers: $($manifest.providers.Count) configured" -ForegroundColor Green

        # Check which are running
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

        # Stable providers
        $stable = @($manifest.providers | Where-Object { $_.stable_candidate })
        $stableUp = @($running | Where-Object { $_.stable_candidate })
        Write-Host "Stable: $($stableUp.Count)/$($stable.Count) up" -ForegroundColor $(if ($stableUp.Count -eq $stable.Count) { "Green" } else { "Yellow" })
    } else {
        Write-Host "No manifest found. Run 'sync' first." -ForegroundColor Yellow
    }

    # Projects
    Write-Host ""
    Write-Host "═══ Projects ═══" -ForegroundColor Cyan
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
                Write-Host "  [$($proj.status)] $($proj.id): $($proj.name) — $taskCount tasks" -ForegroundColor $(if ($proj.status -eq "complete") { "Green" } else { "White" })
            }
        }
    } else {
        Write-Host "No projects directory." -ForegroundColor DarkGray
    }

    # Provider health
    Write-Host ""
    Write-Host "═══ Provider Health ═══" -ForegroundColor Cyan
    $healthPath = Join-Path $Root "parallel-ai\tasks\runtime\provider-health.json"
    if (Test-Path $healthPath) {
        $health = Get-Content $healthPath -Raw | ConvertFrom-Json
        $disabled = @($health.providers.PSObject.Properties | Where-Object {
            $_.Value.disabledUntil -and (Get-Date) -lt [datetime]::Parse($_.Value.disabledUntil)
        })
        if ($disabled.Count -gt 0) {
            foreach ($d in $disabled) {
                Write-Host "  [!!] $($d.Name): disabled until $($d.Value.disabledUntil) — $($d.Value.disabledReason)" -ForegroundColor Red
            }
        } else {
            Write-Host "  All providers healthy." -ForegroundColor Green
        }
    } else {
        Write-Host "  No health data yet." -ForegroundColor DarkGray
    }
}

function Invoke-Panel {
    & powershell.exe -NoExit -ExecutionPolicy Bypass -File (Join-Path $ScriptsDir "open-supervisor-panel.ps1") -Workspace $Workspace
}

function Invoke-Check {
    Write-Host "Running isolation check..." -ForegroundColor Cyan
    & powershell.exe -ExecutionPolicy Bypass -File (Join-Path $ScriptsDir "check-isolation.ps1")
}

function Invoke-Clean {
    Write-Host "Cleaning all runtime state..." -ForegroundColor Yellow
    $dirs = @(
        (Join-Path $Root "parallel-ai\settings"),
        (Join-Path $Root "parallel-ai\logs"),
        (Join-Path $Root "parallel-ai\tasks\runtime"),
        (Join-Path $Root "parallel-ai\tasks\projects")
    )
    foreach ($dir in $dirs) {
        if (Test-Path $dir) {
            Write-Host "  Remove: $dir" -ForegroundColor DarkGray
            Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    $files = @(
        (Join-Path $Root "parallel-ai\providers.manifest.json"),
        (Join-Path $Root "parallel-ai\scripts\open-claude-*.ps1"),
        (Join-Path $Root "parallel-ai\scripts\parallel-*.cmd")
    )
    foreach ($pattern in $files) {
        Get-ChildItem $pattern -ErrorAction SilentlyContinue | Remove-Item -Force
    }
    Write-Host "Done. Run 'sync' to rebuild." -ForegroundColor Green
}

function Show-Help {
    Write-Host ""
    Write-Host "DeepSeek Autolook — Multi-AI Parallel Programming Workbench" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "Commands:" -ForegroundColor Yellow
    Write-Host "  sync      同步 cc-switch 提供者配置"
    Write-Host "  start     启动稳定提供者代理（先 sync）"
    Write-Host "  stop      停止所有代理"
    Write-Host "  status    查看系统状态（提供者/项目/健康）"
    Write-Host "  dashboard 启动平铺仪表盘 (TUI 中枢 + worker 窗口)"
    Write-Host "  hub       启动交互式中枢面板"
    Write-Host "  panel     启动监督者面板（18 项操作菜单）"
    Write-Host "  rd        创建 RD 任务链（4 个种子任务）"
    Write-Host "  verify    运行系统验证"
    Write-Host "  check     验证隔离性 (端口/设置/数据不冲突)"
    Write-Host "  clean     清除所有运行时状态 (不影响 cc-switch)"
    Write-Host "  help      显示此帮助"
    Write-Host ""
    Write-Host "Examples:" -ForegroundColor DarkCyan
    Write-Host "  deepseek-autolook.ps1 status"
    Write-Host "  deepseek-autolook.ps1 start"
    Write-Host "  deepseek-autolook.ps1 dashboard -Workspace C:\myproject"
    Write-Host "  deepseek-autolook.ps1 hub -Project my-project"
    Write-Host "  deepseek-autolook.ps1 rd -Workspace C:\myproject -Name fix-login-bug"
    Write-Host ""
}

# ---- 入口 -------------------------------------------------------------------

Write-Host ""
Write-Host "╔══════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║     DeepSeek Autolook                        ║" -ForegroundColor Cyan
Write-Host "╚══════════════════════════════════════════════╝" -ForegroundColor Cyan

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
    "help"      {
        Test-Prerequisites | Out-Null
        Write-Host ""
        Show-Help
    }
    default     {
        Test-Prerequisites | Out-Null
        Write-Host ""
        Show-Help
    }
}
