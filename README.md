# DeepSeek Autolook — Multi-AI Parallel Programming Workbench

基于 cc-switch 的多 AI 并行编程系统。通过本地 HTTP 代理层 + 监督者任务调度，
让多个 AI 模型（DeepSeek、LongCat、GitHub Copilot、OpenRouter、Ollama 等）
在独立窗口中并行分析，但串行写入，形成可控的多模型协作工作流。

## 架构

```
快捷键层 (AHK hotstrings)
    ↓
代理层 (fixed_anthropic_proxy / ollama_bridge)
    ↓ 每提供者一个本地端口 (15821+)
Claude Code 窗口 × N
    ↓
监督层 (supervisor-lib.ps1 + 业务脚本)
    ↓
耐久任务系统 (projects / tasks / reports)
```

## 快速开始

### 1. 同步提供者

```powershell
C:\Python311\python.exe .\parallel-ai\scripts\sync-parallel-providers.py
```

### 2. 启动并行 AI 服务

```powershell
powershell -ExecutionPolicy Bypass -File .\parallel-ai\scripts\start-parallel-ai.ps1
```

### 3. 打开监督者面板

```powershell
powershell -ExecutionPolicy Bypass -File .\parallel-ai\scripts\open-supervisor-panel.ps1
```

### 4. 停止服务

```powershell
powershell -ExecutionPolicy Bypass -File .\parallel-ai\scripts\stop-parallel-ai.ps1
```

## 核心原则

- **并行分析，串行写入** — 多窗口同时分析，但同一时刻只允许一个模型写文件
- **廉价优先** — 便宜/免费的模型用于首轮扫描，昂贵的模型需要显式 override
- **审查即完成** — 任务不能自证完成，`done` 状态必须来自 reviewer
- **本地单车道** — Ollama 等本地模型同一时间只能处理一个任务
- **基于文件的异步通信** — worker 输出 markdown 报告，supervisor 读取审查

## 提供者角色（推荐）

| 提供者 | 角色 |
|--------|------|
| DeepSeek | 项目分析、编码执行、Web 研究 |
| LongCat-Flash-Thinking-2601 | 任务分解、深度推理、失败分析 |
| GitHub gpt-5-mini | 快速审查、简化检查、第二意见 |
| GitHub claude-haiku-4.5 | 轻量审查、简洁问题发现 |
| qwen3.5:9b (Ollama) | 目录列表、简短摘要 |
| gemma4:e4b (Ollama) | 文件摘要、低风险辅助任务 |

## 许可证

MIT
