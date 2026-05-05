#!/usr/bin/env python3
"""
extract-claude-result.py — Extract the final text result from a Claude Code stream-json log.
Usage: python extract-claude-result.py <stream.jsonl>
"""
import json
import sys


def extract(path: str) -> str:
    parts = []
    with open(path, "r", encoding="utf-8") as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            try:
                obj = json.loads(line)
            except json.JSONDecodeError:
                continue

            obj_type = obj.get("type", "")

            # assistant message blocks
            if obj_type == "assistant":
                message = obj.get("message", {})
                content = message.get("content", [])
                for block in content:
                    if isinstance(block, dict):
                        if block.get("type") == "text":
                            parts.append(block.get("text", ""))
                        elif block.get("type") == "tool_use":
                            name = block.get("name", "tool")
                            inp = block.get("input", {})
                            parts.append(f"\n[TOOL: {name}] {json.dumps(inp, ensure_ascii=False)[:200]}\n")
                        elif block.get("type") == "thinking":
                            # Optionally include thinking; skip by default
                            pass

            # system messages
            elif obj_type == "system":
                subtype = obj.get("subtype", "")
                if subtype == "init":
                    continue

            # result message
            elif obj_type == "result":
                result_text = obj.get("result", "")
                if result_text:
                    parts.append(result_text)

    return "\n".join(parts)


def main():
    if len(sys.argv) < 2:
        print("Usage: python extract-claude-result.py <stream.jsonl>", file=sys.stderr)
        sys.exit(1)

    path = sys.argv[1]
    result = extract(path)
    print(result)


if __name__ == "__main__":
    main()
