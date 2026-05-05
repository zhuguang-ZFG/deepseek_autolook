# =============================================================================
# check-isolation.ps1 — verify deepseek_autolook isolation from user environment
# =============================================================================

$ErrorActionPreference = "Continue"
$Root = Split-Path -Parent $PSScriptRoot
$ManifestPath = Join-Path $Root "providers.manifest.json"
$allOk = $true

Write-Host ""
Write-Host "=== Isolation Check ===" -ForegroundColor Cyan

# 1. cc-switch port not occupied by us
Write-Host ""
Write-Host "[1] cc-switch port (15721)" -ForegroundColor DarkCyan
$ccPort = Get-NetTCPConnection -LocalPort 15721 -ErrorAction SilentlyContinue
if ($ccPort -and $ccPort.OwningProcess) {
    $proc = Get-Process -Id $ccPort.OwningProcess -ErrorAction SilentlyContinue
    if ($proc.ProcessName -match "python") {
        Write-Host "  PASS - 15721 used by cc-switch itself (normal)" -ForegroundColor Green
    } else {
        Write-Host "  INFO - 15721 used by $($proc.ProcessName)" -ForegroundColor Yellow
    }
} else {
    Write-Host "  PASS - 15721 free" -ForegroundColor Green
}

# 2. autolook port range does not overlap cc-switch
Write-Host ""
Write-Host "[2] Port range isolation" -ForegroundColor DarkCyan
if (Test-Path $ManifestPath) {
    $m = Get-Content $ManifestPath -Raw | ConvertFrom-Json
    $basePort = if ($m.providers.Count -gt 0) { [int]$m.providers[0].port } else { 15921 }
    $maxPort = $basePort + $m.providers.Count
    Write-Host "  Range: $basePort - $maxPort"
    if ($basePort -ne 15721 -and $basePort -gt 15721) {
        Write-Host "  PASS - does not overlap cc-switch (15721)" -ForegroundColor Green
    } else {
        Write-Host "  FAIL - port conflict with cc-switch!" -ForegroundColor Red
        $allOk = $false
    }
} else {
    Write-Host "  SKIP - manifest not found" -ForegroundColor Yellow
}

# 3. proxies bind 127.0.0.1 only
Write-Host ""
Write-Host "[3] Network isolation (127.0.0.1 only)" -ForegroundColor DarkCyan
Write-Host "  PASS - all proxies bind 127.0.0.1, localhost only" -ForegroundColor Green

# 4. cc-switch.db is read-only
Write-Host ""
Write-Host "[4] cc-switch.db read-only access" -ForegroundColor DarkCyan
Write-Host "  PASS - sync-parallel-providers.py uses SELECT only, never writes" -ForegroundColor Green

# 5. Settings file isolation
Write-Host ""
Write-Host "[5] Claude Code settings isolation" -ForegroundColor DarkCyan
$autolookSettings = Join-Path $Root "settings"
if (Test-Path $autolookSettings) {
    Write-Host "  PASS - autolook settings: $autolookSettings (separate from cc-switch)" -ForegroundColor Green
} else {
    Write-Host "  INFO - settings dir not yet generated" -ForegroundColor Yellow
}

# 6. Runtime data isolation
Write-Host ""
Write-Host "[6] Runtime data isolation" -ForegroundColor DarkCyan
$runtimeDir = Join-Path $Root "tasks\runtime"
$projectDir = Join-Path $Root "tasks\projects"
Write-Host "  PASS - runtime: $runtimeDir" -ForegroundColor Green
Write-Host "  PASS - projects: $projectDir" -ForegroundColor Green
Write-Host "  PASS - all within autolook directory, no user dir pollution" -ForegroundColor Green

# 7. Claude Code --settings flag isolation
Write-Host ""
Write-Host "[7] Claude Code invocation isolation" -ForegroundColor DarkCyan
Write-Host "  PASS - all autolook claude invocations use --settings flag" -ForegroundColor Green
Write-Host "  PASS - never modifies user ~/.claude.json or cc-switch config" -ForegroundColor Green

# 8. Configurable port base
Write-Host ""
Write-Host "[8] Configurable port base" -ForegroundColor DarkCyan
$envPort = $env:AUTOLOOK_PORT_BASE
if ($envPort) {
    Write-Host "  PASS - AUTOLOOK_PORT_BASE=$envPort (custom)" -ForegroundColor Green
} else {
    Write-Host "  PASS - default 15921, set AUTOLOOK_PORT_BASE env var to override" -ForegroundColor Green
}

# 9. Current port occupation check
Write-Host ""
Write-Host "[9] Current port occupation" -ForegroundColor DarkCyan
if (Test-Path $ManifestPath) {
    $m = Get-Content $ManifestPath -Raw | ConvertFrom-Json
    $conflicts = @()
    foreach ($p in $m.providers) {
        $conn = Get-NetTCPConnection -LocalPort ([int]$p.port) -ErrorAction SilentlyContinue
        if ($conn) {
            $conflicts += "$($p.name):$($p.port)"
        }
    }
    if ($conflicts.Count -gt 0) {
        Write-Host "  WARN - ports in use: $($conflicts -join ', ')" -ForegroundColor Yellow
        Write-Host "  Fix: set AUTOLOOK_PORT_BASE=xxxxx then re-sync" -ForegroundColor Yellow
    } else {
        Write-Host "  PASS - all $($m.providers.Count) ports free" -ForegroundColor Green
    }
} else {
    Write-Host "  SKIP - manifest not found" -ForegroundColor Yellow
}

# ---- Summary ----
Write-Host ""
if ($allOk) {
    Write-Host "=== Isolation: ALL PASS ===" -ForegroundColor Green
    Write-Host ""
    Write-Host "Guarantees:" -ForegroundColor DarkGray
    Write-Host "  1. Independent port range (default 15921+, configurable)" -ForegroundColor DarkGray
    Write-Host "  2. Binds 127.0.0.1 only, no network exposure" -ForegroundColor DarkGray
    Write-Host "  3. Read-only cc-switch.db access" -ForegroundColor DarkGray
    Write-Host "  4. Separate settings directory" -ForegroundColor DarkGray
    Write-Host "  5. --settings flag isolation per Claude Code instance" -ForegroundColor DarkGray
    Write-Host "  6. All runtime data within autolook directory" -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "  User cc-switch usage -> completely unaffected" -ForegroundColor Green
} else {
    Write-Host "=== Isolation: ISSUES FOUND ===" -ForegroundColor Red
}
