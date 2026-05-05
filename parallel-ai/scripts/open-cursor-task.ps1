param(
    [string]$Project,
    [string]$Task,
    [string]$Workspace = (Get-Location).Path,
    [switch]$PreferCli
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "supervisor-lib.ps1")

if (-not $Project) { $Project = Read-Host "Project slug" }
if (-not $Task) { $Task = Read-Host "Task ID" }

$projectFile = Get-ProjectFile $Project
$taskFile = Get-TaskFile -ProjectSlug $Project -TaskId $Task
if (-not (Test-Path $projectFile)) { throw "Project not found: $projectFile" }
if (-not (Test-Path $taskFile)) { throw "Task not found: $taskFile" }

$projectData = Read-JsonFile $projectFile
$taskData = Ensure-TaskSchema (Read-JsonFile $taskFile)

$reportPath = Join-Path (Join-Path (Get-ProjectRoot $Project) "reports") ($Task + "--cursor.md")
$promptPath = Join-Path (Join-Path (Get-ProjectRoot $Project) "prompts") ($Task + "--cursor.txt")

# Build a simplified worker prompt for Cursor (local editor, manual review)
$cursorPrompt = @"
You are acting as a Cursor worker in the DeepSeek Autolook supervisor system.

Project: $($projectData.name) ($($projectData.id))
Goal: $($projectData.goal)

Task: $($taskData.id) — $($taskData.title)
Objective: $($taskData.objective)
Priority: $($taskData.priority)

Acceptance criteria:
$(($taskData.acceptanceCriteria | ForEach-Object { "- $_" }) -join "`n")

Allowed edit scope:
$(if ($taskData.allowedPaths) { ($taskData.allowedPaths | ForEach-Object { "- $_" }) -join "`n" } else { "- No explicit limit — stay tightly scoped." })

Constraints:
$(if ($taskData.constraints) { ($taskData.constraints | ForEach-Object { "- $_" }) -join "`n" } else { "- None recorded." })

When finished, write a brief report to: $reportPath
Include: Summary, Findings, Acceptance checklist (PASS/FAIL each criterion), Files touched, Open questions.
"@

[System.IO.File]::WriteAllText($promptPath, $cursorPrompt + [Environment]::NewLine, [System.Text.UTF8Encoding]::new($false))

$taskData.status = "dispatched"
$taskData.lastProvider = "cursor"
$taskData.owner = "cursor"
$taskData = Start-TaskLease -Task $taskData
$taskData = Add-AssignmentHistoryEntry -Task $taskData -Worker "cursor" -Outcome "delegated" -Reason "cursor-manual"
$taskData.updatedAt = Get-IsoNow
Write-JsonFile -Path $taskFile -Data $taskData

$cursorCli = Get-CursorCliPath
if ($PreferCli -and $cursorCli) {
    Write-Host "Opening Cursor CLI for task $Task..." -ForegroundColor Green
    & $cursorCli --prompt $cursorPrompt
} else {
    Write-Host "Opening Cursor workspace..." -ForegroundColor Green
    if ($cursorCli) {
        Start-Process $cursorCli -ArgumentList $Workspace
    } else {
        Write-Host "Cursor CLI not found. Opening project folder in explorer." -ForegroundColor Yellow
        Start-Process explorer.exe -ArgumentList $Workspace
    }
}

Write-Host "Prompt saved: $promptPath"
Write-Host "Report expected: $reportPath"
Write-Host "Task $Task dispatched to Cursor" -ForegroundColor Green
