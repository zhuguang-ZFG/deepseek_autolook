param(
    [string]$Project,
    [string]$Task,
    [string]$Provider,
    [string]$Workspace,
    [switch]$ForceExpensive,
    [switch]$AutoFallback
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "supervisor-lib.ps1")

Ensure-SupervisorLayout | Out-Null

if (-not $Project) { $Project = Read-Host "Project slug" }
if (-not $Task) { $Task = Read-Host "Task ID" }
if (-not $Provider) { $Provider = Read-Host "Provider slug or name (blank for auto)" }

$projectFile = Get-ProjectFile $Project
$taskFile = Get-TaskFile -ProjectSlug $Project -TaskId $Task
if (-not (Test-Path $projectFile)) { throw "Project not found: $projectFile" }
if (-not (Test-Path $taskFile)) { throw "Task not found: $taskFile" }

$projectData = Read-JsonFile $projectFile
$taskData = Ensure-TaskSchema (Read-JsonFile $taskFile)

# ---- Worker resolution ------------------------------------------------------

function Try-ResolveWorker {
    param([string]$WorkerName)
    if ($WorkerName -ieq "cursor") {
        return [pscustomobject]@{ kind = "cursor"; name = "cursor" }
    }
    $provider = Find-ProviderEntry -Provider $WorkerName -IncludeDisabled
    if ($provider) {
        $blockedReason = Get-ProviderDispatchBlockReason -Provider $provider
        if ($blockedReason) {
            return [pscustomobject]@{ kind = "provider-disabled"; name = $provider.name; provider = $provider; reason = $blockedReason }
        }
        return [pscustomobject]@{ kind = "provider"; name = $provider.name; provider = $provider }
    }
    return $null
}

$workerCandidates = @()
if ($Provider) {
    $workerCandidates += $Provider
}
elseif ($AutoFallback) {
    $workerCandidates += Get-PreferredDispatchWorkerOrder $taskData
}
elseif ($taskData.owner) {
    $workerCandidates += $taskData.owner
}

if (-not $workerCandidates) {
    throw "No worker specified and no owner/fallback worker configured."
}

$selectedWorker = $null
$providerEntry = $null
$cursorMode = $false
foreach ($candidate in $workerCandidates) {
    $resolved = Try-ResolveWorker $candidate
    if (-not $resolved) {
        $taskData = Add-AssignmentHistoryEntry -Task $taskData -Worker $candidate -Outcome "skipped" -Reason "worker-not-found"
        continue
    }
    if ($resolved.kind -eq "provider-disabled") {
        $taskData = Add-AssignmentHistoryEntry -Task $taskData -Worker $candidate -Outcome "skipped" -Reason ("dispatch-disabled:" + $resolved.reason)
        continue
    }
    if ($resolved.kind -eq "cursor") {
        $selectedWorker = $candidate
        $cursorMode = $true
        break
    }
    $providerEntry = $resolved.provider
    if ($providerEntry.runtime_group -eq "local") {
        $lock = Get-LocalLock
        if ($lock -and -not ($lock.project -eq $Project -and $lock.task -eq $Task)) {
            $taskData = Add-AssignmentHistoryEntry -Task $taskData -Worker $candidate -Outcome "skipped" -Reason ("local-busy:" + $lock.providerName)
            $providerEntry = $null
            continue
        }
    }
    if ($providerEntry.cost_tier -eq "expensive" -and -not $ForceExpensive) {
        $taskData = Add-AssignmentHistoryEntry -Task $taskData -Worker $candidate -Outcome "skipped" -Reason "expensive-needs-override"
        $providerEntry = $null
        continue
    }
    $selectedWorker = $candidate
    break
}

if (-not $selectedWorker) {
    Write-JsonFile -Path $taskFile -Data $taskData
    throw "No available worker found for this task."
}

# Duplicate dispatch guard: check if task already has an active lease with the same worker/provider
$activeLeaseExpiry = Get-TaskLeaseExpiry $taskData
$hasActiveLease = $taskData.status -eq "dispatched" -and $activeLeaseExpiry -and $activeLeaseExpiry -gt (Get-Date)
$sameWorker = -not [string]::IsNullOrWhiteSpace($taskData.owner) -and $taskData.owner -ieq $selectedWorker
$sameProvider = $cursorMode -or (
    $providerEntry -and
    -not [string]::IsNullOrWhiteSpace($taskData.lastProvider) -and
    $taskData.lastProvider -ieq $providerEntry.slug
)

