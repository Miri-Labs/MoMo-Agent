"""Synthetic OpenAI SSE faults over real loopback HTTPS; never log requests."""

from __future__ import annotations

import json
import base64
import hashlib
import math
import socket
import ssl
import threading
import time
import uuid
from dataclasses import dataclass, field
from datetime import datetime, timedelta, timezone
from email.utils import format_datetime
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path


SYNTHETIC_KEY = "momo-j17-synthetic-only"
SCENARIOS = (
    "success", "success-tools", "auth-401", "auth-403",
    "retry-429-seconds", "retry-429-date", "retry-429-ms", "retry-429-over-budget",
    "retry-500", "retry-503", "always-500", "always-503", "headers-delay",
    "body-delay", "stream-stall", "continuous-drip", "disconnect-midstream",
    "fragmented-text", "fragmented-tool-json", "late-tool-after-cancel",
    "privacy-success", "privacy-late-tool-after-cancel",
    "controlled-long-stream",
    "summary-success", "summary-503",
)
SUMMARY_MODEL = "j17-summary-selected"
SUMMARY_TEXTS = {
    "v1": "MOMO_SUMMARY_V1_9F21 今天讨论了录音档案的整理安排，先核对已有文字，再检查来源原音，负责人仍待确认。",
    "v2": "MOMO_SUMMARY_V2_7A35 更新后的安排是先检查来源原音，再核对已有文字，负责人已经确认由小林负责。",
}
SUMMARY_RESPONSES = {"v1": "合成总结一：先核对文字，再检查原音，负责人待确认。",
                     "v2": "合成总结二：先检查原音，再核对文字，负责人为小林。"}
SUMMARY_UNRELATED = "MOMO_SUMMARY_UNRELATED_602D"
PRIVACY_MARKERS = {
    "currentV1": "MOMO_J25_ALLOWED_V1_104BF6", "currentV2": "MOMO_J25_ALLOWED_V2_C5D108",
    "unrelated": "MOMO_J25_UNRELATED_849E20", "audio": "MOMO_J25_AUDIO_ONLY_86CFA6",
    "credential": SYNTHETIC_KEY,
}
DEFAULT_TIMING = {
    "delaySeconds": 90.0, "dripIntervalSeconds": 1.0, "dripDurationSeconds": 150.0,
    "fragmentIntervalSeconds": 0.003, "retryAfterSeconds": 1,
    "retryAfterMilliseconds": 1000, "overBudgetSeconds": 86400,
}
DEFAULT_TOOL_ARGUMENTS = {"query": "合成验证"}
MAX_BODY = 2 * 1024 * 1024


def configuration(path: Path | None = None) -> dict:
    value = json.loads(path.read_text()) if path else {}
    if not isinstance(value, dict) or value.keys() - {"timing", "toolArguments"}:
        raise ValueError("invalid_config_fields")
    timing = dict(DEFAULT_TIMING)
    overrides = value.get("timing", {})
    if not isinstance(overrides, dict) or overrides.keys() - timing.keys():
        raise ValueError("invalid_timing_fields")
    for name, number in overrides.items():
        if type(number) not in (int, float) or not math.isfinite(number) or number <= 0 or number > 86400:
            raise ValueError("invalid_timing_value")
        if name in ("retryAfterSeconds", "retryAfterMilliseconds", "overBudgetSeconds") and type(number) is not int:
            raise ValueError("integer_retry_required")
        timing[name] = number
    if timing["dripDurationSeconds"] > 600 or timing["delaySeconds"] > 600:
        raise ValueError("fixture_duration_limit")
    arguments = value.get("toolArguments", DEFAULT_TOOL_ARGUMENTS)
    if not isinstance(arguments, dict) or set(arguments) != {"query"}:
        raise ValueError("invalid_tool_fields")
    if not isinstance(arguments["query"], str) or not arguments["query"]:
        raise ValueError("invalid_tool_values")
    if len(json.dumps(arguments).encode()) > 65536:
        raise ValueError("tool_size_limit")
    return {"timing": timing, "toolArguments": arguments}



@dataclass
class CaseState:
    requests: int = 0
    events: list = field(default_factory=list)
    release: threading.Event = field(default_factory=threading.Event)
    disconnect: threading.Event = field(default_factory=threading.Event)
    inspections: list = field(default_factory=list)


