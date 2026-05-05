#!/usr/bin/env python3
"""
Sync parallel providers from cc-switch.db.

Reads the cc-switch SQLite database, extracts all Claude-typed providers,
assigns fixed local ports, generates Claude Code settings files, launcher
scripts, and a provider manifest used by the supervisor layer.

Usage:
  python sync-parallel-providers.py
"""
import json
import re
import sqlite3
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SETTINGS_DIR = ROOT / "settings"
SCRIPTS_DIR = ROOT / "scripts"
LOGS_DIR = ROOT / "logs"
MANIFEST_PATH = ROOT / "providers.manifest.json"
DB_PATH = Path.home() / ".cc-switch" / "cc-switch.db"
PORT_BASE = 15921


def slugify(name: str) -> str:
    """Convert a provider name to a filesystem-safe slug."""
    slug = re.sub(r"[^a-z0-9]+", "-", name.lower()).strip("-") or "provider"
    # Collapse consecutive dashes
    slug = re.sub(r"-{2,}", "-", slug)
    return slug


def is_ollama(base_url: str | None) -> bool:
    """Check if a base URL points to a local Ollama instance."""
    if not base_url:
        return False
    value = base_url.lower()
    return "127.0.0.1:11434" in value or "localhost:11434" in value


def infer_strengths(name: str, model: str, base_url: str) -> str:
    """Infer the strengths of a provider from its name, model, and base URL."""
    text = f"{name} {model} {base_url}".lower()

    if "deepseek-v4-pro" in text:
        return "complex reasoning, design review, harder coding tasks"
    if "deepseek" in text:
        return "general coding, project analysis, web-backed research, first-pass analysis"
    if "longcat-flash-thinking" in text:
        return "task decomposition, deeper reasoning, tradeoff analysis, failure-mode analysis"
    if "longcat-flash-lite" in text:
        return "fast brainstorming, lightweight analysis, quick summaries"
    if "gpt-5-mini" in text:
        return "fast code review, concise second opinion, implementation checks, simplification review"
    if "claude-haiku" in text:
        return "quick review, concise summaries, lightweight validation, issue spotting"
    if "qwen" in text:
        return "light local tasks, quick file inspection, directory listing, rough summaries"
    if "gemma" in text:
        return "light local summaries, low-risk helper tasks, file summaries"
    if "owl-alpha" in text:
        return "broad general analysis, experimental reasoning, exploratory investigation"
    if "glm" in text or "zhipu" in text:
        return "general reasoning, cheap fallback analysis, Chinese language tasks"
    if "spark" in text:
        return "general chat, quick ideation, lightweight experimentation"
    if "nemotron" in text:
        return "compact reasoning, low-cost review, quick checks"
    if "minimax" in text:
        return "general reasoning, broad fallback use, creative tasks"
    if "ling" in text:
        return "general multilingual reasoning, fallback tasks"
    if "tencent" in text or "hy3" in text:
        return "general reasoning, fallback experimentation"
    if "apinebula" in text:
        return "experimental upstream route, alternative routing"
    if "yd" in text:
        return "custom provider route (China Mobile), experimental use"
    if "githubcopilot.com" in base_url.lower():
        return "coding assistance and review, lightweight checks"
    if is_ollama(base_url):
        return "local model tasks, low-cost lightweight work"

    return "general-purpose analysis"


def infer_runtime_group(name: str, model: str, base_url: str) -> str:
    """Classify a provider as local or cloud."""
    if is_ollama(base_url):
        return "local"
    return "cloud"


def infer_cost_tier(name: str, model: str, base_url: str) -> str:
    """Classify a provider's cost tier."""
    text = f"{name} {model} {base_url}".lower()
    if is_ollama(base_url):
        return "cheap"
    if any(kw in text for kw in [
        "free", "spark-lite", "glm-4.5-air", "nemotron",
        "ling-2.6-1t", "hy3-preview", "minimax-m2.5",
    ]):
        return "cheap"
    if any(kw in text for kw in ["deepseek-v4-pro", "opus", "glm-4.6v"]):
        return "expensive"
    if any(kw in text for kw in [
        "deepseek", "longcat-flash-thinking", "claude-haiku",
        "gpt-5-mini", "longcat-flash-lite", "owl-alpha",
        "glm-4.5", "zhipu",
    ]):
        return "standard"
    return "standard"


def infer_budget_policy(name: str, model: str, base_url: str) -> str:
    """Determine the budget policy for a provider."""
    cost_tier = infer_cost_tier(name, model, base_url)
    if cost_tier == "expensive":
        return "manual-approval"
    if cost_tier == "standard":
        return "normal"
    return "prefer-first"


