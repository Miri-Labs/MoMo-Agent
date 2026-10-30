"""Scripted model for transport/tool lifecycle checks, not an intelligence evaluation."""
import json
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


def start_model():
    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *_args):
            pass

        def respond(self, value):
            raw = json.dumps(value).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(raw)))
            self.end_headers()
            self.wfile.write(raw)

        def do_GET(self):
            self.respond({"object": "list", "data": [{"id": "momo-runtime-fixture", "object": "model"}]})

        def do_POST(self):
            body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
            messages = body["messages"]
            start = max(i for i, message in enumerate(messages) if message["role"] == "user")
            results = [message for message in messages[start:] if message["role"] == "tool"]
            tools = [tool["function"]["name"] for tool in body.get("tools", [])]
            stage = len(results)
            name = None
            arguments = {}
            deferred = "tool_call" in tools
            if stage == 0:
                time.sleep(2)
                if deferred:
                    name, arguments = "tool_search", {"queries": ["MoMo runtime record_probe"], "limit": 1}
                else:
                    name = next((name for name in tools if name.endswith("record_probe")), None)
            elif deferred and stage == 1:
                name, arguments = "tool_describe", {"names": ["mcp__momo_probe__record_probe"]}
            elif deferred and stage == 2:
                name, arguments = "tool_call", {"calls": [{"name": "mcp__momo_probe__record_probe", "arguments": {}}]}
            if name:
                message = {"role": "assistant", "content": None, "tool_calls": [{
                    "id": f"fixture_{stage}", "type": "function",
                    "function": {"name": name, "arguments": json.dumps(arguments)},
                }]}
                finish = "tool_calls"
            else:
                message = {"role": "assistant", "content": "Fixture result: " + (str(results[-1]["content"]) if results else "MISSING_TOOL")}
                finish = "stop"
            self.respond({"id": f"fixture-{time.time_ns()}", "object": "chat.completion", "created": int(time.time()),
                          "model": "momo-runtime-fixture", "choices": [{"index": 0, "message": message, "finish_reason": finish}],
                          "usage": {"prompt_tokens": 100, "completion_tokens": 20, "total_tokens": 120}})

    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server
