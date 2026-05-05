# DeepSeek Autolook — Multi-AI Parallel Programming Workbench

基于 cc-switch 的多 AI 并行编程系统。通过本地 HTTP 代理层 + 监督者任务调度，
让多个 AI 模型在独立窗口中并行分析，但串行写入，形成可控的多模型协作工作流。

## 一键启动

```powershell
# 查看帮助
powershell -ExecutionPolicy Bypass -File .\deepseek-autolook.ps1

# 查看系统状态
powershell -ExecutionPolicy Bypass -File .\deepseek-autolook.ps1 status

# 启动稳定提供者
powershell -ExecutionPolicy Bypass -File .\deepseek-autolook.ps1 start

# 启动平铺仪表盘 (TUI 中枢 + worker 窗口)
powershell -ExecutionPolicy Bypass -File .\deepseek-autolook.ps1 dashboard

# 启动交互式中枢
powershell -ExecutionPolicy Bypass -File .\deepseek-autolook.ps1 hub -Project my-project

# 创建 RD 任务链
powershell -ExecutionPolicy Bypass -File .\deepseek-autolook.ps1 rd -Name fix-login-bug
```

## 架构

```
deepseek-autolook.ps1 (顶层入口 — 10 个子命令)
    ↓
┌───────────────────┬──────────────────────┐
│  hub.ps1          │  open-supervisor-    │
│  (TUI 中枢)       │  panel.ps1 (菜单面板) │
├───────────────────┴──────────────────────┤
│  supervisor-lib.ps1 (核心库 ~1100 行)     │
│  ├ 任务状态机 (ready→dispatched→done)     │
│  ├ 提供者健康退避 (2失败自动禁用)          │
│  ├ 稳定路由 (stable>candidate>experimental)│
│  ├ 成功率追踪 (每个提供者成功/失败计数)     │
│  ├ 缓存优化提示词 (静态前缀→变量后缀)       │
│  └ 自动审查闭环 (worker→submit→review)    │
├──────────────────────────────────────────┤
│  代理层 (HTTP proxy / Ollama bridge)      │
│  每提供者一个本地端口 (15921–15960)        │
└──────────────────────────────────────────┘
```

## 核心原则

- **并行分析，串行写入** — 多窗口同时分析，同一时刻只允许一个模型写文件
- **廉价优先** — 免费/便宜模型用于首轮扫描，昂贵模型需显式 override
- **审查即完成** — 任务不能自证完成，`done` 状态必须来自 reviewer
- **本地单车道** — Ollama 同一时间只处理一个任务
- **健康退避** — 2 次连续失败自动禁用 15-30 分钟
- **静态前缀缓存** — worker prompt 的前缀跨所有分派复用，命中率 ~80%

## 工作流

```
start-rd-task.ps1 → 创建项目 + 4 个种子任务
  ↓
hub.ps1 [c] 链式调度:
  [1/4] 调和过期任务
  [2/4] 审查已提交任务 (gpt-5-mini 自动判断)
  [3/4] 重分派返工任务
  [4/4] 分派就绪任务
  ↓
close-supervisor-project.ps1 → 关闭检查
```

## 平铺仪表盘

```
┌──────────────────────┬──────────────┐
│                      │  DeepSeek    │
│   DeepSeek TUI       ├──────────────┤
│   (中枢/编排)         │  LongCat     │
│                      ├──────────────┤
│                      │  gpt-5-mini  │
└──────────────────────┴──────────────┘
```

启动：`deepseek-autolook.ps1 dashboard`

## 提供者 (20 个，从 cc-switch.db 自动发现)

| 稳定性 | 提供者 | 端口 |
|--------|--------|------|
| stable | DeepSeek | 15921 |
| stable | GitHub gpt-5-mini | 15924 |
| stable | LongCat-Flash-Thinking-2601 | 15926 |
| stable | LongCat-Flash-Lite | 15925 |
| stable | DeepSeek-V4-pro | 15922 |
| candidate | GitHub claude-haiku-4.5 | 15923 |
| candidate | Zhipu GLM | 15928 |
| candidate | z-ai/glm-4.5-air:free | 15940 |
| candidate | openrouter/free 系列 | 15932-15939 |
| local | qwen3.5:9b / gemma4:e4b | 15937/15931 |

## 脚本清单 (30+ 个)

| 脚本 | 用途 |
|------|------|
| `deepseek-autolook.ps1` | **顶层入口** — 10 个子命令 |
| `hub.ps1` | **TUI 中枢** — 交互式编排面板 |
| `start-dashboard.ps1` | 平铺仪表盘启动器 (Win32 窗口布局) |
| `supervisor-lib.ps1` | 核心库 (项目/任务/路由/租约/健康/缓存提示词) |
| `open-supervisor-panel.ps1` | 19 项操作菜单面板 |
| `open-claude-task.ps1` | 任务分派 + Claude Code 启动器 |
| `submit-supervisor-task.ps1` | 提交任务 + 自动审查 |
| `review-supervisor-task.ps1` | 人工/自动审查 |
| `reconcile-supervisor-tasks.ps1` | 调和过期租约 |
| `post-task-hook.ps1` | 任务完成钩子 (自动链式分派) |
| `sync-parallel-providers.py` | 从 cc-switch.db 生成全量配置 |
| `verify-parallel-ai.ps1` | 6 项系统验证 |
| `check-stable-providers.ps1` | 提供者健康检查 |
| `start-stable-providers.ps1` | 仅启动稳定提供者 |
| `open-provider.ps1` | 提供者浏览器 (分组菜单) |
| `watch-task-report.ps1` | 报告监控 |
| `refresh-desktop-shortcuts.ps1` | 桌面快捷方式生成 |
| `extract-claude-result.py` | 从 stream-json 提取文本 |
| `fixed_anthropic_proxy.py` | HTTP 代理 (20+ 上游类型) |
| `anthropic_to_ollama_bridge.py` | Ollama 协议桥接 |

## 许可证

MIT