def infer_stability_tier(name: str, model: str, base_url: str) -> str:
    """Classify provider stability for dispatch ordering."""
    text = f"{name} {model} {base_url}".lower()
    if is_ollama(base_url):
        return "local"
    if "deepseek-v4-pro" in text:
        return "stable"
    if "deepseek" in text:
        return "stable"
    if "gpt-5-mini" in text:
        return "stable"
    if "longcat-flash-lite" in text or "longcat-flash-thinking" in text:
        return "stable"
    if "claude-haiku" in text:
        return "candidate"
    if "free" in text or "glm" in text or "nemotron" in text or "spark" in text:
        return "candidate"
    if "apinebula" in text or "yd" in text or "owl-alpha" in text:
        return "experimental"
    return "candidate"


def infer_dispatch_priority(name: str, model: str, base_url: str) -> int:
    """Infer the dispatch priority (lower = higher priority)."""
    text = f"{name} {model} {base_url}".lower()
    if "deepseek" in text and "v4-pro" not in text:
        return 10
    if "gpt-5-mini" in text:
        return 20
    if "longcat-flash-thinking" in text:
        return 30
    if "longcat-flash-lite" in text:
        return 40
    if "deepseek-v4-pro" in text:
        return 50
    if "claude-haiku" in text:
        return 60
    if "glm" in text:
        return 70
    if "free" in text:
        return 80
    if is_ollama(base_url):
        return 90
    return 100


def infer_stable_candidate(name: str, model: str, base_url: str) -> bool:
    """Whether this provider is a stable dispatch candidate."""
    return infer_stability_tier(name, model, base_url) == "stable"


def infer_healthcheck_candidate(name: str, model: str, base_url: str) -> bool:
    """Whether this provider should be included in health checks."""
    stability = infer_stability_tier(name, model, base_url)
    return stability in {"stable", "candidate"}


def load_providers() -> list[dict]:
    """Load all Claude-typed providers from cc-switch.db."""
    conn = sqlite3.connect(str(DB_PATH))
    cur = conn.cursor()
    cur.execute(
        "SELECT id, name, settings_config FROM providers WHERE app_type='claude' ORDER BY sort_index, name"
    )
    out = []
    for pid, name, raw in cur.fetchall():
        if not raw:
            continue
        try:
            cfg = json.loads(raw)
        except json.JSONDecodeError:
            continue

        env = cfg.get("env", {})
        base_url = env.get("ANTHROPIC_BASE_URL", "")
        token = env.get("ANTHROPIC_AUTH_TOKEN", "")

        # Model priority: explicit model > default haiku > default sonnet > default opus
        model = (
            env.get("ANTHROPIC_MODEL")
            or env.get("ANTHROPIC_DEFAULT_HAIKU_MODEL")
            or env.get("ANTHROPIC_DEFAULT_SONNET_MODEL")
            or env.get("ANTHROPIC_DEFAULT_OPUS_MODEL")
            or ""
        )

        if not base_url or not token:
            # Skip providers without essential configuration
            continue

        out.append({
            "id": pid,
            "name": name,
            "base_url": base_url,
            "token": token,
            "model": model,
        })

    conn.close()
    return out


def write_json(path: Path, data):
    """Write a JSON file with consistent formatting."""
    path.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n", "utf-8")


def quote_windows(path: Path) -> str:
    """Return a path as a string suitable for Windows batch files."""
    return str(path)


def build_cmd(item: dict) -> str:
    """Build a .cmd launcher for a provider's proxy."""
    log_file = LOGS_DIR / f"parallel-{item['slug']}.log"

    if item["mode"] == "ollama_bridge":
        return (
            "@echo off\n"
            f"set LISTEN_PORT={item['port']}\n"
            f"set OLLAMA_BASE_URL={item['base_url'].removesuffix('/v1')}\n"
            f"set OLLAMA_MODEL={item['model']}\n"
            f'C:\\Python311\\python.exe {quote_windows(ROOT / "proxies" / "anthropic_to_ollama_bridge.py")}'
            f" >> {quote_windows(log_file)} 2>&1\n"
        )

    model_line = f"set UPSTREAM_MODEL={item['model']}\n" if item["model"] else ""
    return (
        "@echo off\n"
        f"set LISTEN_PORT={item['port']}\n"
        f"set UPSTREAM_BASE_URL={item['base_url']}\n"
        f"set UPSTREAM_AUTH_TOKEN={item['token']}\n"
        f"{model_line}"
        f'C:\\Python311\\python.exe {quote_windows(ROOT / "proxies" / "fixed_anthropic_proxy.py")}'
        f" >> {quote_windows(log_file)} 2>&1\n"
    )


