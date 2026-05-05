param(
  [string]$Title = "DeepSeek Autolook",
  [string]$Message,
  [int]$TimeoutSeconds = 8
)

$ErrorActionPreference = "Stop"

if ([string]::IsNullOrWhiteSpace($Message)) {
  exit 0
}

try {
  $shell = New-Object -ComObject WScript.Shell
  $null = $shell.Popup($Message, $TimeoutSeconds, $Title, 64)
} catch {
  try {
    Add-Type -AssemblyName System.Windows.Forms
    [System.Windows.Forms.MessageBox]::Show($Message, $Title) | Out-Null
  } catch {
    Write-Host ("Desktop alert failed: " + $_.Exception.Message) -ForegroundColor Yellow
  }
}
