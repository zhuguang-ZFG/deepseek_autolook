# =============================================================================
# supervisor-lib.ps1 — DeepSeek Autolook Supervisor Core Library
# =============================================================================
# Shared functions for the multi-AI supervisor layer.
# Dot-source this file from any supervisor script:
#   . (Join-Path $PSScriptRoot "supervisor-lib.ps1")
# =============================================================================

# ---- Path helpers -----------------------------------------------------------

function Get-ParallelAiRoot {
    return (Split-Path -Parent $PSScriptRoot)
}

function Get-SupervisorRoot {
    return (Join-Path (Get-ParallelAiRoot) "tasks")
}

function Ensure-SupervisorLayout {
    $root = Get-SupervisorRoot
    foreach ($path in @(
            $root,
            (Join-Path $root "projects"),
            (Join-Path $root "templates"),
            (Join-Path $root "runtime"),
            (Join-Path (Join-Path $root "runtime") "events")
        )) {
        New-Item -ItemType Directory -Force -Path $path | Out-Null
    }
    return $root
}

# ---- String utilities -------------------------------------------------------

function ConvertTo-Slug {
    param([string]$Value)
    $slug = $Value.ToLowerInvariant() -replace "[^a-z0-9]+", "-"
    $slug = $slug.Trim("-")
    if ([string]::IsNullOrWhiteSpace($slug)) {
        return "item"
    }
    return $slug
}

function Get-IsoNow {
    return (Get-Date).ToString("s")
}

# ---- JSON I/O ---------------------------------------------------------------

function Read-JsonFile {
    param([string]$Path)
    return (Get-Content $Path -Raw | ConvertFrom-Json)
}

function Write-JsonFile {
    param(
        [string]$Path,
        $Data
    )
    $json = $Data | ConvertTo-Json -Depth 100
    [System.IO.File]::WriteAllText($Path, $json + [Environment]::NewLine, [System.Text.UTF8Encoding]::new($false))
}

# ---- Project helpers --------------------------------------------------------

function Get-ProjectRoot {
    param([string]$ProjectSlug)
    return (Join-Path (Join-Path (Get-SupervisorRoot) "projects") $ProjectSlug)
}

function Get-ProjectFile {
    param([string]$ProjectSlug)
    return (Join-Path (Get-ProjectRoot $ProjectSlug) "project.json")
}

function Ensure-ProjectSchema {
    param($Project)
    if (-not ($Project.PSObject.Properties.Name -contains "status")) {
        $Project | Add-Member -NotePropertyName status -NotePropertyValue "active" -Force
    }
    if (-not ($Project.PSObject.Properties.Name -contains "closeout")) {
        $Project | Add-Member -NotePropertyName closeout -NotePropertyValue ([pscustomobject]@{
                decision        = ""
                checkedAt       = ""
                summary         = ""
                incompleteTasks = @()
                blockedTasks    = @()
            }) -Force
    }
    if (-not ($Project.PSObject.Properties.Name -contains "referenceWorkspace")) {
        $Project | Add-Member -NotePropertyName referenceWorkspace -NotePropertyValue "" -Force
    }
    return $Project
}

function Get-ProjectList {
    Ensure-SupervisorLayout | Out-Null
    $projectsDir = Join-Path (Get-SupervisorRoot) "projects"
    $dirs = Get-ChildItem $projectsDir -Directory -ErrorAction SilentlyContinue | Sort-Object Name
    $items = @()
    foreach ($dir in $dirs) {
        $projectFile = Join-Path $dir.FullName "project.json"
        if (Test-Path $projectFile) {
            $items += Read-JsonFile $projectFile
        }
    }
    return $items
}

# ---- Task helpers -----------------------------------------------------------

function Get-TaskFile {
    param(
        [string]$ProjectSlug,
        [string]$TaskId
    )
    return (Join-Path (Join-Path (Get-ProjectRoot $ProjectSlug) "tasks") ($TaskId + ".json"))
}

function Get-TaskReportPath {
    param(
        [string]$ProjectSlug,
        [string]$TaskId,
        [string]$ProviderSlug
    )
    return (Join-Path (Join-Path (Get-ProjectRoot $ProjectSlug) "reports") ($TaskId + "--" + $ProviderSlug + ".md"))
}