def build_open_script(item: dict) -> str:
    """Build a PowerShell script to open a Claude Code window for a provider."""
    provider_name = item["name"].replace("'", "''")
    provider_strengths = item["strengths"].replace("'", "''")
    settings_path = str(SETTINGS_DIR / f"{item['slug']}-settings.json").replace("\\", "\\\\").replace("'", "''")

    return f"""$command = @'
$Host.UI.RawUI.WindowTitle = "{provider_name} | port {item['port']}"
Write-Host "Provider: {provider_name}" -ForegroundColor Cyan
Write-Host "Port: {item['port']}"
Write-Host "Best for: {provider_strengths}" -ForegroundColor DarkCyan
Write-Host "Use this window for tasks matching the best-for line above." -ForegroundColor DarkGray
Write-Host "Settings: {settings_path}"
Write-Host ""
$initPrompt = @"'
Before anything else, reply in plain text with exactly two lines and no extra text.
Provider: {provider_name}
Best for: {provider_strengths}
'@
claude --settings "{settings_path}" $initPrompt
'@
$bytes = [System.Text.Encoding]::Unicode.GetBytes($command)
$encoded = [Convert]::ToBase64String($bytes)
Start-Process powershell.exe -ArgumentList "-NoExit", "-EncodedCommand", $encoded -WindowStyle Normal
"""


def build_append_system_prompt(item: dict) -> str:
    """Build a system prompt append that reminds the model of its identity."""
    return (
        f"You are running in a routed parallel session managed by DeepSeek Autolook.\n"
        f"Provider: {item['name']}\n"
        f"Best for: {item['strengths']}\n"
        "At the start of a fresh session, before your first substantive answer, print exactly these two lines:\n"
        f"Provider: {item['name']}\n"
        f"Best for: {item['strengths']}\n"
        "Then continue with the actual answer.\n"
        "Do not claim to be a different provider or different model backend.\n"
    )


def main():
    SETTINGS_DIR.mkdir(parents=True, exist_ok=True)
    SCRIPTS_DIR.mkdir(parents=True, exist_ok=True)
    LOGS_DIR.mkdir(parents=True, exist_ok=True)

    providers = load_providers()
    if not providers:
        print("No Claude-typed providers found in cc-switch.db. Nothing to do.")
        return

    manifest = {"providers": []}
    used_slugs: set[str] = set()

    for index, provider in enumerate(providers):
        slug = slugify(provider["name"])
        base = slug
        n = 2
        while slug in used_slugs:
            slug = f"{base}-{n}"
            n += 1
        used_slugs.add(slug)

        item = {
            **provider,
            "slug": slug,
            "port": PORT_BASE + index,
            "mode": "ollama_bridge" if is_ollama(provider["base_url"]) else "anthropic_proxy",
            "strengths": infer_strengths(provider["name"], provider["model"], provider["base_url"]),
            "runtime_group": infer_runtime_group(provider["name"], provider["model"], provider["base_url"]),
            "cost_tier": infer_cost_tier(provider["name"], provider["model"], provider["base_url"]),
            "budget_policy": infer_budget_policy(provider["name"], provider["model"], provider["base_url"]),
            "stability_tier": infer_stability_tier(provider["name"], provider["model"], provider["base_url"]),
            "dispatch_priority": infer_dispatch_priority(provider["name"], provider["model"], provider["base_url"]),
            "stable_candidate": infer_stable_candidate(provider["name"], provider["model"], provider["base_url"]),
            "healthcheck_candidate": infer_healthcheck_candidate(provider["name"], provider["model"], provider["base_url"]),
            "settings_path": str(SETTINGS_DIR / f"{slug}-settings.json"),
            "launcher_path": str(SCRIPTS_DIR / f"parallel-{slug}.cmd"),
            "open_script_path": str(SCRIPTS_DIR / f"open-claude-{slug}.ps1"),
            # By default, all providers are dispatch-enabled
            "dispatch_enabled": True,
            "dispatch_disabled_reason": "",
        }
        manifest["providers"].append(item)

        # --- Generate Claude Code settings file ---
        write_json(
            SETTINGS_DIR / f"{slug}-settings.json",
            {
                "env": {
                    "ANTHROPIC_BASE_URL": f"http://127.0.0.1:{item['port']}",
                    "ANTHROPIC_AUTH_TOKEN": "parallel-sidecar",
                },
                "appendSystemPrompt": build_append_system_prompt(item),
            },
        )

        # --- Generate proxy launcher .cmd ---
        (SCRIPTS_DIR / f"parallel-{slug}.cmd").write_text(build_cmd(item), "utf-8")

        # --- Generate Claude Code open script ---
        (SCRIPTS_DIR / f"open-claude-{slug}.ps1").write_text(build_open_script(item), "utf-8")

        print(f"  [{item['runtime_group']}/{item['cost_tier']}] {item['name']} -> port {item['port']} ({slug})")

    write_json(MANIFEST_PATH, manifest)
    print(f"\nWrote manifest with {len(manifest['providers'])} providers.")
    print(f"Settings: {SETTINGS_DIR}")
    print(f"Launchers: {SCRIPTS_DIR}")
    print(f"Logs: {LOGS_DIR}")


if __name__ == "__main__":
    main()
