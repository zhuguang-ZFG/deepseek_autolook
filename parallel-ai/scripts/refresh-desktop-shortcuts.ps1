$ErrorActionPreference = "Stop"

$Root = Split-Path -Parent $PSScriptRoot
$ManifestPath = Join-Path $Root "providers.manifest.json"
$Desktop = [Environment]::GetFolderPath("Desktop")
$Wsh = New-Object -ComObject WScript.Shell

if (-not (Test-Path $ManifestPath)) {
  throw "Manifest not found: $ManifestPath"
}

$manifest = Get-Content $ManifestPath -Raw | ConvertFrom-Json

Get-ChildItem $Desktop -Filter "DeepSeek Autolook - *.lnk" -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue

foreach ($provider in $manifest.providers) {
  $safeName = $provider.name -replace '[\\/:*?"<>|]', '-'
  $linkPath = Join-Path $Desktop ("DeepSeek Autolook - " + $safeName + ".lnk")
  $openScript = $provider.open_script_path
  $sc = $Wsh.CreateShortcut($linkPath)
  $sc.TargetPath = "C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe"
  $sc.Arguments = '-ExecutionPolicy Bypass -File "' + $openScript + '"'
  $sc.WorkingDirectory = Split-Path $openScript
  $sc.IconLocation = "C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe,0"
  $sc.WindowStyle = 1
  $sc.Description = "Provider: {0} | Port: {1} | Strengths: {2}" -f $provider.name, $provider.port, $provider.strengths
  $sc.Save()
  Write-Host ("Created shortcut: " + $safeName)
}

Write-Host ""
Write-Host "Created $($manifest.providers.Count) shortcuts on Desktop." -ForegroundColor Green
