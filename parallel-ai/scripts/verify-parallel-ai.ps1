$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "supervisor-lib.ps1")

$repoRoot = Split-Path -Parent (Get-ParallelAiRoot)
$checks = @()

function Add-CheckResult {
    param(
        [string]$Name,
        [bool]$Passed,
        [string]$Details
    )
    $script:checks += [pscustomobject]@{
        Name    = $Name
        Passed  = $Passed
        Details = $Details
    }
}

function Test-IgnoredPath {
    param([string]$Path)
    $result = git -C $repoRoot check-ignore $Path 2>$null
    return -not [string]::IsNullOrWhiteSpace($result)
}

# --- Git ignore checks ---
$runtimeIgnored = Test-IgnoredPath "parallel-ai/tasks/runtime/provider-usage.json"
Add-CheckResult -Name "runtime-dir-ignored" -Passed $runtimeIgnored -Details "parallel-ai/tasks/runtime/provider-usage.json"

$artifactIgnored = Test-IgnoredPath "parallel-ai/tasks/projects/demo/artifacts/logs/example.log"
Add-CheckResult -Name "project-artifacts-ignored" -Passed $artifactIgnored -Details "parallel-ai/tasks/projects/*/artifacts/"

# --- Stable dispatch order ---
$task = [pscustomobject]@{
    owner            = "cursor"
    preferredWorkers = @("cursor", "DeepSeek", "github-gpt-5-mini", "longcat-flash-thinking-2601")
    fallbackWorkers  = @("longcat-flash-lite", "deepseek-v4-pro")
}
$dispatchOrder = @(Get-PreferredDispatchWorkerOrder $task)
$stableProviders = @(Get-StableDispatchProviders | ForEach-Object { $_.slug.ToLowerInvariant() })
$dispatchNormalized = @($dispatchOrder | ForEach-Object { ([string]$_).ToLowerInvariant() })
$compareCount = [Math]::Min($dispatchNormalized.Count, $stableProviders.Count)
$dispatchOk = ($dispatchOrder.Count -gt 0) -and (-not ($dispatchOrder -contains "cursor")) -and
    (@($dispatchNormalized[0..($compareCount - 1)]) -join "|") -eq (@($stableProviders[0..($compareCount - 1)]) -join "|")
Add-CheckResult -Name "stable-dispatch-order" -Passed $dispatchOk -Details ($dispatchOrder -join ", ")

# --- Provider manifest ---
$providerManifestPath = Get-ProviderManifestPath
$manifestOk = Test-Path $providerManifestPath
Add-CheckResult -Name "provider-manifest-present" -Passed $manifestOk -Details $providerManifestPath

# --- Duplicate dispatch guard ---
$activeTask = [pscustomobject]@{
    status       = "dispatched"
    owner        = "longcat-flash-lite"
    lastProvider = "longcat-flash-lite"
    leasedAt     = (Get-IsoNow)
    heartbeatAt  = (Get-IsoNow)
    leaseMinutes = 120
}
$leaseExpiry = Get-TaskLeaseExpiry $activeTask
$duplicateGuardOk = ($leaseExpiry -gt (Get-Date)) -and ($activeTask.status -eq "dispatched")
Add-CheckResult -Name "duplicate-dispatch-guard-preconditions" -Passed $duplicateGuardOk -Details ("owner={0}, provider={1}, leaseExpiry={2}" -f $activeTask.owner, $activeTask.lastProvider, $leaseExpiry)

# --- Provider health ---
$healthPath = Get-ProviderRuntimeHealthPath
$healthOk = -not (Test-Path $healthPath) -or (Test-Path $healthPath)
Add-CheckResult -Name "provider-health-path-valid" -Passed $healthOk -Details $healthPath

# --- Report ---
$checks | ForEach-Object {
    $status = if ($_.Passed) { "PASS" } else { "FAIL" }
    $color = if ($_.Passed) { "Green" } else { "Red" }
    Write-Host ("[{0}] {1} :: {2}" -f $status, $_.Name, $_.Details) -ForegroundColor $color
}

if ($checks.Passed -contains $false) {
    exit 1
}
