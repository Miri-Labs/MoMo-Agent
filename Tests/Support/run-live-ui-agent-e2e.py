"""Run the opt-in J02 simulator UI journey; credentials never enter launch arguments."""

import argparse
from contextlib import closing
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import signal
import sqlite3
import stat
import subprocess
import uuid

BUNDLE_ID = "com.momoagent.ios"
CREDENTIAL_NAME = "live-ui-agent-credentials.json"
TEST_NAME = "MoMoAgentUITests/PhoneLiveAgentJourneyTests/testRealASRAnswersThroughChatWithoutCreatingArtifacts"
PUBLIC_AUDIO_SHA256 = "b77f1794fe374a0ba1ee1dc458bfaf9349496cbbfc32780c50ba3c5a7ad8e373"
PROVIDER_URL = "https://openrouter.ai/api/v1"
PROVIDER_PROTOCOL = "openAICompletions"
PROVIDER_ID = "momoagent-" + hashlib.sha256((PROVIDER_PROTOCOL + "\n" + PROVIDER_URL).encode()).hexdigest()
PROMPT = "What was just discussed? Keep it brief, cite the source and do not guess unclear details."
TOOLS = {"get_context_status", "list_recordings", "search_transcripts", "read_transcript", "play_audio"}
SUPPORT = Path("Library/Application Support/MoMoAgent")


class Failure(Exception):
    """Only fixed codes cross the CLI/report boundary; underlying exceptions stay private."""


def require(condition, code):
    if not condition:
        raise Failure(code)


def read_key(path):
    require(path is not None and path.is_file(), "credentials_missing")
    require(path.stat().st_size <= 1024 * 1024, "credentials_invalid")
    values = []
    for line in path.read_text().splitlines():
        match = re.fullmatch(r"\s*(?:export\s+)?OPENROUTER_API_KEY\s*=\s*(.*?)\s*", line)
        if match:
            value = match[1]
            if value.startswith(("'", '"')):
                require(len(value) >= 2 and value[-1] == value[0], "credentials_invalid")
                value = value[1:-1]
            values.append(value)
    require(len(values) == 1 and 0 < len(values[0].encode()) <= 512
            and all(33 <= ord(c) <= 126 and c not in "\"'`$\\" for c in values[0]), "credentials_invalid")
    return values[0]


def write_credentials(path, key, model, run_id, route):
    payload = json.dumps(dict(enabled=True, apiKey=key, modelID=model, runID=run_id, networkRoute=route))
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    identity = os.fstat(descriptor)
    complete = False
    try:
        with os.fdopen(descriptor, "w") as stream:
            os.fchmod(stream.fileno(), 0o600)
            stream.write(payload)
            stream.flush()
            os.fsync(stream.fileno())
        complete = True
    finally:
        if not complete and os.path.lexists(path):
            current = path.lstat()
            if (current.st_dev, current.st_ino) == (identity.st_dev, identity.st_ino):
                path.unlink()
    return (identity.st_dev, identity.st_ino)


def redact(text, key):
    if key:
        text = text.replace(key, "[REDACTED]")
        text = text.replace(json.dumps(key)[1:-1], "[REDACTED]")
    text = re.sub(r"(?i)Bearer\s+[^\s\"\\]+", "Bearer [REDACTED]", text)
    return re.sub(r"sk-(?:or-v1-)?[A-Za-z0-9_-]{12,}", "[REDACTED]", text)


def write_json(path, value, key=""):
    path.write_text(redact(json.dumps(value, ensure_ascii=False, indent=2) + "\n", key))


def prepare_xctestrun(source, products, destination, run_id):
    """Preserve v1/v2 layout; relocating the plist must not relocate __TESTROOT__."""
    def replace(value):
        if isinstance(value, str):
            return value.replace("__TESTROOT__", str(products.resolve()))
        if isinstance(value, list):
            return [replace(item) for item in value]
        if isinstance(value, dict):
            return {name: replace(item) for name, item in value.items()}
        return value

    value = replace(plistlib.loads(source.read_bytes()))
    matches = 0
    configurations = value.get("TestConfigurations")
    if configurations is not None:
        require(isinstance(configurations, list), "xctestrun_invalid")
        candidates = [(target.get("BlueprintName"), target) for config in configurations
                      for target in config.get("TestTargets", [])]
    else:
        candidates = list(value.items())
    for name, target in candidates:
        if name != "MoMoAgentUITests":
            continue
        require(isinstance(target, dict) and target.get("IsUITestBundle") is True, "xctestrun_invalid")
        target.setdefault("EnvironmentVariables", {})["MOMO_LIVE_UI_RUN_ID"] = run_id
        target["OnlyTestIdentifiers"] = [TEST_NAME.split("/", 1)[1]]
        target["SkipTestIdentifiers"] = []
        matches += 1
    require(matches == 1, "xctestrun_target_not_unique")
    destination.write_bytes(plistlib.dumps(value))