if ($hasActiveLease -and $sameWorker -and $sameProvider) {
    Write-Host ("Task {0} is already dispatched to {1} until {2}. Skipping duplicate dispatch." -f $Task, $selectedWorker, $activeLeaseExpiry) -ForegroundColor Yellow
    return
}

if ($cursorMode) {
    Write-JsonFile -Path $taskFile -Data $taskData
    & (Join-Path $PSScriptRoot "open-cursor-task.ps1") -Project $Project -Task $Task -Workspace $Workspace
    return
}

# ---- Build prompt and launcher -----------------------------------------------

$reportPath = Get-TaskReportPath -ProjectSlug $Project -TaskId $Task -ProviderSlug $providerEntry.slug
$promptPath = Join-Path (Join-Path (Get-ProjectRoot $Project) "prompts") ($Task + "--" + $providerEntry.slug + ".txt")
$workerPrompt = Build-WorkerPrompt -Project $projectData -Task $taskData -Provider $providerEntry -ReportPath $reportPath
[System.IO.File]::WriteAllText($promptPath, $workerPrompt + [Environment]::NewLine, [System.Text.UTF8Encoding]::new($false))

if (-not $Workspace) {
    $Workspace = if ($projectData.workspace) { $projectData.workspace } else { (Get-Location).Path }
}

# ---- Update task state -------------------------------------------------------

$taskData.status = "dispatched"
$taskData.dispatchCount = [int]$taskData.dispatchCount + 1
$taskData.attemptCount = [int]$taskData.attemptCount + 1
$taskData.lastProvider = $providerEntry.slug
$taskData.lastDispatchAt = Get-IsoNow
$taskData.owner = $selectedWorker
$taskData.lastFailureReason = ""
$taskData = Start-TaskLease -Task $taskData
$taskData = Add-AssignmentHistoryEntry -Task $taskData -Worker $selectedWorker -Outcome "delegated" -Reason "provider-selected"
$taskData.updatedAt = $taskData.lastDispatchAt
Write-JsonFile -Path $taskFile -Data $taskData
Update-ProviderUsage -Provider $providerEntry -Project $Project -Task $Task
Reset-ProviderRuntimePenalty -ProviderSlug $providerEntry.slug
if ($providerEntry.runtime_group -eq "local") {
    Set-LocalLock -Project $Project -Task $Task -Provider $providerEntry
}
Write-SupervisorEvent -Type "task-dispatched" -Project $Project -Task $Task -Worker $selectedWorker -Status $taskData.status -Summary "worker-launched" -FilesTouched "" -Extra @{
    provider       = $providerEntry.slug
    runtime        = $providerEntry.runtime_group
    expectedOutput = $taskData.expectedOutput
} | Out-Null

# ---- Generate launcher script -------------------------------------------------

$settingsPath = $providerEntry.settings_path
$providerName = $providerEntry.name
$taskLabel = "$($taskData.id) $($taskData.title)"
$policySummary = Get-ProviderPolicySummary -Provider $providerEntry
$artifactsDir = Join-Path (Get-ProjectRoot $Project) "artifacts"
$logsDir = Join-Path $artifactsDir "logs"
$launchersDir = Join-Path $artifactsDir "launchers"
New-Item -ItemType Directory -Force -Path $logsDir | Out-Null
New-Item -ItemType Directory -Force -Path $launchersDir | Out-Null

