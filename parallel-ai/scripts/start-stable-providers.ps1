param(
  [switch]$HealthCheck
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "supervisor-lib.ps1")

$root = Split-Path -Parent $PSScriptRoot
$stableProviders = @(Get-StableDispatchProviders)

foreach ($provider in $stableProviders) {
  $scriptPath = $provider.launcher_path
  if (-not (Test-Path $scriptPath)) {
    Write-Host "Missing launcher: $scriptPath" -ForegroundColor Yellow
    continue
  }
  Start-Process -FilePath cmd.exe -ArgumentList "/c", $scriptPath -WindowStyle Hidden
  Write-Host ("Requested start: {0} [{1}]" -f $provider.name, $provider.slug) -ForegroundColor Green
}

Start-Sleep -Seconds 4

$ports = @($stableProviders | ForEach-Object { [int]$_.port })
Write-Host ""
Write-Host "Listening ports" -ForegroundColor Cyan
Get-NetTCPConnection -State Listen -LocalPort $ports -ErrorAction SilentlyContinue |
  Sort-Object LocalPort |
  Select-Object LocalPort, OwningProcess, State |
  Format-Table -AutoSize

if ($HealthCheck) {
  Write-Host ""
  Write-Host "Health checks" -ForegroundColor Cyan
  foreach ($provider in $stableProviders) {
    $port = [int]$provider.port
    try {
      $content = Invoke-WebRequest -UseBasicParsing ("http://127.0.0.1:{0}/health" -f $port) -TimeoutSec 8 |
        Select-Object -ExpandProperty Content
      Write-Host ("[{0}] {1} :: {2}" -f $port, $provider.slug, $content)
    } catch {
      Write-Host ("[{0}] {1} FAILED {2}" -f $port, $provider.slug, $_.Exception.Message) -ForegroundColor Yellow
    }
  }
}