function Ensure-TaskSchema {
    param($Task)

    $defaults = @{
        owner              = ""
        expectedOutput     = "report"
        priority           = "P1"
        review             = [pscustomobject]@{
            decision       = ""
            reviewedAt     = ""
            reviewer       = ""
            summary        = ""
            missingCriteria = @()
        }
        notes              = @()
        preferredWorkers   = @()
        fallbackWorkers    = @()
        assignmentHistory  = @()
        dependsOn          = @()
        constraints        = @()
        contextFiles       = @()
        referenceAnchors   = @()
        supervisorNotes    = @()
        leaseMinutes       = 30
        leasedAt           = ""
        heartbeatAt        = ""
        attemptCount       = 0
        maxAttempts        = 3
        lastFailureReason  = ""
        lastRecoveredAt    = ""
        autoRedispatch     = $true
    }

    foreach ($key in $defaults.Keys) {
        if (-not ($Task.PSObject.Properties.Name -contains $key)) {
            $Task | Add-Member -NotePropertyName $key -NotePropertyValue $defaults[$key] -Force
        }
    }

    return $Task
}

function Get-TaskList {
    param([string]$ProjectSlug)
    $taskDir = Join-Path (Get-ProjectRoot $ProjectSlug) "tasks"
    $files = Get-ChildItem $taskDir -Filter *.json -File -ErrorAction SilentlyContinue | Sort-Object Name
    $items = @()
    foreach ($file in $files) {
        $items += Ensure-TaskSchema (Read-JsonFile $file.FullName)
    }
    return $items
}

# ---- Task lease management --------------------------------------------------

function Get-DateOrNull {
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) {
        return $null
    }
    try {
        return [datetime]::Parse($Value)
    }
    catch {
        return $null
    }
}

function Get-TaskLeaseExpiry {
    param($Task)
    $start = Get-DateOrNull $Task.heartbeatAt
    if (-not $start) {
        $start = Get-DateOrNull $Task.leasedAt
    }
    if (-not $start) {
        return $null
    }
    $leaseMinutes = 30
    if ($Task.leaseMinutes -and [int]$Task.leaseMinutes -gt 0) {
        $leaseMinutes = [int]$Task.leaseMinutes
    }
    return $start.AddMinutes($leaseMinutes)
}

function Clear-TaskLease {
    param($Task)
    $Task.leasedAt = ""
    $Task.heartbeatAt = ""
    return $Task
}

function Start-TaskLease {
    param($Task)
    $now = Get-IsoNow
    $Task.leasedAt = $now
    $Task.heartbeatAt = $now
    return $Task
}

# ---- Failure classification -------------------------------------------------

function Get-TaskFailureClassificationFromText {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) {
        return ""
    }
    $rules = @(
        @{ pattern = "(?i)rate limit|too many requests|quota exceeded|usage limit|429"; reason = "rate-limited" }
        @{ pattern = "(?i)context length|token limit|max tokens"; reason = "context-limited" }
        @{ pattern = "(?i)network error|connection reset|timed out|timeout|econnreset|econnrefused"; reason = "provider-unavailable" }
        @{ pattern = "(?i)permission denied|access denied|forbidden|unauthorized|401|403"; reason = "permission-blocked" }
        @{ pattern = "(?i)manual stop|cancelled by user|interrupted"; reason = "manual-stop" }
    )
    foreach ($rule in $rules) {
        if ($Text -match $rule.pattern) {
            return $rule.reason
        }
    }
    return "unknown"
}

# ---- Worker routing ----------------------------------------------------------

function Get-WorkerPreferenceOrder {
    param($Task)
    $ordered = @()
    foreach ($worker in @($Task.preferredWorkers)) {
        if (-not [string]::IsNullOrWhiteSpace($worker) -and $ordered -notcontains $worker) {
            $ordered += $worker
        }
    }
    if (-not [string]::IsNullOrWhiteSpace($Task.owner) -and $ordered -notcontains $Task.owner) {
        $ordered += $Task.owner
    }
    foreach ($worker in @($Task.fallbackWorkers)) {
        if (-not [string]::IsNullOrWhiteSpace($worker) -and $ordered -notcontains $worker) {
            $ordered += $worker
        }
    }
    return $ordered
}

function Add-AssignmentHistoryEntry {
    param(
        $Task,
        [string]$Worker,
        [string]$Outcome,
        [string]$Reason
    )
    $stamp = Get-IsoNow
    $entry = [pscustomobject]@{
        worker  = $Worker
        outcome = $Outcome
        reason  = $Reason
        at      = $stamp
    }
    $Task.assignmentHistory = @($Task.assignmentHistory) + $entry
    $Task.updatedAt = $stamp
    return $Task
}