def inspect_summary(body: dict, raw: bytes, request: int, path: str, authority_matches: bool,
                    content_type_matches: bool) -> dict:
    """Closed synthetic corpus only. Persist hashes/booleans, never arbitrary prompt or key text."""
    messages = body["messages"]
    def content(message):
        value = message.get("content") if isinstance(message, dict) else None
        if isinstance(value, str):
            return value
        if isinstance(value, list) and all(isinstance(part, dict) and part.get("type") == "text"
                                         and isinstance(part.get("text"), str) for part in value):
            return "\n".join(part["text"] for part in value)
        return None
    texts = [content(message) for message in messages]
    roles = [message.get("role") if isinstance(message, dict) else None for message in messages]
    users = [text for role, text in zip(roles, texts) if role == "user"]
    user = users[0] if len(users) == 1 and users[0] is not None else ""
    revision = next((name for name, text in SUMMARY_TEXTS.items() if user == text), "unexpected")
    encoded = raw.decode("utf-8")
    return {"request": request, "path": path, "authorityMatches": authority_matches,
            "contentTypeMatches": content_type_matches, "authorizationMatches": True,
            "modelMatches": body.get("model") == SUMMARY_MODEL, "stream": body.get("stream") is True,
            "messageCount": len(messages), "systemThenSingleUser": roles == ["system", "user"],
            "textOnlyMessages": all(text is not None for text in texts)
                and all("audio" not in message and "tool_calls" not in message for message in messages if isinstance(message, dict)),
            "hasTools": bool(body.get("tools") or body.get("functions")),
            "userTextSHA256": hashlib.sha256(user.encode()).hexdigest(), "fixtureRevision": revision,
            "bodyBytes": len(raw), "containsUnrelatedText": SUMMARY_UNRELATED in encoded,
            "containsCredential": SYNTHETIC_KEY in encoded}


def inspect_outbound(body: dict, raw: bytes, request: int, path: str, authority_matches: bool,
                     content_type_matches: bool) -> dict:
    """Inspect encoded synthetic requests in memory; export no arbitrary body, header or text fields."""
    messages = body["messages"]

    def text(message):
        content = message.get("content") if isinstance(message, dict) else None
        if isinstance(content, str):
            return content
        if isinstance(content, list):
            return "\n".join(part["text"] for part in content
                             if isinstance(part, dict) and part.get("type") == "text" and isinstance(part.get("text"), str))
        return ""

    def text_only(message):
        if not isinstance(message, dict) or "audio" in message:
            return False
        content = message.get("content")
        return isinstance(content, str) or (isinstance(content, list) and all(
            isinstance(part, dict) and part.get("type") == "text" and isinstance(part.get("text"), str)
            for part in content))

    system = "\n".join(text(message) for message in messages if isinstance(message, dict) and message.get("role") == "system")
    combined = "\n".join(text(message) for message in messages)
    encoded = raw.decode("utf-8")
    sources = []
    context_valid = False
    opening, closing = "<recent_life_context>\n", "\n</recent_life_context>"
    try:
        start = system.index(opening) + len(opening)
        context = json.loads(system[start:system.index(closing, start)])
        for passage in context["passages"]:
            source = passage["source"]
            version = source["transcriptVersion"]
            if type(version) is not int or version <= 0 or not isinstance(source["sessionID"], str):
                raise ValueError("invalid_version")
            sources.append({"sessionID": str(uuid.UUID(source["sessionID"])), "transcriptVersion": version})
        context_valid = True
    except (ValueError, KeyError, TypeError):
        sources = []
    # Ignore edge base64 quanta, whose bits depend on surrounding bytes in a whole encoded audio container.
    encoded_markers = {name: any(base64.b64encode(b"\0" * offset + marker.encode()).decode()[4:-4] in encoded
                                for offset in range(3)) for name, marker in PRIVACY_MARKERS.items()}
    return {"request": request, "path": path, "authorityMatches": authority_matches,
            "contentTypeMatches": content_type_matches, "authorizationMatches": True,
            "modelMatches": body.get("model") == "j17-synthetic", "stream": body.get("stream") is True,
            "bodyBytes": len(raw), "messageCount": len(messages),
            "textOnlyMessages": all(text_only(message) for message in messages),
            "hasProductionRules": "<momoagent_rules>" in system,
            "hasContextEnvelope": "<recent_life_context>" in system,
            "contextValid": context_valid, "passageSources": sources,
            "bodyMarkers": {name: marker in encoded for name, marker in PRIVACY_MARKERS.items()},
            "messageMarkers": {name: marker in combined for name, marker in PRIVACY_MARKERS.items()},
            "systemMarkers": {name: marker in system for name, marker in PRIVACY_MARKERS.items()},
            "base64Markers": encoded_markers}


