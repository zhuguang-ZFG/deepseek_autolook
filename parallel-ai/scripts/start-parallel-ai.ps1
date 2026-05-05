# Start all parallel AI sidecar proxies
$ErrorActionPreference = "Continue"
$root = Split-Path -Parent $PSScriptRoot

$syncScript = Join-Path $PSScriptRoot "sync-parallel-providers.py"
Write-Host "Syncing providers from cc-switch.db..." -ForegroundColor Cyan
C:\Python311\python.exe $syncScript

$manifestPath = Join-Path $root "providers.manifest.json"
if (-not (Test-Path $manifestPath)) {
    Write-Host "ERROR: Manifest not found at $manifestPath" -ForegroundColor Red
    exit 1
}

$manifest = Get-Content $manifestPath -Raw | ConvertFrom-Json
$providers = $manifest.providers

Write-Host ""
Write-Host "Starting $($providers.Count) provider proxies..." -ForegroundColor Green

foreach ($provider in $providers) {
    $cmdPath = $provider.launcher_path
    if (-not (Test-Path $cmdPath)) {
        Write-Host "  SKIP $($provider.name): launcher not found at $cmdPath" -ForegroundColor Yellow
        continue
    }

    Write-Host "  START $($provider.name) [port $($provider.port)] [$($provider.runtime_group)/$($provider.cost_tier)]" -ForegroundColor DarkCyan
    $proc = Start-Process cmd.exe -ArgumentList "/c", $cmdPath -WindowStyle Hidden -PassThru
    Start-Sleep -Milliseconds 300
}

Write-Host ""
Write-Host "All proxies launched." -ForegroundColor Green
Write-Host "To verify: check logs in $root\logs\"
Write-Host "To stop: run stop-parallel-ai.ps1"