function Test-TaskDependenciesSatisfied {
    param(
        [string]$ProjectSlug,
        $Task
    )
    foreach ($dependencyId in @($Task.dependsOn)) {
        if ([string]::IsNullOrWhiteSpace($dependencyId)) {
            continue
        }
        $dependencyFile = Get-TaskFile -ProjectSlug $ProjectSlug -TaskId $dependencyId
        if (-not (Test-Path $dependencyFile)) {
            return $false
        }
        $dependencyTask = Ensure-TaskSchema (Read-JsonFile $dependencyFile)
        if ($dependencyTask.status -ne "done") {
            return $false
        }
    }
    return $true
}

function Get-ReadyDispatchTasks {
    param([string]$ProjectSlug)
    $priorityRank = @{
        "P0" = 0
        "P1" = 1
        "P2" = 2
        "P3" = 3
    }
    return @(
        Get-TaskList $ProjectSlug |
        Where-Object {
            $_.status -eq "ready" -and (Test-TaskDependenciesSatisfied -ProjectSlug $ProjectSlug -Task $_)
        } |
        Sort-Object @{
            Expression = {
                if ($priorityRank.ContainsKey([string]$_.priority)) {
                    $priorityRank[[string]$_.priority]
                }
                else {
                    99
                }
            }
        }, @{
            Expression = { $_.id }
        }
    )
}

# ---- Provider manifest -------------------------------------------------------

function Get-ProviderManifestPath {
    return (Join-Path (Get-ParallelAiRoot) "providers.manifest.json")
}

function Get-ProviderManifest {
    $path = Get-ProviderManifestPath
    if (-not (Test-Path $path)) {
        throw "Provider manifest missing: $path. Run sync-parallel-providers.py first."
    }
    return (Get-Content $path -Raw | ConvertFrom-Json)
}

function Get-ProviderRuntimeHealthPath {
    return (Join-Path (Get-SupervisorRuntimeRoot) "provider-health.json")
}

function Get-ProviderRuntimeHealth {
    $path = Get-ProviderRuntimeHealthPath
    if (-not (Test-Path $path)) {
        return [pscustomobject]@{ providers = [pscustomobject]@{} }
    }
    $data = Get-Content $path -Raw | ConvertFrom-Json
    if (-not $data) {
        return [pscustomobject]@{ providers = [pscustomobject]@{} }
    }
    if (-not ($data.PSObject.Properties.Name -contains "providers")) {
        $data | Add-Member -NotePropertyName providers -NotePropertyValue ([pscustomobject]@{}) -Force
    }
    return $data
}

function Save-ProviderRuntimeHealth {
    param($Data)
    Write-JsonFile -Path (Get-ProviderRuntimeHealthPath) -Data $Data
}

function Ensure-ProviderRuntimeHealthEntry {
    param(
        $HealthData,
        [string]$ProviderSlug
    )
    if (-not ($HealthData.providers.PSObject.Properties.Name -contains $ProviderSlug)) {
        $HealthData.providers | Add-Member -NotePropertyName $ProviderSlug -NotePropertyValue ([pscustomobject]@{
                failureCount      = 0
                disabledUntil     = ""
                disabledReason    = ""
                lastFailureAt     = ""
                lastFailureReason = ""
                lastRecoveredAt   = ""
            }) -Force
    }
    return $HealthData.providers.$ProviderSlug
}

function Get-ProviderRuntimeHealthEntry {
    param([string]$ProviderSlug)
    $health = Get-ProviderRuntimeHealth
    return Ensure-ProviderRuntimeHealthEntry -HealthData $health -ProviderSlug $ProviderSlug
}

function Reset-ProviderRuntimePenalty {
    param([string]$ProviderSlug)
    if ([string]::IsNullOrWhiteSpace($ProviderSlug)) {
        return
    }
    $health = Get-ProviderRuntimeHealth
    $entry = Ensure-ProviderRuntimeHealthEntry -HealthData $health -ProviderSlug $ProviderSlug
    $entry.failureCount = 0
    $entry.disabledUntil = ""
    $entry.disabledReason = ""
    $entry.lastRecoveredAt = Get-IsoNow
    Save-ProviderRuntimeHealth -Data $health
}

