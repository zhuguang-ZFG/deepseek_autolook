# =============================================================================
# quick-self-check.ps1 — One-command full verification (verify + isolation)
# =============================================================================
$ErrorActionPreference = "Continue"
$Root = Split-Path -Parent $PSScriptRoot
$failed = 0; $passed = 0

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host " DeepSeek Autolook Quick Self-Check" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan

# 1. PowerShell syntax check on all .ps1 files
Write-Host ""
Write-Host "[1] PowerShell syntax" -ForegroundColor DarkCyan
$psFiles = @(Get-ChildItem "$Root\scripts\*.ps1", "$Root\..\deepseek-autolook.ps1" -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -notmatch "^open-claude-(?!task\.)|^parallel-" })
foreach ($f in $psFiles) {
    $tokens = $null; $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$tokens, [ref]$errors)
    if ($errors.Count -eq 0) {
        $passed++
    } else {
        Write-Host "  FAIL: $($f.Name) — $($errors[0].Message)" -ForegroundColor Red
        $failed++
    }
}
Write-Host "  Syntax: $passed/$($psFiles.Count) clean" -ForegroundColor $(if ($failed -eq 0) { "Green" } else { "Red" })

# 2. Python syntax check
Write-Host ""
Write-Host "[2] Python syntax" -ForegroundColor DarkCyan
$pyFiles = @(Get-ChildItem "$Root\proxies\*.py", "$Root\scripts\*.py" -ErrorAction SilentlyContinue)
$pyOk = 0; $pyFail = 0
foreach ($f in $pyFiles) {
    $result = python -m py_compile $f.FullName 2>&1
    if ($LASTEXITCODE -eq 0) { $pyOk++ } else { Write-Host "  FAIL: $($f.Name)" -ForegroundColor Red; $pyFail++ }
}
Write-Host "  Syntax: $pyOk/$($pyFiles.Count) clean" -ForegroundColor $(if ($pyFail -eq 0) { "Green" } else { "Red" })
if ($pyFail -gt 0) { $failed++ } else { $passed++ }

# 3. Manifest integrity
Write-Host ""
Write-Host "[3] Manifest integrity" -ForegroundColor DarkCyan
$manifestPath = Join-Path $Root "providers.manifest.json"
if (Test-Path $manifestPath) {
    try {
        $m = Get-Content $manifestPath -Raw | ConvertFrom-Json
        $required = @("slug","port","name","cost_tier","runtime_group","stability_tier","dispatch_priority","stable_candidate","healthcheck_candidate")
        $bad = @()
        foreach ($p in $m.providers) {
            foreach ($r in $required) {
                if (-not ($p.PSObject.Properties.Name -contains $r)) { $bad += "$($p.slug):$r" }
            }
        }
        if ($bad.Count -eq 0) {
            Write-Host "  PASS: $($m.providers.Count) providers, all fields present" -ForegroundColor Green
            $passed++
        } else {
            Write-Host "  FAIL: $($bad.Count) providers missing fields: $($bad -join ', ')" -ForegroundColor Red
            $failed++
        }
    } catch {
        Write-Host "  FAIL: manifest JSON invalid" -ForegroundColor Red
        $failed++
    }
} else {
    Write-Host "  SKIP: manifest not found" -ForegroundColor Yellow
}

# 4. Key functions available
Write-Host ""
Write-Host "[4] Supervisor library functions" -ForegroundColor DarkCyan
. (Join-Path $Root "scripts\supervisor-lib.ps1")
$funcs = @("Get-ProviderManifest","Get-DispatchableProviders","Get-StableDispatchProviders","Get-FreeProviders",
           "Build-WorkerPrompt","Build-ReviewerPrompt","Invoke-AutoReview","Apply-AutoReviewResult",
           "Get-ProjectList","Get-TaskList","Register-ProviderFailure","Reset-ProviderRuntimePenalty",
           "Get-PreferredDispatchWorkerOrder","Get-ProviderRuntimeHealth")
$missingFuncs = @($funcs | Where-Object { -not (Get-Command $_ -ErrorAction SilentlyContinue) })
if ($missingFuncs.Count -eq 0) {
    Write-Host "  PASS: all $($funcs.Count) core functions available" -ForegroundColor Green
    $passed++
} else {
    Write-Host "  FAIL: missing: $($missingFuncs -join ', ')" -ForegroundColor Red
    $failed++
}

# 5. cc-switch.db readable
Write-Host ""
Write-Host "[5] cc-switch.db access" -ForegroundColor DarkCyan
$ccDb = "$env:USERPROFILE\.cc-switch\cc-switch.db"
if (Test-Path $ccDb) {
    Write-Host "  PASS: cc-switch.db exists ($((Get-Item $ccDb).Length) bytes)" -ForegroundColor Green
    $passed++
} else {
    Write-Host "  INFO: cc-switch.db not found (optional)" -ForegroundColor Yellow
}

# ---- Final ----
Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
$total = $passed + $failed
if ($failed -eq 0) {
    Write-Host " RESULT: PASS ($passed/$total)" -ForegroundColor Green
} else {
    Write-Host " RESULT: $failed FAILED ($passed/$total)" -ForegroundColor Red
}
Write-Host "========================================" -ForegroundColor Cyan
exit $failed