$logPath = Join-Path $logsDir ($Task + "--" + $providerEntry.slug + ".log")
$streamPath = Join-Path $logsDir ($Task + "--" + $providerEntry.slug + ".jsonl")
$launcherPath = Join-Path $launchersDir ($Task + "--" + $providerEntry.slug + ".ps1")
$submitScriptPath = Join-Path $PSScriptRoot "submit-supervisor-task.ps1"
$failScriptPath = Join-Path $PSScriptRoot "fail-supervisor-task.ps1"
$supervisorLibPath = Join-Path $PSScriptRoot "supervisor-lib.ps1"
$pythonResultExtractorPath = Join-Path (Get-ParallelAiRoot) "scripts\extract-claude-result.py"
$windowTitle = $providerName + " | " + $taskLabel
$allowedDirs = @()
foreach ($path in @($taskData.allowedPaths)) {
    if (-not [string]::IsNullOrWhiteSpace($path) -and $allowedDirs -notcontains $path) {
        $allowedDirs += $path
    }
}
if ($Workspace -and $allowedDirs -notcontains $Workspace) {
    $allowedDirs += $Workspace
}
$projectRuntimeRoot = Get-ProjectRoot $Project
if ($allowedDirs -notcontains $projectRuntimeRoot) {
    $allowedDirs += $projectRuntimeRoot
}
$allowedDirArgs = (($allowedDirs | ForEach-Object { "--add-dir `"$($_)`"" }) -join " ")
$displayCommand = "Get-Content -Raw `"$promptPath`" | claude -p --verbose --output-format stream-json --include-partial-messages --permission-mode bypassPermissions --dangerously-skip-permissions $allowedDirArgs --settings `"$settingsPath`""

$launcherScript = @"
`$ErrorActionPreference = 'Continue'
try { chcp 65001 | Out-Null } catch {}
try {
    [Console]::InputEncoding = [System.Text.UTF8Encoding]::new(`$false)
    [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new(`$false)
    `$OutputEncoding = [System.Text.UTF8Encoding]::new(`$false)
} catch {}
`$env:PYTHONIOENCODING = 'utf-8'
`$env:LANG = 'zh_CN.UTF-8'
try { `$Host.UI.RawUI.WindowTitle = '$($windowTitle.Replace("'", "''"))' } catch {}

function Write-RenderedStreamLine {
    param([string]`$Line)
    if ([string]::IsNullOrWhiteSpace(`$Line)) { return }
    try { `$obj = `$Line | ConvertFrom-Json -ErrorAction Stop } catch { Write-Host `$Line; return }

    if (`$obj.type -eq 'system' -and `$obj.subtype -eq 'task_progress' -and `$obj.description) {
        Write-Host ("[tool] " + [string]`$obj.description) -ForegroundColor DarkCyan; return
    }
    if (`$obj.type -eq 'assistant' -and `$obj.message -and `$obj.message.content) {
        foreach (`$block in @(`$obj.message.content)) {
            if (`$block.type -eq 'thinking' -and `$block.thinking) {
                Write-Host '[thinking]' -ForegroundColor DarkGray -NoNewline
                Write-Host (' ' + ([string]`$block.thinking).Trim()); continue
            }
            if (`$block.type -eq 'text' -and `$block.text) {
                Write-Host ([string]`$block.text); continue
            }
            if (`$block.type -eq 'tool_use' -and `$block.name) {
                `$inputText = ''
                try { if (`$block.input) { `$inputText = (`$block.input | ConvertTo-Json -Compress -Depth 8) } } catch {}
                if (`$inputText.Length -gt 240) { `$inputText = `$inputText.Substring(0, 240) + '...' }
                Write-Host ("[tool_use] " + [string]`$block.name + ' ' + `$inputText) -ForegroundColor Yellow; continue
            }
        }
        return
    }
    if (`$obj.type -eq 'result') {
        Write-Host ("[result] exit=" + [string]`$obj.is_error + " status=" + [string]`$obj.subtype) -ForegroundColor DarkYellow; return
    }
}

Write-Host "Supervisor task dispatch" -ForegroundColor Cyan
Write-Host "Project: $($projectData.id)"; Write-Host "Task: $($taskData.id) - $($taskData.title)"
Write-Host "Provider: $($providerEntry.name)"; Write-Host "Policy: $($policySummary)"
Write-Host "Prompt: $($promptPath)"; Write-Host "Report: $($reportPath)"
Write-Host "Log: $($logPath)"; Write-Host "Stream: $($streamPath)"
Write-Host "Command: $($displayCommand)"; Write-Host ""

try { Start-Transcript -Path '$($logPath.Replace("'", "''"))' -Force | Out-Null } catch {
    Write-Host "Transcript start failed: $($_.Exception.Message)" -ForegroundColor Yellow
}

try {
    Set-Location '$($Workspace.Replace("'", "''"))'
    . '$($supervisorLibPath.Replace("'", "''"))'
    Write-Host "Resolved command:" -ForegroundColor DarkCyan
    Write-Host '$($displayCommand.Replace("'", "''"))'; Write-Host ""
    if (Test-Path '$($streamPath.Replace("'", "''"))') {
        Remove-Item -LiteralPath '$($streamPath.Replace("'", "''"))' -Force -ErrorAction SilentlyContinue
    }
    Write-Host "Launching claude stream..." -ForegroundColor Green
    Get-Content '$($promptPath.Replace("'", "''"))' -Raw |
        claude -p --verbose --output-format stream-json --include-partial-messages --permission-mode bypassPermissions --dangerously-skip-permissions $($allowedDirArgs) --settings '$($settingsPath.Replace("'", "''"))' 2>&1 |
        ForEach-Object {
            `$line = [string]`$_
            [System.IO.File]::AppendAllText('$($streamPath.Replace("'", "''"))', `$line + [Environment]::NewLine, [System.Text.UTF8Encoding]::new(`$false))
            Write-RenderedStreamLine -Line `$line
        }
    `$claudeExit = `$LASTEXITCODE
    `$resultText = ""
    if (Test-Path '$($streamPath.Replace("'", "''"))') {
        try {
            `$resultText = (& python '$($pythonResultExtractorPath.Replace("'", "''"))' '$($streamPath.Replace("'", "''"))') -join [Environment]::NewLine
        } catch {
            Write-Host "Python result extraction failed: $($_.Exception.Message)" -ForegroundColor Yellow
        }
    }
    Write-Host ""; Write-Host "Claude exit code: `$claudeExit" -ForegroundColor Yellow
    if (-not [string]::IsNullOrWhiteSpace(`$resultText)) {
        [System.IO.File]::WriteAllText('$($reportPath.Replace("'", "''"))', (`$resultText.TrimEnd() + [Environment]::NewLine), [System.Text.UTF8Encoding]::new(`$false))
        Write-Host "Report written: $($reportPath)" -ForegroundColor Green
        try {
            & '$($submitScriptPath.Replace("'", "''"))' -Project '$($Project.Replace("'", "''"))' -Task '$($Task.Replace("'", "''"))' -Worker '$($providerEntry.slug.Replace("'", "''"))' -Summary 'report-captured-from-stream' -AutoReview
        } catch {
            Write-Host "Submit status update failed: $($_.Exception.Message)" -ForegroundColor Yellow
        }
        Write-Host ""; Write-Host "Report preview:" -ForegroundColor DarkCyan
        Write-Host (`$resultText.Substring(0, [Math]::Min(`$resultText.Length, 1200)))
    } else {
        Write-Host "No final result extracted from stream; report not written." -ForegroundColor Yellow
        `$failureReason = if (`$claudeExit -ne 0) { "worker-exited" } else { "partial-output" }
        if (Test-Path '$($streamPath.Replace("'", "''"))') {
            try {
                `$streamText = Get-Content '$($streamPath.Replace("'", "''"))' -Raw
                `$classified = Get-TaskFailureClassificationFromText -Text `$streamText
                if (-not [string]::IsNullOrWhiteSpace(`$classified)) { `$failureReason = `$classified }
            } catch {}
        }
        try {
            & '$($failScriptPath.Replace("'", "''"))' -Project '$($Project.Replace("'", "''"))' -Task '$($Task.Replace("'", "''"))' -Reason `$failureReason -Note 'launcher-no-report' -Workspace '$($Workspace.Replace("'", "''"))'
        } catch {
            Write-Host "Failure status update failed: $($_.Exception.Message)" -ForegroundColor Yellow
        }
    }
} catch {
    Write-Host ""; Write-Host "Claude launch failed: $($_.Exception.Message)" -ForegroundColor Red
    try {
        & '$($failScriptPath.Replace("'", "''"))' -Project '$($Project.Replace("'", "''"))' -Task '$($Task.Replace("'", "''"))' -Reason 'worker-exited' -Note 'launcher-exception' -Workspace '$($Workspace.Replace("'", "''"))'
    } catch {
        Write-Host "Failure status update failed: $($_.Exception.Message)" -ForegroundColor Yellow
    }
} finally {
    try { Stop-Transcript | Out-Null } catch {}
}

Write-Host ""; Write-Host "Launcher finished. Window kept open for inspection." -ForegroundColor Cyan
Write-Host "Log file: $($logPath)"
Read-Host "Press Enter to close this worker window"
"@

[System.IO.File]::WriteAllText($launcherPath, $launcherScript + [Environment]::NewLine, [System.Text.UTF8Encoding]::new($false))

$taskData.notes = @($taskData.notes) + ("[" + (Get-IsoNow) + "] launcher=" + $launcherPath)
$taskData.notes = @($taskData.notes) + ("[" + (Get-IsoNow) + "] log=" + $logPath)
Write-JsonFile -Path $taskFile -Data $taskData

Start-Process powershell.exe -ArgumentList "-NoExit", "-ExecutionPolicy", "Bypass", "-File", $launcherPath -WorkingDirectory $Workspace -WindowStyle Normal

Write-Host "Opened provider $($providerEntry.name) for task $($taskData.id)" -ForegroundColor Green
Write-Host "Prompt file: $promptPath"
Write-Host "Launcher: $launcherPath"
Write-Host "Log: $logPath"