def safe_path(root, relative, regular=True):
    """Reject path traversal and symlinks before reading files or deleting an isolated run."""
    relative = Path(relative)
    require(not relative.is_absolute() and relative.parts and ".." not in relative.parts, "evidence_path_invalid")
    cursor = root
    require(root.is_dir() and not root.is_symlink(), "evidence_path_invalid")
    for index, part in enumerate(relative.parts):
        cursor /= part
        info = cursor.lstat()
        expected = stat.S_ISREG if regular and index == len(relative.parts) - 1 else stat.S_ISDIR
        require(expected(info.st_mode), "evidence_path_invalid")
    return cursor


def decode(value):
    require(isinstance(value, (str, bytes)) and len(value) <= 8 * 1024 * 1024, "evidence_json_invalid")
    try:
        return json.loads(value)
    except (ValueError, UnicodeError):
        raise Failure("evidence_json_invalid") from None


def rows(database, query, parameters=()):
    result = [dict(row) for row in database.execute(query, parameters).fetchmany(4097)]
    require(len(result) <= 4096, "evidence_row_limit")
    return result


def one(values, code):
    require(len(values) == 1, code)
    return values[0]


def readonly(path):
    database = sqlite3.connect(path.as_uri() + "?mode=ro", uri=True)
    database.row_factory = sqlite3.Row
    database.execute("PRAGMA query_only=ON")
    database.setlimit(sqlite3.SQLITE_LIMIT_LENGTH, 8 * 1024 * 1024)
    return database


def frame_range(value):
    require(isinstance(value, dict) and type(value.get("start")) is int and type(value.get("count")) is int
            and value["start"] >= 0 and value["count"] > 0, "source_frames_invalid")
    return {"start": value["start"], "count": value["count"]}


def contains(outer, inner):
    return outer["start"] <= inner["start"] and inner["start"] + inner["count"] <= outer["start"] + outer["count"]


