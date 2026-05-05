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
    return $null
}

function Get-DispatchableProviders {
    $manifest = Get-ProviderManifest
    return @($manifest.providers | Where-Object { -not (Get-ProviderDispatchBlockReason $_) })
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
                name          = $Provider.name
                runtimeGroup  = $Provider.runtime_group
                costTier      = $Provider.cost_tier
                dispatchCount = 0
                lastProject   = ""
                lastTask      = ""
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

# ---- Worker prompt builder (the heart of the dispatch system) -----------------

function Build-WorkerPrompt {
    param(
        $Project,
        $Task,
        $Provider,
        [string]$ReportPath
    )

    $uniqueContextFiles = @()
    foreach ($item in @($Task.contextFiles)) {
        if (-not [string]::IsNullOrWhiteSpace($item) -and $uniqueContextFiles -notcontains $item) {
            $uniqueContextFiles += $item
        }
    }

    $uniqueReferenceAnchors = @()
    foreach ($item in @($Task.referenceAnchors)) {
        if (-not [string]::IsNullOrWhiteSpace($item) -and $uniqueReferenceAnchors -notcontains $item) {
            $uniqueReferenceAnchors += $item
        }
    }

    $acceptance = if ($Task.acceptanceCriteria) {
        (($Task.acceptanceCriteria | ForEach-Object { "- $_" }) -join "`n")
    }
    else {
        "- Complete the task and explain any residual gaps."
    }

    $allowedPaths = if ($Task.allowedPaths) {
        (($Task.allowedPaths | ForEach-Object { "- $_" }) -join "`n")
    }
    else {
        "- No explicit path limit recorded. Stay tightly scoped."
    }

    $dependsOn = if ($Task.dependsOn) {
        (($Task.dependsOn | ForEach-Object { "- $_" }) -join "`n")
    }
    else {
        "- None recorded."
    }

    $constraints = if ($Task.constraints) {
        (($Task.constraints | ForEach-Object { "- $_" }) -join "`n")
    }
    else {
        "- No extra constraints recorded."
    }

    $contextFiles = if ($uniqueContextFiles) {
        (($uniqueContextFiles | ForEach-Object { "- $_" }) -join "`n")
    }
    else {
        "- None recorded."
    }

    $referenceAnchors = if ($uniqueReferenceAnchors) {
        (($uniqueReferenceAnchors | ForEach-Object { "- $_" }) -join "`n")
    }
    else {
        "- None recorded."
    }

    $supervisorNotes = if ($Task.supervisorNotes) {
        (($Task.supervisorNotes | ForEach-Object { "- $_" }) -join "`n")
    }
    else {
        "- None recorded."
    }

    $referencePath = if ($Project.referenceWorkspace) { $Project.referenceWorkspace } else { "(none)" }

    return @"
You are a worker in a supervised multi-agent coding workflow managed by DeepSeek Autolook.

Provider lane:
- Provider: $($Provider.name)
- Best for: $($Provider.strengths)
- Runtime group: $($Provider.runtime_group)
- Cost tier: $($Provider.cost_tier)

Project:
- Project ID: $($Project.id)
- Project name: $($Project.name)
- Target workspace: $($Project.workspace)
- Reference workspace: $referencePath
- Goal: $($Project.goal)

Task:
- Task ID: $($Task.id)
- Title: $($Task.title)
- Role: $($Task.role)
- Owner: $($Task.owner)
- Priority: $($Task.priority)
- Expected output: $($Task.expectedOutput)
- Objective: $($Task.objective)

Acceptance criteria:
$acceptance

Allowed edit scope:
$allowedPaths

Task dependencies:
$dependsOn

Hard constraints:
$constraints

Context files to read first:
$contextFiles

Reference anchors:
$referenceAnchors

Supervisor notes:
$supervisorNotes

Required workflow:
1. Inspect the target workspace and any directly relevant reference files.
2. Stay within the allowed scope unless the task is impossible without expanding it.
3. Return the final report as markdown on stdout. The supervisor launcher will save it to:
   $ReportPath
4. Structure the report with these sections:
   - Summary
   - Findings
   - Acceptance checklist
   - Files touched
   - Open questions
   - Next recommendation
5. In "Acceptance checklist", copy every acceptance criterion verbatim and mark each one as PASS or FAIL with one-line evidence.
6. If the task changes behavior, cite exact reverse-source files/classes/methods that justify the decision.
7. If you make code changes, include exact file paths in the report.
8. If blocked, explain the blocker in the report and stop there.
9. Output only the report body. Do not add chatty prefaces, tool narration, or surrounding markdown fences unless they are part of the report itself.
10. When your work is submitted, the task should be treated as submitted for review, not automatically done.

Tool-use discipline:
- Do not read large files wholesale unless the file is genuinely short.
- Prefer Grep/search first, then Read only the exact relevant slices.
- Keep each file read focused and small; avoid dumping long documents into context at once.
- For roadmap, audit, ledger, or decompiled files, extract only the lines/classes/methods needed for the current finding.
- If a file is long, build your answer incrementally from multiple targeted reads instead of one full read.
- Treat the listed context files and reference anchors as the primary evidence set; do not wander into unrelated subsystems unless a current finding cannot be justified without that exact file.
- Once you have enough evidence to satisfy the acceptance criteria, stop exploring and write the report.
- For analysis and audit tasks, prefer curated docs and named data classes over broad codebase discovery.

Do not claim to be a different provider. Do not widen the task on your own.
"@
}
