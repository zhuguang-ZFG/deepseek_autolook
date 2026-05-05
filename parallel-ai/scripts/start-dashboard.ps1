# =============================================================================
# start-dashboard.ps1 — Tiled Multi-AI Dashboard Launcher
# =============================================================================
# Usage:
#   powershell -ExecutionPolicy Bypass -File .\start-dashboard.ps1
#   powershell -ExecutionPolicy Bypass -File .\start-dashboard.ps1 -Workspace C:\myproject
#
# Layout:
#   ┌──────────────────────┬──────────────┐
#   │                      │  Worker 1    │
#   │   DeepSeek TUI       ├──────────────┤
#   │   (中枢/编排)         │  Worker 2    │
#   │                      ├──────────────┤
#   │                      │  Worker 3    │
#   └──────────────────────┴──────────────┘
# =============================================================================

param(
    [string]$Workspace = (Get-Location).Path,
    [int]$MainWidthPercent = 65,
    [string[]]$Workers = @("deepseek", "longcat-flash-thinking-2601", "github-gpt-5-mini"),
    [int]$MonitorIndex = 0,
    [string]$Hub = "tui"
)

$ErrorActionPreference = "Continue"

# ---- Win32 API for window positioning ---------------------------------------
Add-Type @"
using System;
using System.Runtime.InteropServices;
public class WindowLayout {
    [DllImport("user32.dll")]
    public static extern bool SetWindowPos(IntPtr hWnd, IntPtr hWndInsertAfter,
        int X, int Y, int cx, int cy, uint uFlags);

    [DllImport("user32.dll")]
    public static extern bool MoveWindow(IntPtr hWnd, int X, int Y, int cx, int cy, bool repaint);

    [DllImport("user32.dll")]
    public static extern bool GetWindowRect(IntPtr hWnd, out RECT lpRect);

    public static readonly IntPtr HWND_TOP = IntPtr.Zero;
    public const uint SWP_NOZORDER = 0x0004;
    public const uint SWP_SHOWWINDOW = 0x0040;

    [StructLayout(LayoutKind.Sequential)]
    public struct RECT {
        public int Left, Top, Right, Bottom;
    }
}
"@

# ---- Path resolution --------------------------------------------------------
$Root = Split-Path -Parent $PSScriptRoot
$ManifestPath = Join-Path $Root "providers.manifest.json"

if (-not (Test-Path $ManifestPath)) {
    Write-Host "Manifest not found. Running sync..." -ForegroundColor Yellow
    & "C:\Python311\python.exe" (Join-Path $PSScriptRoot "sync-parallel-providers.py")
}

$manifest = Get-Content $ManifestPath -Raw | ConvertFrom-Json
$allProviders = $manifest.providers

# ---- Calculate screen layout ------------------------------------------------
$screens = [System.Windows.Forms.Screen]::AllScreens
if ($MonitorIndex -ge $screens.Count) { $MonitorIndex = 0 }
$screen = $screens[$MonitorIndex]
$bounds = $screen.WorkingArea

$totalW = $bounds.Width
$totalH = $bounds.Height
$left = $bounds.X
$top = $bounds.Y

# Reserve some margin
$margin = 4
$left += $margin
$top += $margin
$totalW -= $margin * 2
$totalH -= $margin * 2

$mainW = [int]($totalW * $MainWidthPercent / 100) - $margin
$sideW = $totalW - $mainW - $margin
$sideX = $left + $mainW + $margin

Write-Host "Screen: $totalW x $totalH at ($left, $top)" -ForegroundColor DarkGray
Write-Host "Main: ${mainW}px | Side: ${sideW}px" -ForegroundColor DarkGray