class FaultServer(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = False

    def __init__(self, port: int, certificate: Path, private_key: Path, output: Path, config: dict):
        self.config = config
        self.output = output
        self.cases: dict[tuple[str, str], CaseState] = {}
        self.lock = threading.Lock()
        self.stopping = threading.Event()
        super().__init__(("127.0.0.1", port), FaultHandler)
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.minimum_version = ssl.TLSVersion.TLSv1_2
        context.load_cert_chain(certificate, private_key)
        self.socket = context.wrap_socket(self.socket, server_side=True)

    def get_request(self):
        connection, address = super().get_request()
        connection.settimeout(10)
        return connection, address

    def handle_error(self, request, client_address):
        # Base implementation prints a traceback, which can contain request data.
        self.event(None, None, 0, "handler_error")

    def case(self, run_id: str, scenario: str) -> CaseState:
        with self.lock:
            return self.cases.setdefault((run_id, scenario), CaseState())

    def begin(self, run_id: str, scenario: str) -> int:
        with self.lock:
            state = self.cases.setdefault((run_id, scenario), CaseState())
            state.requests += 1
            return state.requests

    def event(self, run_id: str | None, scenario: str | None, request: int, event: str,
              status: int | None = None, byte_count: int = 0):
        record = {"runID": run_id, "scenario": scenario, "request": request,
                  "event": event, "monotonicSeconds": time.monotonic(),
                  "status": status, "byteCount": byte_count}
        with self.lock:
            if run_id is not None:
                self.cases[(run_id, scenario)].events.append(record)
            with (self.output / "events.jsonl").open("a", encoding="utf-8") as stream:
                stream.write(json.dumps(record, separators=(",", ":")) + "\n")

    def snapshot(self, run_id: str, scenario: str) -> dict:
        self.case(run_id, scenario)
        with self.lock:
            state = self.cases[(run_id, scenario)]
            events = list(state.events)
            return {"runID": run_id, "scenario": scenario, "requests": state.requests,
                    "snapshotMonotonicSeconds": time.monotonic(),
                    "responseBodyBytes": sum(e["byteCount"] for e in events if e["event"] == "body_sent"),
                    "statuses": [e["status"] for e in events if e["event"] == "headers_sent"],
                    "events": events}

    def inspect_request(self, run_id: str, scenario: str, observation: dict):
        with self.lock:
            self.cases[(run_id, scenario)].inspections.append(observation)

    def inspection_snapshot(self, run_id: str, scenario: str) -> dict:
        self.case(run_id, scenario)
        with self.lock:
            return {"runID": run_id, "scenario": scenario,
                    "requests": list(self.cases[(run_id, scenario)].inspections)}

    def pause(self, seconds: float):
        if self.stopping.wait(seconds):
            raise ConnectionAbortedError()


class FaultHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server: FaultServer

    def log_message(self, format, *args):
        pass

    def send_error(self, code, message=None, explain=None):
        # Do not reflect malformed request lines, URLs, or authorization.
        self.send_response(code)
        self.send_header("Content-Length", "0")
        self.send_header("Connection", "close")
        self.end_headers()
        self.close_connection = True

    def route(self) -> tuple[str, str, str] | None:
        parts = self.path.split("/")
        if len(parts) not in (5, 7) or parts[1] != "runs" or parts[3] not in SCENARIOS:
            self.send_error(404)
            return None
        try:
            run_id = str(uuid.UUID(parts[2]))
        except ValueError:
            self.send_error(404)
            return None
        if run_id != parts[2].lower():
            self.send_error(404)
            return None
        endpoint = "/".join(parts[4:])
        if endpoint not in ("counts", "inspection", "release", "disconnect", "v1/chat/completions"):
            self.send_error(404)
            return None
        return run_id, parts[3], endpoint

    def do_GET(self):
        route = self.route()
        if route is None:
            return
        run_id, scenario, endpoint = route
        if endpoint not in ("counts", "inspection"):
            self.send_error(405)
            return
        if endpoint == "inspection" and not scenario.startswith(("privacy-", "summary-")):
            self.send_error(404)
            return
        snapshot = self.server.inspection_snapshot if endpoint == "inspection" else self.server.snapshot
        encoded = json.dumps(snapshot(run_id, scenario)).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(encoded)))
        self.end_headers()
        self.wfile.write(encoded)

    def do_POST(self):
        route = self.route()
        if route is None:
            return
        self.run_id, self.scenario, endpoint = route
        if self.headers.get("Authorization") != "Bearer " + SYNTHETIC_KEY:
            self.send_error(401)
            return
        if endpoint in ("release", "disconnect"):
            if endpoint == "disconnect" and self.scenario != "controlled-long-stream":
                self.send_error(405)
                return
            state = self.server.case(self.run_id, self.scenario)
            getattr(state, endpoint).set()
            self.server.event(self.run_id, self.scenario, 0, endpoint + "_requested")
            self.send_error(204)
            return
        if endpoint != "v1/chat/completions":
            self.send_error(405)
            return
        self.request_number = self.server.begin(self.run_id, self.scenario)
        self.record("request_received")
        try:
            if self.headers.get("Transfer-Encoding") is not None:
                self.send_error(400)
                return
            length = int(self.headers.get("Content-Length", "0"))
            if length <= 0 or length > MAX_BODY:
                self.send_error(413)
                return
            raw = self.rfile.read(length)
            body = json.loads(raw)
            if not isinstance(body, dict) or body.get("stream") is not True or not isinstance(body.get("messages"), list):
                self.send_error(400)
                return
            # Validate protocol in memory. Never persist model, messages, tools or headers.
            if self.scenario.startswith("privacy-"):
                observation = inspect_outbound(body, raw, self.request_number, self.path,
                    self.headers.get("Host") == f"127.0.0.1:{self.server.server_address[1]}",
                    self.headers.get_content_type() == "application/json")
                self.server.inspect_request(self.run_id, self.scenario, observation)
            if self.scenario.startswith("summary-"):
                observation = inspect_summary(body, raw, self.request_number, self.path,
                    self.headers.get("Host") == f"127.0.0.1:{self.server.server_address[1]}",
                    self.headers.get_content_type() == "application/json")
                self.server.inspect_request(self.run_id, self.scenario, observation)
            self.script(body)
        except (ValueError, UnicodeError):
            self.record("invalid_request")
            self.send_error(400)
        except (BrokenPipeError, ConnectionError, TimeoutError, ssl.SSLError):
            self.record("connection_closed")
        finally:
            self.close_connection = True
            self.record("request_finished")

    def record(self, event: str, status: int | None = None, byte_count: int = 0):
        self.server.event(self.run_id, self.scenario, self.request_number, event, status, byte_count)

    def respond_headers(self, status: int, extra: dict, length: int | None = None):
        self.send_response(status)
        self.send_header("Content-Type", "text/event-stream" if status == 200 else "application/json")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Connection", "close")
        self.send_header("Transfer-Encoding", "chunked") if length is None else self.send_header("Content-Length", str(length))
        for key, value in extra.items():
            self.send_header(key, value)
        self.end_headers()
        self.wfile.flush()
        self.record("headers_sent", status=status)

    def send_bytes(self, data: bytes):
        self.wfile.write(f"{len(data):x}\r\n".encode() + data + b"\r\n")
        self.wfile.flush()
        self.record("body_sent", byte_count=len(data))

    def delta(self, delta: dict, finish: str | None = None) -> bytes:
        value = {"id": "chatcmpl-j17", "object": "chat.completion.chunk", "created": 1,
                 "model": SUMMARY_MODEL if self.scenario.startswith("summary-") else "j17-synthetic",
                 "choices": [{"index": 0, "delta": delta, "finish_reason": finish}]}
        return ("data: " + json.dumps(value, ensure_ascii=False, separators=(",", ":")) + "\n\n").encode()

    def finish_stream(self):
        self.send_bytes(b"data: [DONE]\n\n")
        self.wfile.write(b"0\r\n\r\n")
        self.wfile.flush()
        self.record("stream_complete")

    def fragments(self, data: bytes):
        # One-byte transport chunks split UTF-8 scalars and SSE delimiters deliberately.
        for index in range(len(data)):
            self.send_bytes(data[index:index + 1])
            self.server.pause(self.server.config["timing"]["fragmentIntervalSeconds"])

    def tool(self, fragmented: bool = False, late: bool = False):
        arguments = json.dumps(self.server.config["toolArguments"], ensure_ascii=False, separators=(",", ":"))
        call = {"index": 0, "id": "call_j17_search", "type": "function", "function": {"name": "search_transcripts", "arguments": ""}}
        self.send_bytes(self.delta({"role": "assistant", "tool_calls": [call]}))
        midpoint = max(1, len(arguments) // 2)
        for index, part in enumerate((arguments[:midpoint], arguments[midpoint:])):
            if index == 1 and late:
                self.record("awaiting_release")
                deadline = time.monotonic() + self.server.config["timing"]["delaySeconds"]
                released = self.server.case(self.run_id, self.scenario).release
                while not released.wait(0.05):
                    if self.server.stopping.is_set() or time.monotonic() >= deadline:
                        self.record("release_timeout")
                        return
                self.record("late_tool_attempted")
            chunk = self.delta({"tool_calls": [{"index": 0, "function": {"arguments": part}}]})
            (self.fragments if fragmented else self.send_bytes)(chunk)
        self.send_bytes(self.delta({}, "tool_calls"))
        self.finish_stream()

    def script(self, body: dict):
        scenario = self.scenario
        timing = self.server.config["timing"]
        status = None
        extra = {}
        if scenario == "summary-503":
            status = 503
        elif scenario in ("auth-401", "auth-403"):
            status = int(scenario[-3:])
            extra["x-should-retry"] = "true"
        elif scenario.startswith("always-") or (scenario.startswith("retry-") and self.request_number == 1):
            status = int(scenario.split("-")[1])
            if status == 429:
                if scenario == "retry-429-ms":
                    extra["retry-after-ms"] = str(timing["retryAfterMilliseconds"])
                elif scenario == "retry-429-date":
                    extra["Retry-After"] = format_datetime(datetime.now(timezone.utc) + timedelta(seconds=timing["retryAfterSeconds"]), usegmt=True)
                else:
                    extra["Retry-After"] = str(timing["overBudgetSeconds"] if scenario.endswith("over-budget") else timing["retryAfterSeconds"])
        if status:
            data = b'{"error":{"message":"Synthetic J17 failure","type":"fixture_error","code":"j17_fault"}}'
            self.respond_headers(status, extra, len(data))
            self.wfile.write(data)
            self.wfile.flush()
            self.record("body_sent", byte_count=len(data))
            return
        if scenario == "headers-delay":
            self.record("headers_wait_started")
            self.server.pause(timing["delaySeconds"])
        self.respond_headers(200, {})
        if scenario == "body-delay":
            self.record("body_wait_started")
            self.server.pause(timing["delaySeconds"])
        if scenario in ("success-tools", "fragmented-tool-json", "late-tool-after-cancel", "privacy-late-tool-after-cancel"):
            has_result = any(isinstance(message, dict) and message.get("role") == "tool" and
                             message.get("tool_call_id") == "call_j17_search" for message in body["messages"])
            if not has_result:
                self.tool(fragmented=scenario == "fragmented-tool-json", late=scenario.endswith("late-tool-after-cancel"))
                return
        self.send_bytes(self.delta({"role": "assistant"}))
        if scenario == "controlled-long-stream":
            # A per-run socket failure, never a host-wide network or proxy change.
            state = self.server.case(self.run_id, self.scenario)
            self.send_bytes(self.delta({"content": "合成并发流"}))
            self.record("controlled_stream_started")
            deadline = time.monotonic() + timing["dripDurationSeconds"]
            while time.monotonic() < deadline and not self.server.stopping.is_set():
                if state.disconnect.wait(timing["dripIntervalSeconds"]):
                    self.record("forced_disconnect")
                    self.connection.shutdown(socket.SHUT_RDWR)
                    return
                self.send_bytes(self.delta({"content": "点"}))
            self.record("controlled_stream_expired")
            return
        if scenario == "stream-stall":
            self.send_bytes(self.delta({"content": "合成"}))
            self.record("stream_wait_started")
            self.server.pause(timing["delaySeconds"])
        if scenario == "continuous-drip":
            deadline = time.monotonic() + timing["dripDurationSeconds"]
            while time.monotonic() < deadline:
                self.send_bytes(self.delta({"content": "点"}))
                self.server.pause(timing["dripIntervalSeconds"])
        if scenario == "disconnect-midstream":
            self.send_bytes(b'data: {"choices":[{"delta":{"content":"partial')
            self.record("forced_disconnect")
            self.connection.shutdown(socket.SHUT_RDWR)
            return
        if scenario == "summary-success":
            observation = inspect_summary(body, b"{}", self.request_number, self.path, True, True)
            text = SUMMARY_RESPONSES.get(observation["fixtureRevision"], "合成服务拒绝了非预期的总结输入。")
        else:
            text = "合成响应：计划已保存。"
        payload = self.delta({"content": text})
        (self.fragments if scenario == "fragmented-text" else self.send_bytes)(payload)
        self.send_bytes(self.delta({}, "stop"))
        self.finish_stream()