function Register-ProviderFailure {
    param(
        [string]$ProviderSlug,
        [string]$Reason
    )
    if ([string]::IsNullOrWhiteSpace($ProviderSlug)) {
        return
    }
    $recoverableReasons = @("rate-limited", "provider-unavailable", "context-limited", "worker-exited")
    if ($recoverableReasons -notcontains $Reason) {
        return
    }

    $health = Get-ProviderRuntimeHealth
    $entry = Ensure-ProviderRuntimeHealthEntry -HealthData $health -ProviderSlug $ProviderSlug
    $entry.failureCount = [int]$entry.failureCount + 1
    $entry.lastFailureAt = Get-IsoNow
    $entry.lastFailureReason = $Reason

    if ([int]$entry.failureCount -ge 2) {
        $minutes = if ($Reason -eq "rate-limited") { 30 } else { 15 }
        $entry.disabledUntil = (Get-Date).AddMinutes($minutes).ToString("s")
        $entry.disabledReason = ("runtime-health:" + $Reason)
    }

    Save-ProviderRuntimeHealth -Data $health
}

function Get-ProviderDispatchBlockReason {
    param($Provider)
    if (-not $Provider) {
        return "provider-missing"
    }
    if (($Provider.PSObject.Properties.Name -contains "dispatch_enabled") -and
        (-not [bool]$Provider.dispatch_enabled)) {
        if (($Provider.PSObject.Properties.Name -contains "dispatch_disabled_reason") -and
            -not [string]::IsNullOrWhiteSpace($Provider.dispatch_disabled_reason)) {
            return [string]$Provider.dispatch_disabled_reason
        }
        return "dispatch-disabled"
    }
    $health = Get-ProviderRuntimeHealth
    $entry = Ensure-ProviderRuntimeHealthEntry -HealthData $health -ProviderSlug $Provider.slug
    $disabledUntil = Get-DateOrNull $entry.disabledUntil
    if ($disabledUntil -and $disabledUntil -gt (Get-Date)) {
        if (-not [string]::IsNullOrWhiteSpace($entry.disabledReason)) {
            return [string]$entry.disabledReason
        }
        return "runtime-health-disabled"
    }
    if ($disabledUntil -and $disabledUntil -le (Get-Date)) {
        $entry.failureCount = 0
        $entry.disabledUntil = ""
        $entry.disabledReason = ""
        $entry.lastRecoveredAt = Get-IsoNow
        Save-ProviderRuntimeHealth -Data $health
    }
    return $null
}

function Get-DispatchableProviders {
    $manifest = Get-ProviderManifest
    return @($manifest.providers | Where-Object { -not (Get-ProviderDispatchBlockReason $_) })
}

function Get-StableDispatchProviders {
    return @(
        Get-DispatchableProviders |
        Where-Object {
            ($_.PSObject.Properties.Name -contains "stable_candidate") -and
            [bool]$_.stable_candidate
        } |
        Sort-Object dispatch_priority, name
    )
}

function Get-StableWorkerNames {
    return @(
        Get-StableDispatchProviders | ForEach-Object { $_.name }
    )
}

function Get-StableHealthcheckProviders {
    return @(
        Get-DispatchableProviders |
        Where-Object {
            ($_.PSObject.Properties.Name -contains "healthcheck_candidate") -and
            [bool]$_.healthcheck_candidate
        } |
        Sort-Object dispatch_priority, name
    )
}

function Test-IsStableWorkerName {
    param([string]$WorkerName)
    if ([string]::IsNullOrWhiteSpace($WorkerName)) {
        return $false
    }
    return @(Get-StableWorkerNames) -icontains $WorkerName
}

function Get-PreferredDispatchWorkerOrder {
    param($Task)

    $candidateWorkers = @()
    foreach ($worker in @(Get-WorkerPreferenceOrder $Task)) {
        if ([string]::IsNullOrWhiteSpace($worker)) {
            continue
        }
        if ($candidateWorkers -icontains $worker) {
            continue
        }
        if ($worker -ieq "cursor") {
            continue
        }
        $candidateWorkers += $worker
    }

    $ordered = @()
    foreach ($provider in @(Get-StableDispatchProviders)) {
        foreach ($worker in $candidateWorkers) {
            if ($worker -ieq $provider.name -or $worker -ieq $provider.slug) {
                if ($ordered -notcontains $worker) {
                    $ordered += $worker
                }
            }
        }
    }

    foreach ($worker in $candidateWorkers) {
        if ($ordered -icontains $worker) {
            continue
        }
        $ordered += $worker
    }
    return $ordered
}

function Find-ProviderEntry {
    param(
        [string]$Provider,
        [switch]$IncludeDisabled
    )
    $providers = if ($IncludeDisabled) { @((Get-ProviderManifest).providers) } else { @(Get-DispatchableProviders) }
    $exact = $providers | Where-Object {
        $_.slug -ieq $Provider -or $_.name -ieq $Provider
    } | Select-Object -First 1
    if ($exact) {
        return $exact
    }
    $prefix = $Provider + "*"
    return $providers | Where-Object {
        $_.slug -like $prefix -or $_.name -like $prefix
    } | Select-Object -First 1
}

