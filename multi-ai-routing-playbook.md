# DeepSeek Autolook — Multi-AI Routing Playbook

## Principles

- **Parallel analysis, serial execution.** Multiple windows can analyze simultaneously. Only one model gets write authority at a time.
- **Only one model edits at a time.** The supervisor lease system enforces this automatically.
- **Local models handle light tasks only.** Ollama models (`qwen3.5:9b`, `gemma4:e4b`) are for directory listings and short summaries.
- **Cloud models handle research, reasoning, and final-quality review.**
- **Cheap-first routing.** Free/cheap providers are tried first; expensive ones need explicit `-ForceExpensive` override.
- **Workers do not self-certify.** `done` status requires a review step. No task is auto-completed.

## Recommended Roles

- **DeepSeek** — project analysis, code execution, web-backed research, first-pass analysis
- **LongCat-Flash-Thinking-2601** — task decomposition, deeper reasoning, failure-mode analysis, tradeoff exploration
- **GitHub gpt-5-mini** — fast code review, concise second opinion, simplification checks
- **GitHub claude-haiku-4.5** — lightweight review, concise issue spotting, quick validation
- **qwen3.5:9b (Ollama)** — directory listing, brief summaries, ultra-light local tasks
- **gemma4:e4b (Ollama)** — file summaries, low-risk helper tasks
- **openrouter/owl-alpha** — broad analysis, experimental reasoning, exploratory investigation
- **z-ai/glm-4.5-air:free** — cheap general reasoning, Chinese language tasks, fallback analysis
- **DeepSeek-V4-pro** — complex reasoning, design review, harder coding tasks (expensive, needs override)
- **Zhipu GLM** — general reasoning, Chinese language context, mid-tier analysis

## Prompt Templates

### 1. Project Research

```
DeepSeek 学习这个项目，先回答：
1. 这是做什么的
2. 核心模块有哪些
3. 当前最值得关注的风险点
4. 不要改代码，只做分析
```

### 2. Plan Decomposition

```
LongCat-Flash-Thinking-2601 基于这个任务，拆成：
1. 目标
2. 约束
3. 最小可行方案
4. 潜在失败点
5. 不要执行，只做方案设计
```

### 3. Quick Review

```
GitHub gpt-5-mini 快速复核上面的方案，重点看：
1. 有没有明显漏洞
2. 有没有过度设计
3. 有没有更简单的实现
4. 简短回答
```

### 4. Change Review

```
GitHub claude-haiku-4.5 审查这个改动：
1. 明显 bug
2. 回归风险
3. 缺失测试
4. 不要重写方案，只列问题
```

### 5. Light Local Task

```
qwen3.5:9b 列出当前目录文件名，不要解释
```

```
gemma4:e4b 读取 README.md，用 5 行总结
```

### 6. Execution

```
DeepSeek 现在开始执行：
1. 先查看相关文件
2. 只改和任务直接相关的内容
3. 改完后说明改了什么
4. 如果不能确定，再提出具体问题
```

### 7. Web Query

```
DeepSeek 查询今天的天气，给出：
1. 天气
2. 温度范围
3. 是否建议带伞
```

### 8. Compare Two Approaches

```
DeepSeek 给出方案 A 和方案 B，并比较优缺点
```

```
LongCat-Flash-Thinking-2601 复核上面的 A/B 方案，指出哪个更稳，为什么
```

## Recommended Workflow

1. **DeepSeek** does initial analysis (project research, codebase scan).
2. **LongCat-Flash-Thinking-2601** decomposes or challenges the plan.
3. **GitHub gpt-5-mini** or **GitHub claude-haiku-4.5** reviews quickly.
4. One model is selected as the single executor.
5. After execution, one reviewer model checks the output.

## Quick-Start RD Pack

```powershell
powershell -ExecutionPolicy Bypass -File .\parallel-ai\scripts\start-rd-task.ps1
```

This creates:
- A supervisor project with 4 seed tasks
- `baseline-comparison` → DeepSeek (analysis)
- `implementation-plan` → LongCat (planning)
- `execution-lane` → DeepSeek (execution)
- `review-and-regression` → GitHub gpt-5-mini (review)

## Do Not

- Do not let multiple models edit the same target at the same time.
- Do not depend on local 9B-class models for final judgment.
- Do not run concurrent provider switching through one shared Claude Code session — use the supervisor panel.
- Do not mark a task `done` without a review.
- Do not use expensive providers without `-ForceExpensive` approval.
