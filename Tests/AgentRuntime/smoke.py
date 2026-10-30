"""Real embedded Hermes + real MCP + Swift client. All inputs/model answers synthetic."""
import argparse
import json
from pathlib import Path
import subprocess
import sys
import time
import uuid
from model_fixture import start_model

ROOT = Path(__file__).resolve().parents[2]
ENTRY = ROOT / "Apps/MacApp/Runtime/momo_agent.py"


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--data-dir", type=Path, required=True,
                        help="An initialized, prepared runtime dedicated to this test; its model config is replaced")
    args = parser.parse_args()
    data = args.data_dir.resolve()
    python = data / "runtime/venv/bin/python"
    probe_dir = subprocess.check_output(["swift", "build", "--package-path", str(ROOT / "Packages/MoMoAgentAgentClient"),
                                        "--show-bin-path"], text=True).strip()
    probe = Path(probe_dir) / "momo-agent-probe"
    artifact = data / "workspace/probe-receipt.json"
    if artifact.exists():
        raise RuntimeError("Use a fresh test runtime; a receipt already exists")
    model = start_model()
    configuration = {"model": {"provider": "custom", "default": "momo-runtime-fixture", "streaming": False,
                               "base_url": f"http://127.0.0.1:{model.server_port}/v1", "context_length": 128000},
                     "agent": {"max_turns": 8}, "updates": {"check": False},
                     "memory": {"memory_enabled": False, "user_profile_enabled": False},
                     "platform_toolsets": {"api_server": ["momo_probe"]},
                     "mcp_servers": {"momo_probe": {"command": str(python), "args": [str(Path(__file__).with_name("mcp_fixture.py"))],
                                                    "env": {"MOMO_PROBE_ARTIFACT": str(artifact)}}}}
    (data / "hermes/config.yaml").write_text(json.dumps(configuration, indent=2))
    (data / "hermes/.env").write_text("OPENAI_API_KEY=synthetic-local-only\n")
    checks = []
    process = None
    log = (data / "runtime/smoke-gateway.log").open("w")

    def check(name, passed):
        checks.append({"name": name, "passed": bool(passed)})
        print(("PASS " if passed else "FAIL ") + name, flush=True)
        if not passed:
            raise AssertionError(name)

    def client(command, *arguments):
        result = subprocess.run([str(probe), command, str(data), *arguments], capture_output=True, text=True, timeout=40)
        if result.returncode:
            raise RuntimeError(result.stderr[-1500:])
        return json.loads(result.stdout)

    def launch():
        child = subprocess.Popen([sys.executable, str(ENTRY), "serve", "--data-dir", str(data)],
                                 cwd=ROOT, stdout=log, stderr=subprocess.STDOUT)
        try:
            last_error = "No capability response"
            for attempt in range(90):
                if child.poll() is not None:
                    raise RuntimeError("Embedded gateway exited; inspect smoke-gateway.log")
                try:
                    capabilities = client("capabilities")
                    if capabilities["features"]["run_submission"]:
                        return child
                except RuntimeError as error:
                    last_error = str(error)
                    if attempt in (0, 30, 60):
                        print("Waiting for Gateway: " + last_error[-400:], flush=True)
                    time.sleep(1)
            raise TimeoutError("Embedded gateway was not ready: " + last_error[-1000:])
        except BaseException:
            shutdown(child)
            raise

    def shutdown(child):
        if child and child.poll() is None:
            child.terminate()
            try:
                child.wait(timeout=20)
            except subprocess.TimeoutExpired:
                child.kill()
                child.wait(timeout=5)

    try:
        process = launch()
        check("Swift client discovers embedded Gateway capabilities", True)
        operation, session = str(uuid.uuid4()), "momo-" + str(uuid.uuid4())
        prompt = "Run the record_probe tool once and report its exact result."
        accepted = client("submit", session, operation, prompt)
        check("A separate Swift client submits and exits before completion", accepted["status"] not in {"completed", "failed"})
        for _ in range(60):
            snapshot = client("status", accepted["run_id"])
            if snapshot["status"] in {"completed", "failed", "cancelled", "interrupted", "unknown"}:
                break
            time.sleep(1)
        check("Gateway continues after client exit and returns real MCP output",
              snapshot["status"] == "completed" and "MOMO_SOURCE_FORK_OK" in snapshot.get("output", ""))
        repeated = client("submit", session, operation, prompt)
        check("Same operation returns the same run without a second tool execution",
              repeated["run_id"] == accepted["run_id"] and json.loads(artifact.read_text())["executions"] == 1)
        shutdown(process)
        process = launch()
        restored = client("status", accepted["run_id"])
        check("Gateway restart preserves the completed run", restored["status"] == "completed")
        log.flush()
        check("Runtime loads the source embedded in this repository",
              str(ROOT / "Vendor/HermesAgent/gateway/run.py") in (data / "runtime/smoke-gateway.log").read_text())
    finally:
        shutdown(process)
        model.shutdown()
        model.server_close()
        log.close()
        (data / "runtime/smoke-results.json").write_text(json.dumps({
            "checks": checks, "model": "scripted local fixture", "phone": "not used",
            "network": "local loopback only", "source": str(ROOT / "Vendor/HermesAgent"),
        }, indent=2) + "\n")


if __name__ == "__main__":
    main()