def sha256(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def archive_evidence(root, run_id):
    with closing(readonly(safe_path(root, SUPPORT / "archive.sqlite"))) as database:
        session = one(rows(database, "SELECT id,source_kind,generation,deleted,transcript_version,projection_version,projection_blocked FROM sessions"), "recording_not_unique")
        require(session["id"] == run_id and session["source_kind"] == "fixture" and session["deleted"] == 0
                and session["generation"] == 0 and session["transcript_version"] == 1
                and session["projection_version"] == 1 and session["projection_blocked"] == 0, "recording_invalid")
        chunk = one(rows(database, "SELECT id,session_id,epoch_id,manifest,manifest_hash,audio_hash,relative_path,retention FROM chunks"), "chunk_not_unique")
        manifest = decode(chunk["manifest"])
        require(chunk["id"] == run_id and chunk["session_id"] == run_id and chunk["epoch_id"] == run_id
                and chunk["retention"] == "present" and manifest["sourceKind"] == "fixture"
                and manifest["sourceBuild"] == "debug-ui-fixture" and manifest["sessionID"] == run_id
                and manifest["chunkID"] == run_id and manifest["epochID"] == run_id
                and manifest["representation"] == "full" and manifest["codec"] == "pcmInt16"
                and manifest["sampleRate"] == 16000 and manifest["channels"] == 1
                and manifest["audioSHA256"] == chunk["audio_hash"] == PUBLIC_AUDIO_SHA256, "audio_source_invalid")
        manifest_bytes = chunk["manifest"].encode() if isinstance(chunk["manifest"], str) else chunk["manifest"]
        require(hashlib.sha256(manifest_bytes).hexdigest() == chunk["manifest_hash"], "manifest_hash_invalid")
        audio = safe_path(root, chunk["relative_path"])
        require(audio.stat().st_size == manifest["byteCount"] and sha256(audio) == PUBLIC_AUDIO_SHA256, "audio_hash_invalid")
        chunk_frames = frame_range(manifest["frames"])
        require(chunk_frames["start"] == 0 and chunk_frames["count"] == manifest["decodedFrameCount"], "source_frames_invalid")
        window = one(rows(database, "SELECT id,session_id,epoch_id,generation,configuration_hash,descriptor,state,length(raw_result) AS result_bytes FROM analysis_windows"), "asr_window_not_unique")
        descriptor = decode(window.pop("descriptor"))
        require(window["state"] == "complete" and window["session_id"] == run_id and window["epoch_id"] == run_id
                and window["generation"] == session["generation"] and (window["result_bytes"] or 0) > 0
                and re.fullmatch(r"[a-f0-9]{64}", window["configuration_hash"]) is not None
                and descriptor["configurationFingerprint"] == window["configuration_hash"]
                and descriptor["id"] == window["id"] and descriptor["sessionID"] == run_id
                and descriptor["epochID"] == run_id, "asr_window_invalid")
        core = frame_range(descriptor["coreFrames"])
        require(contains(chunk_frames, core), "source_frames_invalid")
        window_source = one(descriptor["sources"], "window_source_not_unique")
        require(window_source["chunkID"] == run_id and window_source["audioSHA256"] == PUBLIC_AUDIO_SHA256
                and window_source["manifestSHA256"] == chunk["manifest_hash"]
                and contains(chunk_frames, frame_range(window_source["sourceFrames"]))
                and contains(window_source["sourceFrames"], core), "window_source_invalid")
        transcript_row = one(rows(database, "SELECT session_id,version,document FROM transcript_versions"), "transcript_not_unique")
        transcript = decode(transcript_row["document"])
        require(transcript_row["session_id"] == transcript["sessionID"] == run_id
                and transcript_row["version"] == transcript["version"] == 1
                and transcript["generation"] == session["generation"], "transcript_version_invalid")
        span = one(transcript["spans"], "transcript_span_not_unique")
        audio_range = one(span["sourceRanges"], "transcript_range_not_unique")
        require(span["chunkID"] == audio_range["chunkID"] == run_id and frame_range(span["frames"]) == core
                and frame_range(audio_range["frames"]) == core and isinstance(span["text"], str)
                and "早上9点" in span["text"] and "下午5点" in span["text"], "transcript_source_invalid")
        reference = dict(sessionID=run_id, spanID=span["id"], transcriptVersion=1, generation=session["generation"])
        require(not rows(database, "SELECT id FROM plans")
                and not rows(database, "SELECT plan_id FROM plan_sources"), "unexpected_plan_created")
        agent_source = one(rows(database, "SELECT agent_session_id,session_id,version,generation FROM agent_sources"), "agent_source_not_unique")
        require(agent_source["session_id"] == run_id and agent_source["version"] == 1
                and agent_source["generation"] == session["generation"], "agent_source_invalid")
        return dict(recording=session, audio=dict(chunkID=run_id, sha256=PUBLIC_AUDIO_SHA256,
                    manifestSHA256=chunk["manifest_hash"], frames=chunk_frames), window=window,
                    transcript=dict(sessionID=run_id, version=1, generation=session["generation"],
                                    spans=[dict(id=span["id"], text=span["text"], frames=core, sourceRanges=[audio_range])]),
                    agentSource=agent_source)


def message_text(message):
    content = message.get("content", [])
    if isinstance(content, str):
        return content
    require(isinstance(content, list), "pi_content_invalid")
    return "".join(block["text"] for block in content if block.get("type") == "text")


def pi_evidence(root, agent_session_id, model):
    agent_root = safe_path(root, SUPPORT / "Agent", regular=False)
    provider = decode(safe_path(root, SUPPORT / "Agent/provider.json").read_bytes())
    require(provider.get("baseURL") == PROVIDER_URL and provider.get("modelID") == model
            and provider.get("apiProtocol") == PROVIDER_PROTOCOL and provider.get("compatibility") == "standard",
            "provider_configuration_mismatch")
    directories = [path for path in agent_root.iterdir() if path.is_dir()]
    require(len(directories) == 1 and directories[0].name == agent_session_id, "agent_session_not_unique")
    path = safe_path(root, SUPPORT / "Agent" / str(uuid.UUID(agent_session_id)).upper() / "pi.sqlite")
    metadata = decode(safe_path(root, SUPPORT / "Agent" / str(uuid.UUID(agent_session_id)).upper() / "session.json").read_bytes())
    with closing(readonly(path)) as database:
        entries = rows(database, "SELECT id,conversation_id,record FROM entries ORDER BY id")
        submission = one(rows(database, "SELECT id,conversation_id,request_id,status,record FROM submissions"), "submission_not_unique")
    submitted = decode(submission["record"])
    require(submission["status"] == submitted["status"] == "done" and submitted.get("type", "input") == "input"
            and decode(submission["request_id"]) == submitted["requestId"] == metadata["operationID"]
            and submitted["conversationId"] == submission["conversation_id"], "submission_invalid")
    messages, calls, results, users, assistants = [], {}, {}, [], []
    for row in entries:
        entry = decode(row["record"])
        require(entry["id"] == row["id"] and entry["conversationId"] == row["conversation_id"], "pi_entry_invalid")
        for message in entry.get("model") or []:
            role = message.get("role")
            if role not in {"user", "assistant", "toolResult"}:
                continue
            require(row["conversation_id"] == submission["conversation_id"], "pi_conversation_invalid")
            text = message_text(message)
            item = dict(entryID=row["id"], role=role, text=text)
            if role == "user":
                users.append(item)
            elif role == "assistant":
                require(message.get("model") == model, "model_mismatch")
                require(message.get("provider") == PROVIDER_ID and message.get("api") == "openai-completions", "provider_mismatch")
                require(not message.get("errorMessage") and message.get("stopReason") not in {"error", "aborted"}, "model_failed")
                item.update(model=message["model"], provider=message["provider"], api=message["api"], stopReason=message["stopReason"])
                assistants.append(item)
                tool_calls = []
                for block in message.get("content", []):
                    if block.get("type") != "toolCall":
                        continue
                    require(block["name"] in TOOLS and block["id"] not in calls
                            and isinstance(block["arguments"], dict), "tool_call_invalid")
                    call = {field: block[field] for field in ("id", "name", "arguments")}
                    calls[block["id"]] = call
                    tool_calls.append(call)
                item["toolCalls"] = tool_calls
            else:
                call_id = message["toolCallId"]
                require(call_id in calls and call_id not in results and message.get("isError") is False
                        and calls[call_id]["name"] == message["toolName"], "tool_result_invalid")
                item.update(toolCallID=call_id, toolName=message["toolName"], isError=False)
                results[call_id] = item
            messages.append(item)
    user = one(users, "user_input_not_unique")
    require(user["text"] == PROMPT and user["entryID"] == submitted["entry"], "ui_prompt_mismatch")
    require(assistants and any(item["text"].strip() for item in assistants)
            and assistants[-1]["stopReason"] == "stop" and assistants[-1]["text"].strip()
            and assistants[-1]["entryID"] == submitted["answer"], "final_answer_invalid")
    require(calls.keys() == results.keys(), "tool_result_missing")
    return dict(sessionID=agent_session_id, providerConfiguration={field: provider[field] for field in
                ("baseURL", "modelID", "apiProtocol", "compatibility")}, submission={field: submitted[field] for field in
                ("id", "conversationId", "requestId", "status", "entry", "answer")}, messages=messages)


def collect_evidence(root, run_id, model, route):
    archive = archive_evidence(root, run_id)
    trace = pi_evidence(root, archive["agentSource"]["agent_session_id"], model)
    return dict(runID=run_id, modelID=model, configuredNetworkRoute=route,
                networkRouteEvidence="Debug bootstrap configuration; not a packet capture",
                fixtureKind="public zh.wav through production local ASR and chat UI",
                archive=archive, agent=trace, storageAndAgentChecksPassed=True)


def collect_diagnostics(root, run_id):
    """Preserve a safe trace even when strict source/model acceptance fails."""
    output = dict(runID=run_id, sessions=[], errorCodes=[])
    try:
        directory = safe_path(root, SUPPORT / "Agent", regular=False)
        candidates = [path for path in directory.iterdir() if path.is_dir()]
        require(len(candidates) <= 16, "diagnostic_session_limit")
        for candidate in sorted(candidates):
            try:
                session_id = str(uuid.UUID(candidate.name)).upper()
                database_path = safe_path(root, SUPPORT / "Agent" / session_id / "pi.sqlite")
                with closing(readonly(database_path)) as database:
                    entries = rows(database, "SELECT id,record FROM entries ORDER BY id")
                    submissions = rows(database, "SELECT id,status,record FROM submissions ORDER BY id")
                diagnostic = dict(sessionID=session_id, messages=[], submissions=[])
                output["sessions"].append(diagnostic)
                for row in submissions:
                    record = decode(row["record"])
                    status = row["status"] if row["status"] in {"queued", "placed", "done", "unanswered"} else "unknown"
                    item = dict(id=row["id"], status=status)
                    for field in ("conversationId", "requestId", "entry", "answer"):
                        if field in record:
                            item[field] = record[field]
                    diagnostic["submissions"].append(item)
                for row in entries:
                    for message in decode(row["record"]).get("model") or []:
                        role = message.get("role")
                        if role not in {"user", "assistant", "toolResult"}:
                            continue
                        item = dict(entryID=row["id"], role=role)
                        if role == "user":
                            item["text"] = message_text(message)
                        elif role == "assistant":
                            item.update({field: message.get(field) for field in ("model", "provider", "api")})
                            stop = message.get("stopReason")
                            item["stopReason"] = stop if stop in {"pending", "stop", "length", "toolUse", "error", "aborted", "deferred"} else "unknown"
                            item["errorUTF8Bytes"] = len(str(message.get("errorMessage") or "").encode())
                            item["text"] = message_text(message)
                            item["toolCalls"] = [{field: block.get(field) for field in ("id", "name", "arguments")}
                                                 for block in message.get("content", []) if block.get("type") == "toolCall"
                                                 and block.get("name") in TOOLS]
                        else:
                            item.update(toolCallID=message.get("toolCallId"),
                                        toolName=message.get("toolName") if message.get("toolName") in TOOLS else "unknown",
                                        isError=message.get("isError") is not False)
                            if item["isError"]:
                                item["resultUTF8Bytes"] = len(message_text(message).encode())
                            else:
                                item["text"] = message_text(message)
                        diagnostic["messages"].append(item)
            except (Failure, OSError, ValueError, KeyError, TypeError, sqlite3.Error):
                output["errorCodes"].append("diagnostic_session_unavailable")
    except (Failure, OSError):
        output["errorCodes"].append("diagnostic_store_unavailable")
    return output


def command_output(command, code, environment=None):
    if environment is None:
        environment = {name: value for name, value in os.environ.items() if not name.endswith("API_KEY")}
    result = subprocess.run(command, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, env=environment, timeout=30)
    require(result.returncode == 0, code)
    return result.stdout.decode().strip()


def app_container(simulator, kind="data"):
    return Path(command_output(["xcrun", "simctl", "get_app_container", simulator, BUNDLE_ID, kind], "container_unavailable"))


def simulator_data_root(bundle, simulator):
    return one([path for path in bundle.parents if path.name == "data"
                and path.parent.name.upper() == simulator.upper()], "host_path_invalid")


def stop_host(simulator):
    bundle = app_container(simulator, "app")
    executable = plistlib.loads((bundle / "Info.plist").read_bytes())["CFBundleExecutable"]
    prefix = simulator_data_root(bundle, simulator)

    def running():
        processes = command_output(["ps", "-axww", "-o", "comm="], "host_status_failed").splitlines()
        return any(line.strip().startswith(str(prefix) + "/Containers/Bundle/Application/")
                   and line.strip().endswith("/MoMoAgent.app/" + executable) for line in processes)

    if running():
        command_output(["xcrun", "simctl", "terminate", simulator, BUNDLE_ID], "host_stop_failed")
    require(not running(), "host_still_running")


def run_test(command, environment, log, key, cwd):
    process = subprocess.Popen(command, cwd=cwd, env=environment, stdout=subprocess.PIPE,
                               stderr=subprocess.STDOUT, start_new_session=True)
    captured = b""
    try:
        captured, _ = process.communicate(timeout=720)
        return process.returncode
    finally:
        if process.poll() is None:
            os.killpg(process.pid, signal.SIGTERM)
            try:
                captured, _ = process.communicate(timeout=10)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGKILL)
                captured, _ = process.communicate(timeout=10)
        log.write_text(redact(captured.decode(errors="replace"), key))


