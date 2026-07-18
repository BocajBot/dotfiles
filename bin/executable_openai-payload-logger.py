#!/usr/bin/env python3
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import urllib.request
import urllib.error
import time

UPSTREAM = "http://127.0.0.1:9292"

class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        self.forward()

    def do_POST(self):
        self.forward()

    def forward(self):
        length = int(self.headers.get("content-length", "0") or "0")
        body = self.rfile.read(length) if length else b""

        if self.path == "/v1/chat/completions" and body:
            try:
                data = json.loads(body.decode("utf-8", errors="replace"))
                messages = data.get("messages", [])
                tools = data.get("tools", [])
                model = data.get("model", "")

                char_count = sum(len(str(m.get("content", ""))) for m in messages)
                approx_tokens = char_count / 4

                print()
                print("=" * 80)
                print(time.strftime("%Y-%m-%d %H:%M:%S"))
                print(f"model: {model}")
                print(f"messages: {len(messages)}")
                print(f"tools: {len(tools)}")
                print(f"message_chars: {char_count}")
                print(f"approx_message_tokens: {approx_tokens:.0f}")
                print(f"body_bytes: {len(body)}")

                for i, m in enumerate(messages):
                    role = m.get("role", "?")
                    content = str(m.get("content", ""))
                    print(f"  [{i}] role={role} chars={len(content)} preview={content[:160]!r}")

                if tools:
                    tool_chars = len(json.dumps(tools))
                    print(f"tool_schema_chars: {tool_chars}")
                    print(f"approx_tool_schema_tokens: {tool_chars / 4:.0f}")

                print("=" * 80)
            except Exception as e:
                print(f"Could not inspect request: {e}")

        req = urllib.request.Request(
            UPSTREAM + self.path,
            data=body if body else None,
            method=self.command,
            headers={
                k: v for k, v in self.headers.items()
                if k.lower() not in {"host", "content-length", "connection"}
            },
        )

        try:
            with urllib.request.urlopen(req, timeout=600) as resp:
                resp_body = resp.read()
                self.send_response(resp.status)
                for k, v in resp.headers.items():
                    if k.lower() not in {"transfer-encoding", "connection"}:
                        self.send_header(k, v)
                self.end_headers()
                self.wfile.write(resp_body)
        except urllib.error.HTTPError as e:
            resp_body = e.read()
            self.send_response(e.code)
            for k, v in e.headers.items():
                if k.lower() not in {"transfer-encoding", "connection"}:
                    self.send_header(k, v)
            self.end_headers()
            self.wfile.write(resp_body)
        except Exception as e:
            body = json.dumps({"error": str(e)}).encode()
            self.send_response(502)
            self.send_header("content-type", "application/json")
            self.end_headers()
            self.wfile.write(body)

    def log_message(self, fmt, *args):
        return

if __name__ == "__main__":
    addr = ("127.0.0.1", 9299)
    print(f"Logging proxy listening on http://{addr[0]}:{addr[1]}")
    print(f"Forwarding to {UPSTREAM}")
    ThreadingHTTPServer(addr, Handler).serve_forever()
