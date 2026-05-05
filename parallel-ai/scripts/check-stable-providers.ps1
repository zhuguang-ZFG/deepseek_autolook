$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "supervisor-lib.ps1")

$providers = @(Get-StableHealthcheckProviders)
$ports = @($providers | ForEach-Object { [int]$_.port })

Write-Host "Listening ports" -ForegroundColor Cyan
Get-NetTCPConnection -State Listen -LocalPort $ports -ErrorAction SilentlyContinue |
  Sort-Object LocalPort |
  Select-Object LocalPort, OwningProcess, State |
  Format-Table -AutoSize

Write-Host ""
Write-Host "Health checks" -ForegroundColor Cyan
foreach ($provider in $providers) {
  $port = [int]$provider.port
  try {
    $content = Invoke-WebRequest -UseBasicParsing ("http://127.0.0.1:{0}/health" -f $port) -TimeoutSec 8 |
      Select-Object -ExpandProperty Content
    Write-Host ("[{0}] {1} :: {2}" -f $port, $provider.slug, $content)
  } catch {
    Write-Host ("[{0}] {1} FAILED {2}" -f $port, $provider.slug, $_.Exception.Message) -ForegroundColor Yellow
  }
}
