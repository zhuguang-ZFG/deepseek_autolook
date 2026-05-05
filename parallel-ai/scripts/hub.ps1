# =============================================================================
# hub.ps1 — DeepSeek TUI 作为编排中枢
# =============================================================================
# 在 DeepSeek TUI 会话中直接运行，管理整个多 AI 工作流。
# 用法：
#   . .\parallel-ai\scripts\hub.ps1
#   Start-Hub -Project my-project
# =============================================================================

. (Join-Path $PSScriptRoot "supervisor-lib.ps1")

# ---- 中枢状态 ---------------------------------------------------------------

function Write-HubBanner {
    Write-Host ""
    Write-Host "╔══════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
    Write-Host "║   DeepSeek Autolook Hub — 我是中枢                         ║" -ForegroundColor Cyan
    Write-Host "╚══════════════════════════════════════════════════════════╝" -ForegroundColor Cyan
}

function Show-HubStatus {
    param([string]$Project)
    $projectFile = Get-ProjectFile $Project
    if (-not (Test-Path $projectFile)) {
        Write-Host "项目 '$Project' 不存在" -ForegroundColor Yellow
        return $false
    }
    $projectData = Ensure-ProjectSchema (Read-JsonFile $projectFile)
    $tasks = @(Get-TaskList $Project)
    $providers = @(Get-DispatchableProviders)
    $stableProviders = @(Get-StableDispatchProviders)

    Write-Host ""
    Write-Host "═══ 项目: $($projectData.name) ($Project) ═══" -ForegroundColor Cyan
    Write-Host "目标: $($projectData.goal)"
    Write-Host "状态: $($projectData.status)"

    Write-Host ""
    Write-Host "── 任务状态 ──" -ForegroundColor DarkCyan
    $byStatus = $tasks | Group-Object status
    foreach ($group in $byStatus) {
        $icon = switch ($group.Name) {
            "done"      { "[✓]" }
            "dispatched" { "[→]" }
            "submitted"  { "[?]" }
            "rework"    { "[↻]" }
            "blocked"   { "[✗]" }
            default     { "[ ]" }
        }
        Write-Host "  $icon $($group.Name): $($group.Count)"
    }

    Write-Host ""
    Write-Host "── 可调度任务 ──" -ForegroundColor DarkCyan
    $readyTasks = @(Get-ReadyDispatchTasks -ProjectSlug $Project)
    if ($readyTasks.Count -eq 0) {
        Write-Host "  (无就绪任务)" -ForegroundColor DarkGray
    } else {
        foreach ($t in $readyTasks) {
            Write-Host "  [$($t.priority)] $($t.id): $($t.title)" -ForegroundColor White
            Write-Host "     目标: $($t.objective)" -ForegroundColor DarkGray
            Write-Host "     首选: $(@($t.preferredWorkers) -join ', ')" -ForegroundColor DarkGray
        }
    }

    Write-Host ""
    Write-Host "── 可用工人 (稳定优先) ──" -ForegroundColor DarkCyan
    foreach ($p in $stableProviders) {
        Write-Host "  [$($p.dispatch_priority)] $($p.name) — $($p.strengths)" -ForegroundColor DarkGray
    }

    return $true
}

# ---- 中枢操作 ---------------------------------------------------------------

function Invoke-HubDispatch {
    param(
        [string]$Project,
        [string]$TaskId
    )
    $projectFile = Get-ProjectFile $Project
    if (-not (Test-Path $projectFile)) { Write-Host "项目不存在" -ForegroundColor Red; return }

    $taskFile = Get-TaskFile -ProjectSlug $Project -TaskId $TaskId
    if (-not (Test-Path $taskFile)) { Write-Host "任务 '$TaskId' 不存在" -ForegroundColor Red; return }

    $taskData = Ensure-TaskSchema (Read-JsonFile $taskFile)
    $projectData = Read-JsonFile $projectFile
    $workspace = if ($projectData.workspace) { $projectData.workspace } else { (Get-Location).Path }

    Write-Host ""
    Write-Host "═══ 分派任务: $($taskData.id) — $($taskData.title) ═══" -ForegroundColor Cyan
    Write-Host "目标: $($taskData.objective)"
    Write-Host "优先级: $($taskData.priority)"
    if ($taskData.preferredWorkers) {
        Write-Host "首选工人: $(@($taskData.preferredWorkers) -join ', ')"
    }

    # 中枢决策：选择工人
    $preferredOrder = @(Get-PreferredDispatchWorkerOrder $taskData)
    if (-not $preferredOrder) {
        Write-Host "没有可用工人" -ForegroundColor Red
        return
    }

    Write-Host ""
    Write-Host "中枢决策: 工人顺序 → $($preferredOrder -join ' → ')" -ForegroundColor DarkCyan
    Write-Host "将使用第一个可用工人: $($preferredOrder[0])" -ForegroundColor Green

    & (Join-Path $PSScriptRoot "open-claude-task.ps1") `
        -Project $Project `
        -Task $TaskId `
        -Workspace $workspace `
        -AutoFallback

    Start-Sleep -Seconds 2

    # 读取最新状态
    $taskData = Ensure-TaskSchema (Read-JsonFile $taskFile)
    Write-Host ""
    Write-Host "分派结果: $($taskData.status) → $($taskData.owner) on $($taskData.lastProvider)" -ForegroundColor $(if ($taskData.status -eq "dispatched") { "Green" } else { "Red" })
}