function Get-ProviderPolicySummary {
    param($Provider)
    return ("runtime={0}, cost={1}, policy={2}" -f $Provider.runtime_group, $Provider.cost_tier, $Provider.budget_policy)
}

# ---- Local lock (serial lane for Ollama) ------------------------------------

function Get-LocalLockPath {
    return (Join-Path (Get-SupervisorRuntimeRoot) "local-provider-lock.json")
}

function Get-LocalLock {
    $path = Get-LocalLockPath
    if (-not (Test-Path $path)) {
        return $null
    }
    return (Get-Content $path -Raw | ConvertFrom-Json)
}

function Set-LocalLock {
    param(
        [string]$Project,
        [string]$Task,
        $Provider
    )
    $data = [ordered]@{
        project      = $Project
        task         = $Task
        provider     = $Provider.slug
        providerName = $Provider.name
        lockedAt     = Get-IsoNow
    }
    Write-JsonFile -Path (Get-LocalLockPath) -Data $data
}

function Clear-LocalLock {
    param(
        [string]$Project,
        [string]$Task
    )
    $path = Get-LocalLockPath
    if (-not (Test-Path $path)) {
        return
    }
    $lock = Get-LocalLock
    if (-not $Project -and -not $Task) {
        Remove-Item -LiteralPath $path -Force
        return
    }
    if ($lock -and $lock.project -eq $Project -and $lock.task -eq $Task) {
        Remove-Item -LiteralPath $path -Force
    }
}

# ---- Provider usage tracking -------------------------------------------------

function Get-UsageFilePath {
    return (Join-Path (Get-SupervisorRuntimeRoot) "provider-usage.json")
}

function Get-ProviderUsage {
    $path = Get-UsageFilePath
    if (-not (Test-Path $path)) {
        return [pscustomobject]@{ providers = [pscustomobject]@{} }
    }
    $data = Get-Content $path -Raw | ConvertFrom-Json
    if (-not $data) {
        return [pscustomobject]@{ providers = [pscustomobject]@{} }
    }
    if (-not ($data.PSObject.Properties.Name -contains "providers")) {
        $data | Add-Member -NotePropertyName providers -NotePropertyValue ([pscustomobject]@{}) -Force
    }
    return $data
}

function Update-ProviderUsage {
    param(
        $Provider,
        [string]$Project,
        [string]$Task
    )
    $usage = Get-ProviderUsage
    if (-not ($usage.PSObject.Properties.Name -contains "providers")) {
        $usage | Add-Member -NotePropertyName providers -NotePropertyValue ([pscustomobject]@{}) -Force
    }
    if (-not ($usage.providers.PSObject.Properties.Name -contains $Provider.slug)) {
        $usage.providers | Add-Member -NotePropertyName $Provider.slug -NotePropertyValue ([pscustomobject]@{
                name           = $Provider.name
                runtimeGroup   = $Provider.runtime_group
                costTier       = $Provider.cost_tier
                dispatchCount  = 0
                successCount   = 0
                failureCount   = 0
                lastProject    = ""
                lastTask       = ""
                lastDispatchAt = ""
            }) -Force
    }
    $entry = $usage.providers.$($Provider.slug)
    $entry.name = $Provider.name
    $entry.runtimeGroup = $Provider.runtime_group
    $entry.costTier = $Provider.cost_tier
    $entry.dispatchCount = [int]$entry.dispatchCount + 1
    $entry.lastProject = $Project
    $entry.lastTask = $Task
    $entry.lastDispatchAt = Get-IsoNow
    Write-JsonFile -Path (Get-UsageFilePath) -Data $usage
}

function Update-ProviderSuccessRate {
    param(
        [string]$ProviderSlug,
        [bool]$Success
    )
    if ([string]::IsNullOrWhiteSpace($ProviderSlug)) { return }
    $usage = Get-ProviderUsage
    if (-not ($usage.providers.PSObject.Properties.Name -contains $ProviderSlug)) { return }
    $entry = $usage.providers.$ProviderSlug
    if ($Success) {
        $entry.successCount = [int]$entry.successCount + 1
    } else {
        $entry.failureCount = [int]$entry.failureCount + 1
    }
    Write-JsonFile -Path (Get-UsageFilePath) -Data $usage
}

# ---- Supervisor events -------------------------------------------------------

function Get-SupervisorRuntimeRoot {
    Ensure-SupervisorLayout | Out-Null
    return (Join-Path (Get-SupervisorRoot) "runtime")
}