def remove_credential(container, run_id, owned_identity=None):
    path = container / "tmp" / CREDENTIAL_NAME
    if not path.exists() and not path.is_symlink():
        return
    require(not path.is_symlink() and path.is_file(), "credential_cleanup_unsafe")
    current = path.lstat()
    if owned_identity != (current.st_dev, current.st_ino):
        value = decode(path.read_bytes())
        require(value.get("runID") == run_id, "credential_cleanup_wrong_run")
    path.unlink()


def remove_workspace(container, run_id):
    relative = Path("Library/Caches/MoMoAgentUITests") / run_id
    if not (container / relative).exists() and not (container / relative).is_symlink():
        return
    shutil.rmtree(safe_path(container, relative, regular=False))


def summary_evidence(summary):
    require(summary.get("totalTestCount") == 1 and summary.get("passedTests") == 1
            and summary.get("failedTests") == 0 and summary.get("skippedTests") == 0, "ui_test_not_passed")
    return {name: summary[name] for name in ("totalTestCount", "passedTests", "failedTests", "skippedTests")}


def interrupt_requested(_number, _frame):
    raise KeyboardInterrupt


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--credential-env-file", type=Path)
    parser.add_argument("--model", required=True)
    parser.add_argument("--simulator", required=True)
    parser.add_argument("--network-route", choices=["system", "direct"], default="system")
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--derived-data", type=Path, default=Path("DerivedData"))
    parser.add_argument("--xctestrun", type=Path)
    args = parser.parse_args(argv)
    root = Path(__file__).resolve().parents[2]
    output = args.output.resolve()
    run_id = str(uuid.uuid4()).upper()
    manifest = dict(runID=run_id, model=args.model, provider=PROVIDER_URL,
                    networkRoute=args.network_route, simulator=args.simulator, test=TEST_NAME,
                    executed=False, accepted=False, errorCodes=[], credentialFileRemoved=False,
                    hostStopped=False, isolatedWorkspaceRemoved=False)
    try:
        output.mkdir(mode=0o700, parents=True, exist_ok=False)
    except OSError:
        print(json.dumps(dict(accepted=False, executed=False, errorCodes=["output_unavailable"])))
        return 1
    key, containers, installed, staged = "", set(), False, False
    owned_credentials = {}
    current_container, diagnostics_written = None, False
    temporary_plan = output / "ui-run.xctestrun"
    prior_signals = {number: signal.getsignal(number) for number in (signal.SIGTERM, signal.SIGINT)}
    signal.signal(signal.SIGTERM, interrupt_requested)
    try:
        key = read_key(args.credential_env_file)
        require(0 < len(args.model) <= 256 and not any(c.isspace() for c in args.model), "model_invalid")
        require(str(uuid.UUID(args.simulator)).upper() == args.simulator.upper(), "simulator_invalid")
        derived = (root / args.derived_data).resolve()
        products = derived / "Build/Products"
        app = products / "Debug-iphonesimulator/MoMoAgent.app"
        require(app.is_dir(), "debug_build_missing")
        candidates = [args.xctestrun] if args.xctestrun else sorted(products.glob("MoMoAgent_iphonesimulator*.xctestrun"))
        require(candidates, "xctestrun_missing")
        # A caller can select the build explicitly; otherwise prefer the newest generated test plan.
        selected = max(candidates, key=lambda path: path.stat().st_mtime_ns)
        prepare_xctestrun(selected, products, temporary_plan, run_id)
        require(key.encode() not in temporary_plan.read_bytes(), "credential_in_test_plan")
        environment = {name: value for name, value in os.environ.items()
                       if key not in value and not name.endswith("API_KEY")}
        command_output(["xcrun", "simctl", "install", args.simulator, str(app)], "install_failed", environment)
        installed = True
        stop_host(args.simulator)
        container = app_container(args.simulator)
        current_container = container
        containers.add(container)
        temporary = safe_path(container, "tmp", regular=False)
        require(not os.path.lexists(temporary / CREDENTIAL_NAME), "credentials_already_staged")
        owned_credentials[container] = write_credentials(temporary / CREDENTIAL_NAME, key, args.model, run_id, args.network_route)
        staged = True
        command = ["xcodebuild", "test-without-building", "-xctestrun", str(temporary_plan),
                   "-destination", f"platform=iOS Simulator,id={args.simulator}",
                   "-only-testing:" + TEST_NAME, "-parallel-testing-enabled", "NO",
                   "-collect-test-diagnostics", "never", "-test-timeouts-enabled", "YES",
                   "-default-test-execution-time-allowance", "480", "-maximum-test-execution-time-allowance", "540",
                   "-resultBundlePath", str(output / "tests.xcresult")]
        manifest["executed"] = True
        manifest["exitCode"] = run_test(command, environment, output / "xcodebuild.log", key, root)
        stop_host(args.simulator)
        manifest["hostStopped"] = True
        current = app_container(args.simulator)
        current_container = current
        containers.add(current)
        workspace = safe_path(current, Path("Library/Caches/MoMoAgentUITests") / run_id, regular=False)
        write_json(output / "diagnostics.json", collect_diagnostics(workspace, run_id), key)
        diagnostics_written = True
        evidence = collect_evidence(workspace, run_id, args.model, args.network_route)
        write_json(output / "evidence.json", evidence, key)
        summary = decode(command_output(["xcrun", "xcresulttool", "get", "test-results", "summary",
                                         "--path", str(output / "tests.xcresult")], "test_summary_unavailable", environment))
        manifest["summary"] = summary_evidence(summary)
        require(manifest["exitCode"] == 0, "xcodebuild_failed")
        manifest["accepted"] = True
    except Failure as error:
        manifest["errorCodes"].append(str(error))
    except KeyboardInterrupt:
        manifest["errorCodes"].append("interrupted")
    except subprocess.TimeoutExpired:
        manifest["errorCodes"].append("command_timeout")
    except Exception:
        manifest["errorCodes"].append("runner_or_evidence_invalid")
    finally:
        # TERM/INT request cleanup once. SIGKILL cannot be handled by any process.
        for number in prior_signals:
            signal.signal(number, signal.SIG_IGN)
        # Keep each cleanup step independent so one failure cannot retain the credential unnecessarily.
        if installed:
            try:
                stop_host(args.simulator)
                manifest["hostStopped"] = True
            except (Exception, KeyboardInterrupt):
                manifest["hostStopped"] = False
                manifest["errorCodes"].append("host_cleanup_failed")
            try:
                current_container = app_container(args.simulator)
                containers.add(current_container)
            except (Exception, KeyboardInterrupt):
                manifest["errorCodes"].append("current_container_cleanup_unavailable")
        if manifest["executed"] and manifest["hostStopped"] and current_container is not None and not diagnostics_written:
            try:
                workspace = safe_path(current_container, Path("Library/Caches/MoMoAgentUITests") / run_id, regular=False)
                diagnostics = collect_diagnostics(workspace, run_id)
                write_json(output / "diagnostics.json", diagnostics, key)
            except (Exception, KeyboardInterrupt):
                manifest["errorCodes"].append("diagnostic_cleanup_failed")
        if staged:
            for container in containers:
                try:
                    remove_credential(container, run_id, owned_credentials.get(container))
                except (Exception, KeyboardInterrupt):
                    manifest["errorCodes"].append("credential_cleanup_failed")
            manifest["credentialFileRemoved"] = bool(containers) and all(
                not os.path.lexists(container / "tmp" / CREDENTIAL_NAME) for container in containers)
            if manifest["hostStopped"]:
                for container in containers:
                    try:
                        remove_workspace(container, run_id)
                    except (Exception, KeyboardInterrupt):
                        manifest["errorCodes"].append("workspace_cleanup_failed")
                manifest["isolatedWorkspaceRemoved"] = all(not os.path.lexists(
                    container / "Library/Caches/MoMoAgentUITests" / run_id) for container in containers)
        try:
            temporary_plan.unlink(missing_ok=True)
        except OSError:
            manifest["errorCodes"].append("test_plan_cleanup_failed")
        for number, previous in prior_signals.items():
            signal.signal(number, previous)
    manifest["accepted"] = (manifest["accepted"] and not manifest["errorCodes"]
                            and manifest["credentialFileRemoved"] and manifest["hostStopped"]
                            and manifest["isolatedWorkspaceRemoved"])
    manifest["status"] = "passed" if manifest["accepted"] else ("failed" if manifest["executed"] else "not_executed")
    try:
        write_json(output / "run.json", manifest, key)
    except OSError:
        manifest.update(accepted=False, status="failed")
        manifest["errorCodes"].append("run_manifest_write_failed")
    print(redact(json.dumps(manifest), key))
    return 0 if manifest["accepted"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