function Invoke-HubReview {
    param(
        [string]$Project,
        [string]$TaskId
    )
    $taskFile = Get-TaskFile -ProjectSlug $Project -TaskId $TaskId
    if (-not (Test-Path $taskFile)) { Write-Host "任务不存在" -ForegroundColor Red; return }

    $taskData = Ensure-TaskSchema (Read-JsonFile $taskFile)

    Write-Host ""
    Write-Host "═══ 审查任务: $($taskData.id) — $($taskData.title) ═══" -ForegroundColor Cyan
    Write-Host "状态: $($taskData.status)"

    $reportDir = Join-Path (Get-ProjectRoot $Project) "reports"
    $reports = @(Get-ChildItem $reportDir -Filter "$TaskId--*.md" -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending)

    if (-not $reports) {
        Write-Host "没有找到报告" -ForegroundColor Yellow
        return
    }

    Write-Host ""
    Write-Host "── 报告: $($reports[0].Name) ──" -ForegroundColor DarkCyan
    $reportContent = Get-Content $reports[0].FullName -Raw
    # 显示摘要（前 800 字符）
    $preview = if ($reportContent.Length -gt 800) { $reportContent.Substring(0, 800) + "..." } else { $reportContent }
    Write-Host $preview -ForegroundColor DarkGray

    Write-Host ""
    Write-Host "中枢决策: 启动自动审查 (gpt-5-mini)..." -ForegroundColor Cyan
    $reviewResult = Invoke-AutoReview -Project $Project -Task $taskData -ReportContent $reportContent -ReviewerProvider "github-gpt-5-mini"

    if ($reviewResult) {
        Apply-AutoReviewResult -Project $Project -Task $taskData -ReviewResult $reviewResult
        $taskData = Ensure-TaskSchema (Read-JsonFile $taskFile)
        Write-Host ""
        Write-Host "审查结果: $($taskData.status)" -ForegroundColor $(if ($taskData.status -eq "done") { "Green" } else { "Magenta" })
        if ($reviewResult.summary) {
            Write-Host "摘要: $($reviewResult.summary)" -ForegroundColor DarkGray
        }
        if ($reviewResult.missingCriteria) {
            Write-Host "缺失项:" -ForegroundColor Yellow
            foreach ($m in $reviewResult.missingCriteria) { Write-Host "  - $m" -ForegroundColor Yellow }
        }
    } else {
        Write-Host "自动审查失败，需要人工审查" -ForegroundColor Yellow
    }
}

function Invoke-HubChain {
    param(
        [string]$Project
    )
    Write-Host ""
    Write-Host "═══ 中枢链式调度 ═══" -ForegroundColor Cyan

    $projectFile = Get-ProjectFile $Project
    if (-not (Test-Path $projectFile)) { Write-Host "项目不存在" -ForegroundColor Red; return }
    $projectData = Read-JsonFile $projectFile
    $workspace = if ($projectData.workspace) { $projectData.workspace } else { (Get-Location).Path }

    # 1. 调和过期任务
    Write-Host "[1/4] 调和过期任务..." -ForegroundColor DarkCyan
    & (Join-Path $PSScriptRoot "reconcile-supervisor-tasks.ps1") -Project $Project -Workspace $workspace

    # 2. 审查已提交任务
    Write-Host "[2/4] 审查已提交任务..." -ForegroundColor DarkCyan
    $tasks = @(Get-TaskList $Project)
    $submittedTasks = $tasks | Where-Object { $_.status -eq "submitted" }
    foreach ($t in $submittedTasks) {
        Write-Host "  审查 $($t.id)..." -ForegroundColor DarkGray
        Invoke-HubReview -Project $Project -TaskId $t.id
    }

    # 3. 重新分派 rework 任务
    Write-Host "[3/4] 重新分派返工任务..." -ForegroundColor DarkCyan
    $tasks = @(Get-TaskList $Project)
    $reworkTasks = $tasks | Where-Object { $_.status -eq "rework" -and $_.attemptCount -lt $_.maxAttempts }
    foreach ($t in $reworkTasks) {
        Write-Host "  重新分派 $($t.id)..." -ForegroundColor DarkGray
        Invoke-HubDispatch -Project $Project -TaskId $t.id
    }

    # 4. 分派就绪任务
    Write-Host "[4/4] 分派就绪任务..." -ForegroundColor DarkCyan
    $readyTasks = @(Get-ReadyDispatchTasks -ProjectSlug $Project)
    foreach ($t in $readyTasks) {
        Write-Host "  分派 $($t.id)..." -ForegroundColor DarkGray
        Invoke-HubDispatch -Project $Project -TaskId $t.id
    }

    # 最终状态
    Write-Host ""
    Show-HubStatus -Project $Project
    Write-Host ""
    Write-Host "═══ 中枢链式调度完成 ═══" -ForegroundColor Green
}

