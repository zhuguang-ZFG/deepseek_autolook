# Supervisor Mode

Supervisor mode adds a durable task layer on top of the parallel provider setup.

## Goal

Use a human (or Codex) as the foreman, and use multiple Claude Code provider windows as bounded workers.

## Layout

- `projects/<project-id>/project.json` — project-level metadata
- `projects/<project-id>/tasks/*.json` — task definitions and state
- `projects/<project-id>/reports/*.md` — worker output files
- `projects/<project-id>/prompts/*.txt` — exact prompts used to dispatch workers
- `projects/<project-id>/context/` — copied notes, screenshots, diffs, or requirements
- `projects/<project-id>/artifacts/` — exported comparisons or generated supporting files
- `projects/<project-id>/artifacts/logs/` — per-task dispatch logs
- `projects/<project-id>/artifacts/launchers/` — generated launcher scripts

## Workflow

1. Create a supervisor project: `new-supervisor-project.ps1`
2. Create small bounded tasks with explicit allowed paths: `new-supervisor-task.ps1`
3. Dispatch each task to one provider at a time: `open-claude-task.ps1`
4. Read the generated report in `reports/`
5. Review, correct, and assign the next round: `review-supervisor-task.ps1`

## Scripts

- `open-supervisor-panel.ps1` — interactive panel for recurring use
- `new-supervisor-project.ps1` — scaffold a project
- `new-supervisor-task.ps1` — create a task JSON
- `open-claude-task.ps1` — launch one provider on one task with a generated prompt
- `open-cursor-task.ps1` — launch Cursor as a manual worker
- `submit-supervisor-task.ps1` — submit a task for review
- `review-supervisor-task.ps1` — review task reports
- `set-supervisor-task-status.ps1` — manually change task status
- `fail-supervisor-task.ps1` — mark task as failed with reason
- `reconcile-supervisor-tasks.ps1` — check for stale leases and auto-redispatch
- `close-supervisor-project.ps1` — closeout check and optional status update
- `show-supervisor-dashboard.ps1` — overview of project/tasks/providers
- `start-parallel-ai.ps1` — start all proxy services
- `stop-parallel-ai.ps1` — stop all proxy services
- `start-rd-task.ps1` — seed a project with RD task pack

## Rule

Parallel analysis is fine. Parallel writes to the same files are not.

## Runtime Policy

- **local** providers (`qwen3.5:9b`, `gemma4:e4b`) are single-lane only — one local task at a time
- **cloud** providers may run in parallel
- **cheap** providers should be preferred for first-pass scanning and summaries
- **standard** providers are the default
- **expensive** providers (`DeepSeek-V4-pro`, `Zhipu GLM copy`) require explicit `-ForceExpensive`

## Task Status State Machine

```
ready → dispatched → submitted → review
                        ↓              ↓
                      (failed)       rework → dispatched
                        ↓              ↓
                      ready          done
                        ↑
                     blocked
```

## Acceptance Model

- Workers do not self-certify completion
- `done` should come from review, not from dispatch
- Preferred task flow:
  - `ready` → `dispatched` → `submitted` → `rework` or `done`
- Use `review-supervisor-task.ps1` to evaluate reports against acceptance criteria
- Use `submit-supervisor-task.ps1` when a worker has delivered artifacts
- Use `close-supervisor-project.ps1` for project closeout

## Delegation Model

- `owner` — the current assigned worker
- `preferredWorkers` — desired worker order
- `fallbackWorkers` — backup worker order
- `assignmentHistory` — records why a worker was skipped or selected
- Use auto dispatch (`-AutoFallback`) when the system should choose the next available worker

## Cursor Lane

- Cursor can be used as a manual worker
- Preferred strategy is CLI-first when available (`-PreferCli`)
- If CLI execution does not yield a dependable result, fall back to GUI mode
- Final acceptance should still check report files and task outputs

## Fast Start

```powershell
powershell -ExecutionPolicy Bypass -File .\parallel-ai\scripts\start-rd-task.ps1
```

This seeds a project and an initial task pack to start routing and reviewing.