function Get-SupervisorEventsRoot {
    Ensure-SupervisorLayout | Out-Null
    return (Join-Path (Get-SupervisorRuntimeRoot) "events")
}

function Write-SupervisorEvent {
    param(
        [string]$Type,
        [string]$Project,
        [string]$Task,
        [string]$Worker,
        [string]$Status,
        [string]$Summary,
        [string]$FilesTouched,
        [hashtable]$Extra
    )
    $stamp = Get-IsoNow
    $safeType = if ([string]::IsNullOrWhiteSpace($Type)) { "event" } else { (ConvertTo-Slug $Type) }
    $safeTask = if ([string]::IsNullOrWhiteSpace($Task)) { "task" } else { (ConvertTo-Slug $Task) }
    $eventId = "{0}--{1}--{2}" -f $stamp.Replace(":", "").Replace("T", "-"), $safeTask, $safeType
    $payload = [ordered]@{
        id           = $eventId
        type         = $Type
        project      = $Project
        task         = $Task
        worker       = $Worker
        status       = $Status
        summary      = $Summary
        filesTouched = $FilesTouched
        at           = $stamp
    }
    if ($Extra) {
        foreach ($key in $Extra.Keys) {
            $payload[$key] = $Extra[$key]
        }
    }
    $path = Join-Path (Get-SupervisorEventsRoot) ($eventId + ".json")
    Write-JsonFile -Path $path -Data ([pscustomobject]$payload)
    return $path
}

# ---- Cursor support ----------------------------------------------------------

function Get-CursorCliPath {
    $cmd = Get-Command cursor.cmd -ErrorAction SilentlyContinue
    if ($cmd) {
        return $cmd.Source
    }
    $fallback = "C:\Program Files\cursor\resources\app\bin\cursor.cmd"
    if (Test-Path $fallback) {
        return $fallback
    }
    return $null
}

# ---- Project structure -------------------------------------------------------

function Ensure-ProjectStructure {
    param([string]$ProjectSlug)
    $root = Get-ProjectRoot $ProjectSlug
    foreach ($path in @(
            $root,
            (Join-Path $root "tasks"),
            (Join-Path $root "reports"),
            (Join-Path $root "prompts"),
            (Join-Path $root "context"),
            (Join-Path $root "artifacts")
        )) {
        New-Item -ItemType Directory -Force -Path $path | Out-Null
    }
    return $root
}

# ---- Worker prompt builders (static-prefix-first for Anthropic prompt caching) ---

# Static prompt prefix — identical for every dispatch, cached once by the API
$Script:WorkerPromptPrefix = @'
You are a worker in a supervised multi-agent coding workflow managed by DeepSeek Autolook.

Required workflow:
1. Inspect the target workspace and any directly relevant reference files.
2. Stay within the allowed scope unless the task is impossible without expanding it.
3. Return the final report as markdown on stdout. The supervisor launcher will save it to
   the report path specified below.
4. Structure the report with these sections:
   - Summary
   - Findings
   - Acceptance checklist
   - Files touched
   - Open questions
   - Next recommendation
5. In "Acceptance checklist", copy every acceptance criterion verbatim and mark each
   one as PASS or FAIL with one-line evidence.
6. If the task changes behavior, cite exact reverse-source files/classes/methods that
   justify the decision.
7. If you make code changes, include exact file paths in the report.
8. If blocked, explain the blocker in the report and stop there.
9. Output only the report body. Do not add chatty prefaces, tool narration, or
   surrounding markdown fences unless they are part of the report itself.
10. When your work is submitted, the task should be treated as submitted for review,
    not automatically done.

Tool-use discipline:
- Do not read large files wholesale unless the file is genuinely short.
- Prefer Grep/search first, then Read only the exact relevant slices.
- Keep each file read focused and small; avoid dumping long documents into context at once.
- For roadmap, audit, ledger, or decompiled files, extract only the lines/classes/methods
  needed for the current finding.
- If a file is long, build your answer incrementally from multiple targeted reads instead
  of one full read.
- Treat the listed context files and reference anchors as the primary evidence set; do not
  wander into unrelated subsystems unless a current finding cannot be justified without
  that exact file.
- Once you have enough evidence to satisfy the acceptance criteria, stop exploring and
  write the report.
- For analysis and audit tasks, prefer curated docs and named data classes over broad
  codebase discovery.

Do not claim to be a different provider. Do not widen the task on your own.

--- TASK DETAILS FOLLOW ---
'@

