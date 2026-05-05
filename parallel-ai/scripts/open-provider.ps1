param(
  [string]$Name,
  [string]$Workspace = (Get-Location).Path
)

$ErrorActionPreference = "Stop"

$Root = Split-Path -Parent $PSScriptRoot
$ManifestPath = Join-Path $Root "providers.manifest.json"
$StartParallelScript = Join-Path $PSScriptRoot "start-parallel-ai.ps1"

function Ensure-Manifest {
  if (-not (Test-Path $ManifestPath)) {
    & "C:\Python311\python.exe" (Join-Path $PSScriptRoot "sync-parallel-providers.py") | Out-Host
  }
}

function Ensure-ParallelStarted {
  & powershell.exe -ExecutionPolicy Bypass -File $StartParallelScript | Out-Host
}

function Open-ClaudeProvider {
  param($Provider, [string]$TargetWorkspace)
  $script = $Provider.open_script_path
  if (-not (Test-Path $script)) { throw "Open script missing: $script" }
  $command = "Set-Location `"$TargetWorkspace`"; & `"$script`""
  Start-Process powershell.exe -ArgumentList "-NoExit", "-Command", $command -WorkingDirectory $TargetWorkspace -WindowStyle Normal
}

function Open-Codex {
  param([string]$TargetWorkspace)
  $command = "Set-Location `"$TargetWorkspace`"; codex"
  Start-Process powershell.exe -ArgumentList "-NoExit", "-Command", $command -WorkingDirectory $TargetWorkspace -WindowStyle Normal
}

function Open-Cursor {
  param([string]$TargetWorkspace)
  Start-Process cursor.cmd -ArgumentList "`"$TargetWorkspace`"" -WorkingDirectory $TargetWorkspace -WindowStyle Normal
}

function Open-SupervisorPanel {
  param([string]$TargetWorkspace)
  $script = Join-Path $PSScriptRoot "open-supervisor-panel.ps1"
  Start-Process powershell.exe -ArgumentList "-NoExit", "-ExecutionPolicy", "Bypass", "-File", "`"$script`"", "-Workspace", "`"$TargetWorkspace`"" -WorkingDirectory $TargetWorkspace -WindowStyle Normal
}

function Get-GroupLabel {
  param($Entry)
  $text = (($Entry.Display | Out-String) + " " + ($Entry.Strengths | Out-String)).ToLower()
  if ($Entry.Kind -eq "tool") { return "Workspaces" }
  if ($text -match "local model|local task|local summaries|light local|ollama|qwen|gemma") { return "Local" }
  if ($text -match "review|validation|second opinion|implementation checks") { return "Review" }
  if ($text -match "experimental|fallback|custom provider route") { return "Experimental" }
  if ($text -match "reasoning|analysis|decomposition|design review|project analysis|web-backed research") { return "Reasoning" }
  if ($text -match "coding|workspace|execution") { return "Coding" }
  return "General"
}

Ensure-Manifest
$manifest = Get-Content $ManifestPath -Raw | ConvertFrom-Json
$providers = @($manifest.providers)

$entries = @()
$index = 1
foreach ($provider in $providers) {
  $entries += [pscustomobject]@{
    Index = $index; Kind = "claude"; Key = $provider.slug; Display = $provider.name
    Strengths = ("{0} | {1} | {2}" -f $provider.strengths, $provider.runtime_group, $provider.cost_tier)
    Provider = $provider
  }
  $index++
}

$entries += [pscustomobject]@{ Index = $index; Kind = "tool"; Key = "codex"; Display = "Codex"; Strengths = "primary coding workspace and execution"; Provider = $null }; $index++
$entries += [pscustomobject]@{ Index = $index; Kind = "tool"; Key = "cursor"; Display = "Cursor"; Strengths = "editor workspace, code navigation, manual review"; Provider = $null }; $index++
$entries += [pscustomobject]@{ Index = $index; Kind = "tool"; Key = "supervisor"; Display = "Supervisor Panel"; Strengths = "project task board, worker dispatch, recurring orchestration"; Provider = $null }

if (-not $Name) {
  Write-Host ""
  Write-Host "Open Provider Panel" -ForegroundColor Cyan
  Write-Host "Workspace: $Workspace"
  Write-Host ""
  $groupOrder = @("Reasoning", "Coding", "Review", "Local", "Experimental", "General", "Workspaces")
  foreach ($group in $groupOrder) {
    $groupEntries = @($entries | Where-Object { (Get-GroupLabel $_) -eq $group })
    if (-not $groupEntries) { continue }
    Write-Host ("== {0} ==" -f $group) -ForegroundColor Yellow
    foreach ($entry in $groupEntries) {
      if ($entry.Strengths) {
        Write-Host ("[{0}] {1}" -f $entry.Index, $entry.Display) -ForegroundColor White
        Write-Host ("     {0}" -f $entry.Strengths) -ForegroundColor DarkCyan
      } else {
        Write-Host ("[{0}] {1}" -f $entry.Index, $entry.Display)
      }
    }
    Write-Host ""
  }
  Write-Host ""
  $Name = Read-Host "Enter index, slug, or name. Use commas for multiple entries"
}

if (-not $Name) { Write-Host "No selection provided."; exit 0 }

$tokens = @($Name -split "," | ForEach-Object { $_.Trim() } | Where-Object { $_ })
$selected = @()

foreach ($token in $tokens) {
  $match = $entries | Where-Object { $_.Key -ieq $token -or $_.Display -ieq $token -or $_.Index.ToString() -eq $token } | Select-Object -First 1
  if (-not $match) {
    $prefix = $token + "*"
    $match = $entries | Where-Object { $_.Key -like $prefix -or $_.Display -like $prefix } | Select-Object -First 1
  }
  if ($match) { $selected += $match } else { Write-Host "Unknown selection: $token" -ForegroundColor Yellow }
}

if (-not $selected) { Write-Host "Nothing to open."; exit 1 }

if ($selected | Where-Object { $_.Kind -eq "claude" }) { Ensure-ParallelStarted }

foreach ($item in $selected) {
  switch ($item.Kind) {
    "claude" {
      Open-ClaudeProvider -Provider $item.Provider -TargetWorkspace $Workspace
      Write-Host "Opened Claude provider: $($item.Display)"
    }
    "tool" {
      if ($item.Key -eq "codex") { Open-Codex -TargetWorkspace $Workspace; Write-Host "Opened Codex" }
      elseif ($item.Key -eq "cursor") { Open-Cursor -TargetWorkspace $Workspace; Write-Host "Opened Cursor" }
      elseif ($item.Key -eq "supervisor") { Open-SupervisorPanel -TargetWorkspace $Workspace; Write-Host "Opened Supervisor Panel" }
    }
  }
}
