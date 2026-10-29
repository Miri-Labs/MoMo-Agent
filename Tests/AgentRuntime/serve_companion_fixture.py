"""Loopback-only Mac menu companion fixture; never submits model or computer tasks.

Pass a directory containing identity.json and state.json ({"mode": "active"}).
Modes: active, many, working, idle, offline. Used with an isolated app ID and data directory.
"""
import argparse
import json
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlparse


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("directory", type=Path)
    args = parser.parse_args()
    identity = json.loads((args.directory / "identity.json").read_text())
    port = urlparse(identity["base_url"]).port
    session = "momo-main-" + identity["assistant_id"]

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *_):
            pass

        def do_GET(self):
            self.respond()

        def do_POST(self):
            self.rfile.read(int(self.headers.get("Content-Length", 0)))
            self.respond()

        def respond(self):
            credential = self.headers.get("api-key") or self.headers.get("Authorization", "").removeprefix("Bearer ")
            if credential != "companion-local-test-only":
                self.send_error(401)
                return
            mode = json.loads((args.directory / "state.json").read_text())["mode"]
            path = urlparse(self.path).path
            if path == "/status":
                result = dict(agent_online=mode != "offline", tunnel=dict(state="stopped", mode="self_hosted"), devices=[])
            elif path == "/v1/capabilities":
                result = dict(features=dict(run_submission=True, run_status=True, run_stop=True,
                    runs_idempotency=dict(supported=True, durable=True, retention_seconds=86400)))
            elif path == "/momo/v1/conversation":
                result = dict(conversation_id="fixture", session_id=session, assistant_id=identity["assistant_id"],
                    instance_id=identity["instance_id"], capabilities=dict(shared_conversation=True, server_owned_completion=True,
                    durable_steering=True, independent_chat_while_waiting=True, system_push=False))
            elif path == "/momo/v1/conversation/messages" and self.command == "GET":
                result = dict(data=[], next_cursor=0, has_more=False)
            elif path == "/momo/v1/conversation/runs":
                runs = []
                if mode in ("active", "many", "working", "offline"):
                    titles = ["整理今天的录音", "发送会议总结", "整理下载文件", "准备周会", "检查代码", "查找旅行资料", "整理购物清单"]
                    for i, title in enumerate(titles[:7 if mode == "many" else 2]):
                        run = dict(run_id=f"run-{i}", work_id=f"work-{i}", session_id=session,
                            status="running", title=title, execution_generation=1)
                        if i == 1 and mode != "working":
                            run["pending_controls"] = [dict(prompt_id="confirm", kind="approval", prompt="发送前需要你确认", choices=["once", "deny"])]
                        runs.append(run)
                # Two native workers still belong to one user task.
                work = [dict(id=f"process-{i}", work_id="work-0", state="running", report_state="pending",
                             kind="process", title="录音整理子任务") for i in range(2)] if runs else []
                result = dict(data=runs, background_work=work, next_cursor=0, has_more=False)
            elif path == "/momo/v1/conversation/adopt":
                result = dict(adopted=True)
            elif path == "/momo/v1/conversation/read":
                result = {}
            else:
                print(f"Unsupported fixture request: {self.command} {path}", flush=True)
                self.send_error(404)
                return
            payload = json.dumps(result, ensure_ascii=False).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)

    control = ThreadingHTTPServer(("127.0.0.1", port + 3), Handler)
    agent = ThreadingHTTPServer(("127.0.0.1", port), Handler)
    threading.Thread(target=control.serve_forever, daemon=True).start()
    print(f"Companion fixture listening on loopback ports {port} and {port + 3}", flush=True)
    agent.serve_forever()


if __name__ == "__main__":
    main()