function Build-WorkerPrompt {
    param(
        $Project,
        $Task,
        $Provider,
        [string]$ReportPath
    )

    $referencePath = if ($Project.referenceWorkspace) { $Project.referenceWorkspace } else { "(none)" }

    # --- Build variable suffix (per-task, short) ---
    $lines = @()

    $lines += ""
    $lines += "Report path: $ReportPath"
    $lines += ""
    $lines += "Provider lane:"
    $lines += "- Name: $($Provider.name)"
    $lines += "- Best for: $($Provider.strengths)"
    $lines += "- Runtime: $($Provider.runtime_group)"
    $lines += "- Cost tier: $($Provider.cost_tier)"
    $lines += ""
    $lines += "Project:"
    $lines += "- ID: $($Project.id)"
    $lines += "- Name: $($Project.name)"
    $lines += "- Workspace: $($Project.workspace)"
    $lines += "- Reference: $referencePath"
    $lines += "- Goal: $($Project.goal)"
    $lines += ""
    $lines += "Task:"
    $lines += "- ID: $($Task.id)"
    $lines += "- Title: $($Task.title)"
    $lines += "- Role: $($Task.role)"
    $lines += "- Priority: $($Task.priority)"
    $lines += "- Expected output: $($Task.expectedOutput)"
    $lines += "- Objective: $($Task.objective)"

    if ($Task.acceptanceCriteria -and @($Task.acceptanceCriteria).Count -gt 0) {
        $lines += ""
        $lines += "Acceptance criteria:"
        foreach ($c in $Task.acceptanceCriteria) { $lines += "- $c" }
    }
    else {
        $lines += ""
        $lines += "Acceptance criteria:"
        $lines += "- Complete the task and explain any residual gaps."
    }

    if ($Task.allowedPaths -and @($Task.allowedPaths).Count -gt 0) {
        $lines += ""
        $lines += "Allowed edit scope:"
        foreach ($p in $Task.allowedPaths) { $lines += "- $p" }
    }

    if ($Task.dependsOn -and @($Task.dependsOn).Count -gt 0) {
        $lines += ""
        $lines += "Task dependencies:"
        foreach ($d in $Task.dependsOn) { $lines += "- $d" }
    }

    if ($Task.constraints -and @($Task.constraints).Count -gt 0) {
        $lines += ""
        $lines += "Hard constraints:"
        foreach ($c in $Task.constraints) { $lines += "- $c" }
    }

    if ($Task.contextFiles -and @($Task.contextFiles).Count -gt 0) {
        $lines += ""
        $lines += "Context files:"
        foreach ($f in ($Task.contextFiles | Select-Object -Unique)) {
            if (-not [string]::IsNullOrWhiteSpace($f)) { $lines += "- $f" }
        }
    }

    if ($Task.supervisorNotes -and @($Task.supervisorNotes).Count -gt 0) {
        $lines += ""
        $lines += "Supervisor notes:"
        foreach ($n in $Task.supervisorNotes) { $lines += "- $n" }
    }

    return $Script:WorkerPromptPrefix + ($lines -join "`n")
}

# ---- Reviewer prompt builder ---------------------------------------------------

$Script:ReviewerPromptPrefix = @'
You are an automated reviewer in the DeepSeek Autolook supervisor system.
Your only job is to read a worker's report and decide whether it satisfies
the acceptance criteria.

Output ONLY a JSON object with this exact structure (no markdown fences, no extra text):
{
  "decision": "done" | "rework" | "blocked",
  "summary": "one-line summary of what you found",
  "missingCriteria": ["criterion that was not met", "..."],
  "notes": "optional extra notes"
}

Rules:
- Mark "done" ONLY if every acceptance criterion is convincingly PASS.
- Mark "rework" if any criterion is FAIL or not addressed.
- Mark "blocked" only if the worker explicitly reports a blocker that prevents progress.
- Be strict but fair. A vague report with no evidence is NOT a pass.
- If the report does not contain an "Acceptance checklist" section, treat it as FAIL
  for all criteria and mark "rework".
- Do not add explanations, apologies, or markdown around the JSON.
'@

