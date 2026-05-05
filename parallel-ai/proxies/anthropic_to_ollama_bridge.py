#!/usr/bin/env python3
"""
Anthropic → Ollama API bridge.
Converts Anthropic /v1/messages requests to Ollama OpenAI-compatible /v1/chat/completions,
then maps the response back to Anthropic format.

Environment:
  LISTEN_HOST     (default: 127.0.0.1)
  LISTEN_PORT     (required)
  OLLAMA_BASE_URL (default: http://127.0.0.1:11434)
  OLLAMA_MODEL    (required — e.g. qwen3.5:9b, gemma4:e4b)
"""
import json
import os
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen


LISTEN_HOST = os.environ.get("LISTEN_HOST", "127.0.0.1")
LISTEN_PORT = int(os.environ["LISTEN_PORT"])
OLLAMA_BASE_URL = os.environ.get("OLLAMA_BASE_URL", "http://127.0.0.1:11434").rstrip("/")
OLLAMA_MODEL = os.environ["OLLAMA_MODEL"]


def to_ollama_messages(messages):
    """Convert Anthropic-format messages to Ollama/OpenAI chat format."""
    out = []
    for item in messages or []:
        role = item.get("role", "user")
        content = item.get("content", "")
        # Anthropic content can be a list of blocks; flatten text blocks
        if isinstance(content, list):
            text_parts = []
            for block in content:
                if isinstance(block, dict) and block.get("type") == "text":
                    text_parts.append(block.get("text", ""))
            content = "\n".join(part for part in text_parts if part)
        out.append({"role": role, "content": content if isinstance(content, str) else str(content)})
    return out


class BridgeHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def _send_json(self, status: int, payload: dict):
        body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path in ("/health", "/healthz"):
            self._send_json(200, {"ok": True, "ollama_model": OLLAMA_MODEL})
            return
        self._send_json(404, {"error": {"message": "not found"}})

    def do_POST(self):
        if self.path not in ("/v1/messages", "/messages", "/v1/messages?beta=true"):
            self._send_json(404, {"error": {"message": "unsupported path"}})
            return

        length = int(self.headers.get("Content-Length", "0"))
        raw = self.rfile.read(length)
        try:
            payload = json.loads(raw.decode("utf-8")) if raw else {}
        except json.JSONDecodeError:
            self._send_json(400, {"error": {"message": "invalid json"}})
            return

        # Extract system message if present
        system_content = ""
        if isinstance(payload.get("system"), str):
            system_content = payload["system"]
        elif isinstance(payload.get("system"), list):
            parts = []
            for block in payload["system"]:
                if isinstance(block, dict) and block.get("type") == "text":
                    parts.append(block.get("text", ""))
            system_content = "\n".join(parts)

        ollama_messages = to_ollama_messages(payload.get("messages", []))
        if system_content:
            ollama_messages.insert(0, {"role": "system", "content": system_content})

        ollama_payload = {
            "model": OLLAMA_MODEL,
            "messages": ollama_messages,
            "stream": False,
        }

        request = Request(
            f"{OLLAMA_BASE_URL}/v1/chat/completions",
            data=json.dumps(ollama_payload, ensure_ascii=False).encode("utf-8"),
            method="POST",
            headers={"content-type": "application/json"},
        )

        try:
            with urlopen(request, timeout=300) as resp:
                body = json.loads(resp.read().decode("utf-8"))
        except HTTPError as exc:
            self._send_json(exc.code, {"error": {"message": exc.read().decode("utf-8", errors="replace")}})
            return
        except URLError as exc:
            self._send_json(502, {"error": {"message": f"ollama connection failed: {exc.reason}"}})
            return
        except Exception as exc:
            self._send_json(500, {"error": {"message": f"bridge error: {exc}"}})
            return

        # Extract text from OpenAI-format response
        text = ""
        choices = body.get("choices") or []
        if choices:
            text = (((choices[0] or {}).get("message") or {}).get("content")) or ""

        # Map to Anthropic response format
        anthropic_response = {
            "id": f"msg_{int(time.time() * 1000)}",
            "type": "message",
            "role": "assistant",
            "model": OLLAMA_MODEL,
            "content": [{"type": "text", "text": text}],
            "stop_reason": "end_turn",
            "stop_sequence": None,
            "usage": {
                "input_tokens": ((body.get("usage") or {}).get("prompt_tokens")) or 0,
                "output_tokens": ((body.get("usage") or {}).get("completion_tokens")) or 0,
            },
        }
        self._send_json(200, anthropic_response)

    def log_message(self, fmt, *args):
        sys.stderr.write("[%s] %s\n" % (self.log_date_time_string(), fmt % args))


def main():
    server = ThreadingHTTPServer((LISTEN_HOST, LISTEN_PORT), BridgeHandler)
    print(
        f"anthropic_to_ollama_bridge listening on http://{LISTEN_HOST}:{LISTEN_PORT}"
        f" -> {OLLAMA_BASE_URL} ({OLLAMA_MODEL})",
        flush=True,
    )
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("Shutting down.", flush=True)
        server.shutdown()


if __name__ == "__main__":
    main()
