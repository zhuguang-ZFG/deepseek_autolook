#!/usr/bin/env python3
"""
Fixed-port Anthropic-compatible upstream proxy.
Each instance listens on a fixed local port and forwards to one upstream provider.

Environment:
  LISTEN_HOST          (default: 127.0.0.1)
  LISTEN_PORT          (required)
  UPSTREAM_BASE_URL    (required)
  UPSTREAM_AUTH_TOKEN  (required)
  UPSTREAM_MODEL       (optional — injected into every request)
"""
import json
import os
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen


LISTEN_HOST = os.environ.get("LISTEN_HOST", "127.0.0.1")
LISTEN_PORT = int(os.environ["LISTEN_PORT"])
UPSTREAM_BASE_URL = os.environ["UPSTREAM_BASE_URL"].rstrip("/")
UPSTREAM_AUTH_TOKEN = os.environ["UPSTREAM_AUTH_TOKEN"]
UPSTREAM_MODEL = os.environ.get("UPSTREAM_MODEL", "")
UPSTREAM_BASE_URL_LOWER = UPSTREAM_BASE_URL.lower()

# Provider-specific auth header strategy
# GitHub Copilot uses Bearer; OpenRouter uses Bearer; others use x-api-key + Bearer
_GITHUB_COPILOT = "githubcopilot.com" in UPSTREAM_BASE_URL_LOWER
_OPENROUTER = "openrouter.ai" in UPSTREAM_BASE_URL_LOWER


def build_upstream_headers(client_headers):
    """Build upstream request headers with correct auth for the target provider."""
    headers = {
        "content-type": "application/json",
        "anthropic-version": client_headers.get("anthropic-version", "2023-06-01"),
    }
    if _GITHUB_COPILOT or _OPENROUTER:
        headers["authorization"] = f"Bearer {UPSTREAM_AUTH_TOKEN}"
    else:
        # Most Anthropic-compatible APIs accept x-api-key, api-key, or Bearer
        headers["x-api-key"] = UPSTREAM_AUTH_TOKEN
        headers["api-key"] = UPSTREAM_AUTH_TOKEN
        headers["authorization"] = f"Bearer {UPSTREAM_AUTH_TOKEN}"
    return headers


class ProxyHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def _send_json(self, status: int, payload: dict):
        body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        parsed = urlparse(self.path)
        # Health check
        if parsed.path in ("/health", "/healthz", "/"):
            self._send_json(200, {"ok": True, "upstream_model": UPSTREAM_MODEL or None})
            return
        # Model list (needed by some clients)
        if parsed.path == "/v1/models":
            model_id = UPSTREAM_MODEL or "upstream-model"
            self._send_json(200, {
                "data": [{
                    "id": model_id,
                    "type": "model",
                    "display_name": model_id,
                }],
                "has_more": False,
            })
            return
        self._send_json(404, {"error": {"message": "not found"}})

    def do_HEAD(self):
        parsed = urlparse(self.path)
        if parsed.path in ("/", "/health", "/healthz"):
            self.send_response(200)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        self.send_response(404)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def do_POST(self):
        length = int(self.headers.get("Content-Length", "0"))
        raw = self.rfile.read(length)
        parsed = urlparse(self.path)

        # Token counting endpoint — lightweight client-side approximation
        if parsed.path == "/v1/messages/count_tokens":
            try:
                payload = json.loads(raw.decode("utf-8")) if raw else {}
            except json.JSONDecodeError:
                self._send_json(400, {"error": {"message": "invalid json"}})
                return
            serialized = json.dumps(payload, ensure_ascii=False)
            approx_tokens = max(1, len(serialized) // 4) if serialized else 0
            self._send_json(200, {"input_tokens": approx_tokens})
            return

        # Only handle message creation
        if parsed.path not in ("/v1/messages", "/messages"):
            self._send_json(404, {"error": {"message": "unsupported path"}})
            return

        try:
            payload = json.loads(raw.decode("utf-8")) if raw else {}
        except json.JSONDecodeError:
            self._send_json(400, {"error": {"message": "invalid json"}})
            return

        # Inject the upstream model if configured
        if UPSTREAM_MODEL:
            payload["model"] = UPSTREAM_MODEL

        upstream_url = f"{UPSTREAM_BASE_URL}/v1/messages"
        request = Request(
            upstream_url,
            data=json.dumps(payload, ensure_ascii=False).encode("utf-8"),
            method="POST",
            headers=build_upstream_headers(self.headers),
        )

        try:
            with urlopen(request, timeout=180) as resp:
                body = resp.read()
                self.send_response(resp.status)
                self.send_header("Content-Type", resp.headers.get("Content-Type", "application/json"))
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)
        except HTTPError as exc:
            body = exc.read()
            self.send_response(exc.code)
            self.send_header("Content-Type", exc.headers.get("Content-Type", "application/json"))
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        except URLError as exc:
            self._send_json(502, {"error": {"message": f"upstream connection failed: {exc.reason}"}})
        except Exception as exc:
            self._send_json(500, {"error": {"message": f"proxy error: {exc}"}})

    def log_message(self, fmt, *args):
        sys.stderr.write("[%s] %s\n" % (self.log_date_time_string(), fmt % args))


def main():
    server = ThreadingHTTPServer((LISTEN_HOST, LISTEN_PORT), ProxyHandler)
    print(
        f"fixed_anthropic_proxy listening on http://{LISTEN_HOST}:{LISTEN_PORT}"
        f" -> {UPSTREAM_BASE_URL} ({UPSTREAM_MODEL or 'no model override'})",
        flush=True,
    )
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("Shutting down.", flush=True)
        server.shutdown()


if __name__ == "__main__":
    main()