function Build-ReviewerPrompt {
    param(
        $Task,
        [string]$ReportContent
    )

    $lines = @()
    $lines += ""
    $lines += "Task to review:"
    $lines += "- ID: $($Task.id)"
    $lines += "- Title: $($Task.title)"
    $lines += "- Objective: $($Task.objective)"

    if ($Task.acceptanceCriteria -and @($Task.acceptanceCriteria).Count -gt 0) {
        $lines += ""
        $lines += "Acceptance criteria:"
        foreach ($c in $Task.acceptanceCriteria) { $lines += "- $c" }
    }

    $lines += ""
    $lines += "Worker report:"
    $lines += "--- BEGIN REPORT ---"
    if ($ReportContent.Length -gt 16000) {
        $lines += $ReportContent.Substring(0, 16000)
        $lines += "... [report truncated to 16000 chars]"
    }
    else {
        $lines += $ReportContent
    }
    $lines += "--- END REPORT ---"

    return $Script:ReviewerPromptPrefix + ($lines -join "`n")
}

# Auto-review dispatch: pipe reviewer prompt through Claude Code
function Invoke-AutoReview {
    param(
        [string]$Project,
        $Task,
        [string]$ReportContent,
        [string]$ReviewerProvider = "github-gpt-5-mini"
    )

    $reviewer = Find-ProviderEntry -Provider $ReviewerProvider
    if (-not $reviewer) {
        Write-Host "Auto-review: reviewer provider not found: $ReviewerProvider" -ForegroundColor Yellow
        return $null
    }

    $prompt = Build-ReviewerPrompt -Task $Task -ReportContent $ReportContent
    $settingsPath = $reviewer.settings_path

    Write-Host "Auto-review: dispatching to $($reviewer.name)..." -ForegroundColor Cyan

    try {
        $result = $prompt | claude -p --settings $settingsPath --output-format text --permission-mode bypassPermissions --dangerously-skip-permissions 2>&1
        $resultText = ($result | Out-String).Trim()

        # Try to extract JSON
        $jsonMatch = [regex]::Match($resultText, '\{[\s\S]*"decision"[\s\S]*\}')
        if ($jsonMatch.Success) {
            $reviewResult = $jsonMatch.Value | ConvertFrom-Json
            return $reviewResult
        }

        # Fallback: try to parse whole output
        try {
            return ($resultText | ConvertFrom-Json)
        }
        catch {
            Write-Host "Auto-review: could not parse JSON from reviewer output" -ForegroundColor Yellow
            Write-Host "Raw output (first 500 chars): $($resultText.Substring(0, [Math]::Min(500, $resultText.Length)))" -ForegroundColor DarkGray
            return $null
        }
    }
    catch {
        Write-Host "Auto-review failed: $_" -ForegroundColor Red
        return $null
    }
}

function Apply-AutoReviewResult {
    param(
        [string]$Project,
        $Task,
        $ReviewResult
    )

    if (-not $ReviewResult) { return }

    $taskFile = Get-TaskFile -ProjectSlug $Project -TaskId $Task.id
    if (-not (Test-Path $taskFile)) { return }

    $taskData = Ensure-TaskSchema (Read-JsonFile $taskFile)

    $decision = $ReviewResult.decision
    $summary = if ($ReviewResult.summary) { [string]$ReviewResult.summary } else { "" }
    $missing = @($ReviewResult.missingCriteria)

    if ($decision -eq "done") {
        $taskData.status = "done"
        $taskData.review = [pscustomobject]@{
            decision        = "done"
            reviewedAt      = Get-IsoNow
            reviewer        = "auto-review"
            summary         = $summary
            missingCriteria = $missing
        }
        Update-ProviderSuccessRate -ProviderSlug $taskData.lastProvider -Success $true
        Write-Host "Auto-review: PASS -> done" -ForegroundColor Green
    }
    elseif ($decision -eq "rework") {
        $taskData.status = "rework"
        $taskData.review = [pscustomobject]@{
            decision        = "rework"
            reviewedAt      = Get-IsoNow
            reviewer        = "auto-review"
            summary         = $summary
            missingCriteria = $missing
        }
        Update-ProviderSuccessRate -ProviderSlug $taskData.lastProvider -Success $false
        Write-Host "Auto-review: FAIL -> rework ($summary)" -ForegroundColor Magenta
    }
    elseif ($decision -eq "blocked") {
        $taskData.status = "blocked"
        Write-Host "Auto-review: BLOCKED" -ForegroundColor Red
    }
    else {
        Write-Host "Auto-review: unknown decision '$decision', leaving as submitted" -ForegroundColor Yellow
        return
    }

    $taskData.updatedAt = Get-IsoNow
    Write-JsonFile -Path $taskFile -Data $taskData
    Clear-LocalLock -Project $Project -Task $Task.id
    Write-SupervisorEvent -Type "auto-reviewed" -Project $Project -Task $Task.id -Worker $taskData.owner -Status $decision -Summary $summary -FilesTouched "" | Out-Null
}
