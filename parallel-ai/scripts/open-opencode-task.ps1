# =============================================================================
# open-opencode-task.ps1 — OpenCode Worker Integration
# =============================================================================
# 用法:
#   open-opencode-task.ps1 -Project my-project -Task task-id -Provider zhipu-glm
#   open-opencode-task.ps1 -Project my-project -Task task-id -Free  (自动选免费模型)
# =============================================================================

param(
    [string]$Project,
    [string]$Task,
    [string]$Provider,
    [string]$Workspace = (Get-Location).Path,
    [switch]$Free
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "supervisor-lib.ps1")

$opencode = Get-Command opencode.cmd -ErrorAction SilentlyContinue
if (-not $opencode) { throw "OpenCode not found. Install: npm install -g opencode-ai" }

if (-not $Project) { $Project = Read-Host "Project slug" }
if (-not $Task) { $Task = Read-Host "Task ID" }

$projectFile = Get-ProjectFile $Project
$taskFile = Get-TaskFile -ProjectSlug $Project -TaskId $Task
if (-not (Test-Path $projectFile)) { throw "Project not found: $projectFile" }
if (-not (Test-Path $taskFile)) { throw "Task not found: $taskFile" }

$projectData = Read-JsonFile $projectFile
$taskData = Ensure-TaskSchema (Read-JsonFile $taskFile)

# ---- 智能体选择：免费模式 or 指定提供者 ----
if ($Free -or (-not $Provider)) {
    $manifest = Get-ProviderManifest
    # 过滤免费 + 可用 + 未被禁用
    $freeCandidates = @($manifest.providers | Where-Object {
        $_.cost_tier -eq "cheap" -and
        $_.runtime_group -eq "cloud" -and
        -not (Get-ProviderDispatchBlockReason $_)
    } | Sort-Object dispatch_priority, name)

    if (-not $freeCandidates) {
        Write-Host "没有可用的免费云模型" -ForegroundColor Red
        return
    }

    # 智能选择：匹配任务角色
    $role = $taskData.role.ToLower()
    $selected = $null

    # 审查类任务 → nemotron (compact reasoning)
    if ($role -match "review|check|validate|inspect") {
        $selected = $freeCandidates | Where-Object { $_.slug -match "nemotron" } | Select-Object -First 1
    }
    # 中文任务 → GLM
    if (-not $selected -and ($taskData.objective -match "[\u4e00-\u9fff]")) {
        $selected = $freeCandidates | Where-Object { $_.slug -match "glm|zhipu" } | Select-Object -First 1
    }
    # 创意/生成任务 → minimax
    if (-not $selected -and $role -match "create|generate|write|draft")) {
        $selected = $freeCandidates | Where-Object { $_.slug -match "minimax" } | Select-Object -First 1
    }
    # 快速扫描 → spark-lite
    if (-not $selected -and $role -match "scan|list|summar")) {
        $selected = $freeCandidates | Where-Object { $_.slug -match "spark" } | Select-Object -First 1
    }
    # 默认：openrouter/free (通用)
    if (-not $selected) {
        $selected = $freeCandidates | Where-Object { $_.slug -eq "openrouter-free" } | Select-Object -First 1
    }
    # 最后 fallback：第一个免费可用
    if (-not $selected) { $selected = $freeCandidates[0] }

    Write-Host "免费智能体选择:" -ForegroundColor Cyan
    Write-Host "  任务角色: $($taskData.role)" -ForegroundColor DarkGray
    Write-Host "  匹配结果: $($selected.name) [$($selected.strengths)]" -ForegroundColor Green

    $providerEntry = $selected
} else {
    $providerEntry = Find-ProviderEntry -Provider $Provider
    if (-not $providerEntry) { throw "Provider not found: $Provider" }
}

# ---- 构建 prompt + 启动 OpenCode ----
$reportPath = Get-TaskReportPath -ProjectSlug $Project -TaskId $Task -ProviderSlug $providerEntry.slug
$promptPath = Join-Path (Join-Path (Get-ProjectRoot $Project) "prompts") ($Task + "--opencode-" + $providerEntry.slug + ".txt")

# 构建简化的 OpenCode prompt（不需要 Claude Code 特定指令）
$workerPrompt = @"
You are a worker in the DeepSeek Autolook supervisor system, running via OpenCode.

Project: $($projectData.name)
Goal: $($projectData.goal)

Task: $($taskData.id) — $($taskData.title)
Objective: $($taskData.objective)
Priority: $($taskData.priority)

Acceptance criteria:
$(($taskData.acceptanceCriteria | ForEach-Object { "- $_" }) -join "`n")

Allowed scope:
$(if ($taskData.allowedPaths) { ($taskData.allowedPaths | ForEach-Object { "- $_" }) -join "`n" } else { "- No explicit limit." })

When finished, write a report to: $reportPath
Sections: Summary, Findings, Acceptance checklist (PASS/FAIL each criterion), Files touched, Open questions.
"@

[System.IO.File]::WriteAllText($promptPath, $workerPrompt + [Environment]::NewLine, [System.Text.UTF8Encoding]::new($false))

# 标记分派
$taskData.status = "dispatched"
$taskData.lastProvider = $providerEntry.slug
$taskData.owner = "opencode:" + $providerEntry.slug
$taskData = Start-TaskLease -Task $taskData
$reason = if ($Free) { "opencode-free" } else { "opencode-manual" }
$taskData = Add-AssignmentHistoryEntry -Task $taskData -Worker $taskData.owner -Outcome "delegated" -Reason $reason
$taskData.updatedAt = Get-IsoNow
Write-JsonFile -Path $taskFile -Data $taskData

# 启动 OpenCode 窗口
Write-Host "启动 OpenCode: $($providerEntry.name)" -ForegroundColor Green
Start-Process powershell.exe -ArgumentList "-NoExit", "-Command", "Set-Location '$Workspace'; opencode" -WindowStyle Normal

Write-Host "Prompt: $promptPath"
Write-Host "Report: $reportPath"
Write-Host "Task $Task dispatched to OpenCode ($($providerEntry.name))" -ForegroundColor Green