# ---- 入口函数 ---------------------------------------------------------------

function Start-Hub {
    param(
        [string]$Project
    )
    Write-HubBanner

    if (-not $Project) {
        $projects = @(Get-ProjectList)
        if ($projects.Count -eq 0) {
            Write-Host "没有项目。创建新项目: start-rd-task.ps1" -ForegroundColor Yellow
            return
        }
        Write-Host ""
        Write-Host "可用项目:" -ForegroundColor Cyan
        for ($i = 0; $i -lt $projects.Count; $i++) {
            Write-Host "  [$($i+1)] $($projects[$i].id) — $($projects[$i].name)"
        }
        $choice = Read-Host "选择项目 (序号或 slug)"
        if ($choice -match "^\d+$") {
            $idx = [int]$choice - 1
            if ($idx -ge 0 -and $idx -lt $projects.Count) { $Project = $projects[$idx].id }
        } else {
            $Project = $choice
        }
    }

    if (-not $Project) { Write-Host "未选择项目" -ForegroundColor Yellow; return }

    if (-not (Show-HubStatus -Project $Project)) { return }

    while ($true) {
        Write-Host ""
        Write-Host "中枢操作:" -ForegroundColor Cyan
        Write-Host "  [s] 刷新状态"
        Write-Host "  [d] 分派就绪任务"
        Write-Host "  [r] 审查任务"
        Write-Host "  [c] 链式调度 (自动全流程)"
        Write-Host "  [q] 退出中枢"
        $cmd = Read-Host "中枢指令"

        switch ($cmd) {
            "s" { Show-HubStatus -Project $Project }
            "d" {
                $ready = @(Get-ReadyDispatchTasks -ProjectSlug $Project)
                if ($ready.Count -eq 0) {
                    Write-Host "没有就绪任务" -ForegroundColor Yellow
                } else {
                    Write-Host "就绪任务:" -ForegroundColor Cyan
                    for ($i = 0; $i -lt $ready.Count; $i++) {
                        Write-Host "  [$($i+1)] $($ready[$i].id): $($ready[$i].title)"
                    }
                    $pick = Read-Host "选择任务 (序号/id/回车=第一个)"
                    if (-not $pick) {
                        Invoke-HubDispatch -Project $Project -TaskId $ready[0].id
                    } elseif ($pick -match "^\d+$") {
                        $idx = [int]$pick - 1
                        if ($idx -ge 0 -and $idx -lt $ready.Count) {
                            Invoke-HubDispatch -Project $Project -TaskId $ready[$idx].id
                        }
                    } else {
                        Invoke-HubDispatch -Project $Project -TaskId $pick
                    }
                }
            }
            "r" {
                $submitted = @(Get-TaskList $Project | Where-Object { $_.status -eq "submitted" })
                if ($submitted.Count -eq 0) {
                    Write-Host "没有待审查任务" -ForegroundColor Yellow
                } else {
                    Write-Host "待审查任务:" -ForegroundColor Cyan
                    for ($i = 0; $i -lt $submitted.Count; $i++) {
                        Write-Host "  [$($i+1)] $($submitted[$i].id): $($submitted[$i].title)"
                    }
                    $pick = Read-Host "选择任务 (序号/id)"
                    if ($pick -match "^\d+$") {
                        $idx = [int]$pick - 1
                        if ($idx -ge 0 -and $idx -lt $submitted.Count) {
                            Invoke-HubReview -Project $Project -TaskId $submitted[$idx].id
                        }
                    } elseif ($pick) {
                        Invoke-HubReview -Project $Project -TaskId $pick
                    }
                }
            }
            "c" { Invoke-HubChain -Project $Project }
            "q" { Write-Host "退出中枢" -ForegroundColor Cyan; return }
            default { Write-Host "未知指令" -ForegroundColor Yellow }
        }
    }
}