# ---- Launch main hub window --------------------------------------------------
Write-Host ""
if ($Hub -eq "tui") {
    Write-Host "中枢: 当前 DeepSeek TUI 会话 (不启动额外窗口)" -ForegroundColor Green
    Write-Host "  使用 hub.ps1 的 Start-Hub 或直接在 TUI 中管理" -ForegroundColor DarkGray
} elseif ($Hub -eq "codex") {
    Write-Host "Launching Codex (supervisor)..." -ForegroundColor Cyan
    $codexProc = Start-Process powershell.exe -ArgumentList "-NoExit", "-Command", "Set-Location '$Workspace'; codex" -WindowStyle Normal -PassThru
    Start-Sleep -Seconds 2
    try {
        [WindowLayout]::MoveWindow($codexProc.MainWindowHandle, $left, $top, $mainW, $totalH, $true)
        Write-Host "  Codex positioned: ${left},${top} ${mainW}x${totalH}" -ForegroundColor Green
    } catch {
        Write-Host "  Codex position failed (will use default): $_" -ForegroundColor Yellow
    }
} else {
    Write-Host "中枢: 外部 (不启动额外窗口)" -ForegroundColor Green
}

# ---- Resolve worker providers ------------------------------------------------
function Resolve-Provider {
    param([string]$Name)
    $match = $allProviders | Where-Object { $_.slug -ieq $Name -or $_.name -ieq $Name } | Select-Object -First 1
    if (-not $match) {
        $prefix = $Name + "*"
        $match = $allProviders | Where-Object { $_.slug -like $prefix -or $_.name -like $prefix } | Select-Object -First 1
    }
    return $match
}

# ---- Launch worker windows ---------------------------------------------------
$workerCount = $Workers.Count
if ($workerCount -eq 0) { $workerCount = 1 }
$workerH = [int](($totalH - ($workerCount - 1) * $margin) / $workerCount)

Write-Host ""
Write-Host "Launching $workerCount worker(s)..." -ForegroundColor Cyan

$workerProcs = @()
for ($i = 0; $i -lt $workerCount; $i++) {
    $workerName = $Workers[$i]
    $provider = Resolve-Provider -Name $workerName

    if (-not $provider) {
        Write-Host "  SKIP $workerName : provider not found" -ForegroundColor Yellow
        continue
    }

    $workerY = $top + $i * ($workerH + $margin)
    $openScript = $provider.open_script_path

    if (-not (Test-Path $openScript)) {
        Write-Host "  SKIP $($provider.name) : launcher missing" -ForegroundColor Yellow
        continue
    }

    # Start the worker window
    $proc = Start-Process powershell.exe -ArgumentList "-NoExit", "-Command", "Set-Location '$Workspace'; & '$openScript'" -WindowStyle Normal -PassThru
    Start-Sleep -Milliseconds 800

    # Position worker window
    try {
        [WindowLayout]::MoveWindow($proc.MainWindowHandle, $sideX, $workerY, $sideW, $workerH, $true)
        Write-Host "  $($provider.name) : ${sideX},${workerY} ${sideW}x${workerH}" -ForegroundColor Green
    } catch {
        Write-Host "  $($provider.name) position failed: $_" -ForegroundColor Yellow
    }

    $workerProcs += @{ Name = $provider.name; Proc = $proc; Provider = $provider }
}

# ---- Summary -----------------------------------------------------------------
Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host " Dashboard Ready" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
if ($Hub -eq "tui") {
    Write-Host " 中枢: DeepSeek TUI (当前会话)"
    Write-Host " 用 hub.ps1 的 Start-Hub 直接管理"
} else {
    Write-Host " Main ($Hub) : ${left},${top} ${mainW}x${totalH}"
}
foreach ($w in $workerProcs) {
    Write-Host " Worker ($($w.Name)) : side panel"
}
Write-Host ""
Write-Host " Tip: Use the supervisor panel to dispatch tasks to workers."
Write-Host "      powershell -File .\open-supervisor-panel.ps1"
Write-Host ""
Write-Host " Tip: Right-click terminal title bar → 'Layout' to adjust."
Write-Host "========================================" -ForegroundColor Cyan
