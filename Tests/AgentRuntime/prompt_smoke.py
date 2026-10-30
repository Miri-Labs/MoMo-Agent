"""Capture real Hermes request assembly with synthetic records and a local scripted provider.

No phone, user profile, credentials or external model is used. Run with the prepared Hermes Python.
"""
import argparse
import faulthandler
import hashlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import sys
import tempfile
import threading
import time
import uuid
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
sys.path[:0] = [str(ROOT / "Apps/MacApp/Runtime"), str(ROOT / "Apps/MacApp/Context"),
                str(ROOT / "Vendor/HermesAgent")]


def run(output):
    captures = []

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *_): pass
        def do_POST(self):
            body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
            if "messages" in body:
                captures.append(body)
            response = {"id": "prompt-fixture", "object": "chat.completion", "created": int(time.time()),
                        "model": "momo-prompt-fixture", "choices": [{"index": 0, "finish_reason": "stop",
                        "message": {"role": "assistant", "content": "Synthetic provider: prompt received."}}],
                        "usage": {"prompt_tokens": 100, "completion_tokens": 10, "total_tokens": 110}}
            data = json.dumps(response).encode()
            self.send_response(200); self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(data))); self.end_headers(); self.wfile.write(data)

    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    with tempfile.TemporaryDirectory(prefix="momo-prompt-") as temp:
        data = Path(temp) / "agent"
        import momo_agent
        momo_agent.initialize(data, 18765)
        os.environ.clear()
        os.environ.update(momo_agent.child_environment(data))
        # Explicit temporary HOME also isolates upstream default config and skill discovery.
        os.environ.update(HOME=temp, PATH=os.defpath, HERMES_HOME=str(data / "hermes"),
                          HERMES_RUNTIME_DIR=str(data / "runtime/tools"), TERMINAL_CWD=str(data / "workspace"),
                          HERMES_DISABLE_TOOL_USE_ENFORCEMENT="1")
        config = json.loads((data / "hermes/config.yaml").read_text())
        config["model"] = {"provider": "custom", "default": "momo-prompt-fixture", "streaming": False,
                           "base_url": f"http://127.0.0.1:{server.server_port}/v1"}
        with patch.object(momo_agent, "prepared_python", return_value=Path(sys.executable)):
            momo_agent.configure_context(data, config, None)
        from context_store import ContextStore, digest
        store = ContextStore(data / "context")
        now = time.time()
        sample = dict(library_id=str(uuid.uuid4()), session_id=str(uuid.uuid4()), device_id=str(uuid.uuid4()),
                      generation=0, version=1, deleted=False, recorded_at=now-300,
                      spans=[dict(id=str(uuid.uuid4()), recorded_at=now-300,
                                  text="小林说：方案草稿周五先给我看一下。用户说：好，但最终时间还要确认。"),
                             dict(id=str(uuid.uuid4()), recorded_at=now-240,
                                  text="同事说：我这周睡得很少。用户说：这周我想恢复散步，先从每天二十分钟开始。")])
        sample["text_sha256"] = digest("\n".join(s["text"] for s in sample["spans"]))
        store.sync_source(sample)
        memory_dir = data / "hermes/memories"; memory_dir.mkdir(exist_ok=True)
        (memory_dir / "USER.md").write_text("[Synthetic example] 用户偏好中文、简洁的回答。\n")
        (memory_dir / "MEMORY.md").write_text("[Synthetic example] 用户正在比较个人助手的手机与 Mac 分工；具体实现以当前资料为准。\n")
        print("Loading pinned Hermes in the isolated profile", flush=True)
        faulthandler.dump_traceback_later(45)
        from run_agent import AIAgent
        from agent.system_prompt import build_system_prompt_parts
        from agent.prompt_builder import TASK_COMPLETION_GUIDANCE
        print("Constructing native agent and discovering MoMo plugin", flush=True)
        agent = AIAgent(model="momo-prompt-fixture", provider="custom", api_key="synthetic-not-a-key",
                        base_url=config["model"]["base_url"], api_mode="chat_completions", platform="api_server",
                        enabled_toolsets=config["platform_toolsets"]["api_server"], max_iterations=2,
                        skip_background_review=True, quiet_mode=True, session_id="momo-prompt-synthetic")
        print("Capturing synthetic model requests", flush=True)
        parts = build_system_prompt_parts(agent)
        first = agent.run_conversation("刚才提到的方案草稿，帮我回顾一下时间和需要确认的事。")
        assert captures, "No request reached the local provider"
        wire = captures[0]
        system = "\n\n".join(m["content"] for m in wire["messages"] if m["role"] in {"system", "developer"})
        user = next(m["content"] for m in reversed(wire["messages"]) if m["role"] == "user")
        assert TASK_COMPLETION_GUIDANCE in system, "Upstream execution guidance was replaced"
        assert "## Plugin Context: momoagent" in system, "Native plugin was not discovered"
        assert (ROOT / "Apps/MacApp/Runtime/prompt_plugin/policy.md").read_text().strip() in system, "Product policy was truncated"
        assert "[Synthetic example] 用户偏好" in system, "Native USER memory missing"
        assert "MOMO_RECENT_CONTEXT_JSON=" in user and "最终时间还要确认" in user
        assert "小林说" not in system, "Recorded speech gained system prompt authority"
        assert '"status":"unavailable"' in user, "Unavailable health capability misrepresented"
        sample["version"] += 1
        sample["spans"][0]["text"] = "用户更正：草稿改为周三。"
        sample["text_sha256"] = digest("\n".join(s["text"] for s in sample["spans"]))
        store.sync_source(sample)
        agent.run_conversation("时间改了吗？", conversation_history=first["messages"])
        latest = next(m["content"] for m in reversed(captures[-1]["messages"]) if m["role"] == "user")
        assert "草稿改为周三" in latest and '"source_revision":"0:2:' in latest
        second_system = "\n\n".join(m["content"] for m in captures[-1]["messages"] if m["role"] in {"system", "developer"})
        assert second_system == system, "Recent context invalidated the upstream system prefix"
        from transcript_ingestion import prepare, prompt
        job = store.db.execute("SELECT * FROM jobs WHERE state='pending' ORDER BY rowid DESC LIMIT 1").fetchone()
        batch_prompt = prompt(prepare(store, job))
        from hermes_cli.lifecycle import invoke_hook
        assert not any(r for r in invoke_hook("pre_llm_call", platform="api_server", user_message=batch_prompt,
                                             parent_session_id="")), "Ingestion received unrelated recent transcripts"
        output.mkdir(parents=True, exist_ok=True)
        for name, value in (("system-prompt.txt", system), ("current-turn.txt", user),
                            ("transcript-ingestion.txt", batch_prompt), ("soul.txt", (data / "hermes/SOUL.md").read_text())):
            (output / name).write_text(value + "\n")
        (output / "request.json").write_text(json.dumps(wire, ensure_ascii=False, indent=2) + "\n")
        (output / "system-parts.json").write_text(json.dumps(parts, ensure_ascii=False, indent=2) + "\n")
        (output / "validation.json").write_text(json.dumps({"model": "local scripted fixture", "real_Hermes": True,
            "physical_phone": False, "synthetic_personal_data": True, "requests": len(captures),
            "system_sha256": hashlib.sha256(system.encode()).hexdigest(),
            "checks": ["native plugin discovery", "upstream guidance retained", "native memory included",
                       "recordings in user context only", "health unavailable", "source revision refreshed",
                       "system prefix byte stable", "ingestion context isolated"]}, indent=2) + "\n")
        faulthandler.cancel_dump_traceback_later()
        store.close()
        agent.release_clients()
        print(json.dumps({"result": "passed", "output": str(output), "requests": len(captures)}, ensure_ascii=False))
    server.shutdown(); server.server_close()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(); parser.add_argument("--output", type=Path, required=True)
    run(parser.parse_args().output.resolve())
