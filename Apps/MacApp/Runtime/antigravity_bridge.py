"""Official Antigravity CLI (`agy`) subscription adapter, persistent ACP daemon, and stateful session bridge."""
from __future__ import annotations

import asyncio
import atexit
from collections import deque
import contextlib
from dataclasses import dataclass, field
import hashlib
import json
import logging
import os
from pathlib import Path
import pty
import re
import select
import shutil
import signal
import subprocess
import tempfile
import threading
import time
from typing import Callable
from urllib.parse import urlsplit
import uuid

log = logging.getLogger("momo.antigravity")

_AGY_TOTAL_SEM = threading.BoundedSemaphore(4)
_AGY_BACKGROUND_SEM = threading.BoundedSemaphore(1)

MAX_PROMPT_UTF8_BYTES = 140_000
MAX_SESSION_ACCUMULATED_BYTES = 280_000
MAX_WARM_SESSIONS = 24
SESSION_IDLE_TTL_SECONDS = 900.0
MODEL_CACHE_TTL_SECONDS = 600.0

ANSI_ESCAPE_RE = re.compile(r"\x1b\[[0-9;?]*[A-Za-z]|\x1b\][^\x07]*\x07|\r")
MODEL_LINE_RE = re.compile(r"^\s*([a-z0-9][a-z0-9._-]+)(?:\t+|\s{2,})(.+?)\s*$")
URL_RE = re.compile(r"https://[^\s\x1b<>\"']+")
CODE_FENCE_RE = re.compile(r"^\s*```(?:json)?\s*(.*?)\s*```\s*$", re.DOTALL | re.IGNORECASE)

DEFAULT_ANTIGRAVITY_MODELS: list[str] = [
    "gemini-4-carbon-high",
    "gemini-4-carbon-medium",
    "gemini-4-argon-high",
    "gemini-4-argon-medium",
    "claude-opus-5-5-high",
    "claude-sonnet-5-5-high",
    "claude-sonnet-5-5-medium",
    "gemini-3.8-flash-high",
    "gemini-3.8-flash-medium",
]

PREFERRED_MODEL_ORDER: tuple[str, ...] = (
    "gemini-4-carbon-high",
    "claude-opus-5-5-high",
    "claude-sonnet-5-5-high",
    "gemini-4-carbon-medium",
    "gemini-4-argon-high",
    "claude-sonnet-5-5-medium",
    "gemini-3.8-flash-high",
    "gemini-3.8-flash-medium",
)

TOOL_ENVELOPE_SCHEMA: dict = {
    "type": "object",
    "properties": {
        "content": {"type": "string"},
        "tool_calls": {
            "type": "array",
            "items": {
                "type": "object",
                "properties": {
                    "name": {"type": "string"},
                    "arguments_json": {"type": "string"},
                },
                "required": ["name", "arguments_json"],
            },
        },
    },
    "required": ["content", "tool_calls"],
}

_MODEL_CACHE_LOCK = threading.Lock()
_MODEL_CACHE: dict[str, tuple[float, bool, list[str]]] = {}


def clear_antigravity_caches() -> None:
    """Clear in-memory model catalog caches (used on auth change or tests)."""
    with _MODEL_CACHE_LOCK:
        _MODEL_CACHE.clear()


def _cache_models(cli: str, connected: bool, models: list[str]) -> None:
    with _MODEL_CACHE_LOCK:
        _MODEL_CACHE[cli] = (time.monotonic(), connected, list(models))


def _read_cached_models(cli: str, ttl: float = MODEL_CACHE_TTL_SECONDS) -> tuple[bool, list[str]] | None:
    with _MODEL_CACHE_LOCK:
        entry = _MODEL_CACHE.get(cli)
        if entry is None:
            return None
        checked_at, connected, models = entry
        if time.monotonic() - checked_at > ttl:
            _MODEL_CACHE.pop(cli, None)
            return None
        return connected, list(models)


def find_antigravity_cli(name: str = "agy") -> str | None:
    """Locate the official Antigravity CLI (`agy`) binary on this Mac."""
    override = os.environ.get("MOMO_ANTIGRAVITY_CLI", "").strip()
    if override:
        candidate = Path(override).expanduser()
        if candidate.is_file() and os.access(candidate, os.X_OK):
            return str(candidate)

    found = shutil.which(name)
    if found and os.access(found, os.X_OK):
        return found

    home = Path.home()
    candidates = (
        home / ".local/bin" / name,
        home / ".gemini/antigravity-cli/bin" / name,
        Path("/opt/homebrew/bin") / name,
        Path("/usr/local/bin") / name,
    )
    for path in candidates:
        if path.is_file() and os.access(path, os.X_OK):
            return str(path)
    return None


def is_antigravity_authorization_url(value: str) -> bool:
    """Validate that a login URL is an official Google OAuth endpoint."""
    try:
        url = urlsplit(value)
    except ValueError:
        return False
    if url.scheme != "https" or url.username or url.password or url.port not in {None, 443}:
        return False
    if url.hostname != "accounts.google.com":
        return False
    return url.path.startswith(("/o/oauth2", "/signin", "/v3/signin"))


def _empty_sandbox_dir(base_dir: Path | None = None) -> Path:
    if base_dir is not None:
        folder = Path(base_dir) / "superagent/antigravity-sandbox"
    else:
        folder = Path(tempfile.gettempdir()) / f"momo-antigravity-sandbox-{os.getuid()}"
    folder.mkdir(parents=True, exist_ok=True, mode=0o700)
    return folder


def _agy_env() -> dict[str, str]:
    env = dict(os.environ)
    local_bin = str(Path.home() / ".local/bin")
    agy_bin = str(Path.home() / ".gemini/antigravity-cli/bin")
    existing_path = env.get("PATH", "/usr/bin:/bin")
    parts = [p for p in (local_bin, agy_bin, "/opt/homebrew/bin", "/usr/local/bin") if p not in existing_path.split(":")]
    if parts:
        env["PATH"] = ":".join([*parts, existing_path])
    env["NO_COLOR"] = "1"
    return env


def _order_model_ids(discovered: list[str]) -> list[str]:
    seen: set[str] = set()
    unique: list[str] = []
    for mid in discovered:
        m = str(mid or "").strip()
        if m and m not in {"id", "model", "models", "available"} and m not in seen:
            seen.add(m)
            unique.append(m)
    if not unique:
        return []
    preferred = [m for m in PREFERRED_MODEL_ORDER if m in seen]
    rest = [m for m in unique if m not in set(preferred)]
    return [*preferred, *rest]


def parse_antigravity_models_output(raw_output: str) -> list[str]:
    """Parse `agy models` stdout into ordered model IDs."""
    cleaned = ANSI_ESCAPE_RE.sub("", raw_output or "")
    discovered: list[str] = []
    for raw_line in cleaned.splitlines():
        match = MODEL_LINE_RE.match(raw_line)
        if not match:
            continue
        discovered.append(match.group(1).strip())
    return _order_model_ids(discovered)


def _is_mocked_subprocess() -> bool:
    return hasattr(subprocess.run, "_mock_name") or type(subprocess.run).__module__.startswith("unittest.mock")


def list_antigravity_models(
    cli_path: str | None = None,
    *,
    timeout: float = 15.0,
    force_refresh: bool = False,
) -> tuple[bool, list[str]]:
    """Return `(connected, models)` using cached catalog or live ACP daemon before falling back to `agy models`."""
    cli = cli_path or find_antigravity_cli()
    if not cli:
        return False, list(DEFAULT_ANTIGRAVITY_MODELS)

    mocked = _is_mocked_subprocess()
    if not force_refresh and not mocked:
        cached = _read_cached_models(cli)
        if cached is not None:
            return cached

    if not mocked:
        daemon = _peek_live_acp_daemon(cli)
        if daemon is not None:
            with contextlib.suppress(Exception):
                models = daemon.discover_models(timeout=min(timeout, 10.0))
                if models:
                    _cache_models(cli, True, models)
                    return True, models

    try:
        proc = subprocess.run(
            [cli, "models"],
            cwd=str(_empty_sandbox_dir()),
            env=_agy_env(),
            stdin=subprocess.DEVNULL,
            capture_output=True,
            text=True,
            timeout=timeout,
            check=False,
        )
    except (OSError, subprocess.TimeoutExpired):
        return False, list(DEFAULT_ANTIGRAVITY_MODELS)
    models = parse_antigravity_models_output((proc.stdout or "") + "\n" + (proc.stderr or ""))
    if proc.returncode == 0 and models:
        if not mocked:
            # Cache positive status for 10 minutes so background workers never poll `agy models`.
            _cache_models(cli, True, models)
        return True, models
    if not mocked:
        # Short negative TTL (15s) avoids thundering herds while allowing login flows to observe completion quickly.
        with _MODEL_CACHE_LOCK:
            _MODEL_CACHE[cli] = (time.monotonic() - (MODEL_CACHE_TTL_SECONDS - 15.0), False, list(DEFAULT_ANTIGRAVITY_MODELS))
    return False, list(DEFAULT_ANTIGRAVITY_MODELS)


def login_antigravity(
    authorize=lambda **fields: None,
    *,
    timeout: float = 300.0,
) -> tuple[bool, list[str]]:
    """Drive official `agy` sign-in and surface only validated Google OAuth URLs."""
    cli = find_antigravity_cli()
    if not cli:
        raise RuntimeError("请先安装 Antigravity CLI (agy)，再使用 Antigravity 订阅登录。")

    connected, models = list_antigravity_models(cli, force_refresh=True)
    if connected:
        return True, models

    deadline = time.monotonic() + timeout
    master_fd, slave_fd = pty.openpty()
    child = subprocess.Popen(
        [cli],
        cwd=str(_empty_sandbox_dir()),
        env=_agy_env(),
        stdin=slave_fd,
        stdout=slave_fd,
        stderr=slave_fd,
        start_new_session=True,
        close_fds=True,
    )
    os.close(slave_fd)

    emitted_urls: set[str] = set()
    buffer = ""
    last_probe = 0.0
    sent_enter = False
    try:
        while time.monotonic() < deadline:
            ready, _, _ = select.select([master_fd], [], [], 0.5)
            if ready:
                try:
                    chunk = os.read(master_fd, 4096).decode("utf-8", errors="replace")
                except OSError:
                    chunk = ""
                if chunk:
                    buffer = (buffer + ANSI_ESCAPE_RE.sub("", chunk))[-16384:]
                    for candidate in URL_RE.findall(buffer):
                        trimmed = candidate.rstrip(".,;:)]}")
                        if trimmed not in emitted_urls and is_antigravity_authorization_url(trimmed):
                            emitted_urls.add(trimmed)
                            authorize(url=trimmed, expiresAt=time.time() + max(30.0, deadline - time.monotonic()))
                    if not sent_enter and ("sign in" in buffer.lower() or "login" in buffer.lower() or "authenticate" in buffer.lower()):
                        with contextlib.suppress(OSError):
                            os.write(master_fd, b"\r")
                        sent_enter = True

            now = time.monotonic()
            if now - last_probe >= 3.0:
                last_probe = now
                connected, models = list_antigravity_models(cli, timeout=8.0, force_refresh=True)
                if connected:
                    return True, models

            if child.poll() is not None:
                break

        connected, models = list_antigravity_models(cli, timeout=10.0, force_refresh=True)
        return connected, models
    finally:
        with contextlib.suppress(OSError):
            os.close(master_fd)
        if child.poll() is None:
            with contextlib.suppress(ProcessLookupError):
                os.killpg(child.pid, signal.SIGTERM)
            try:
                child.wait(timeout=1.5)
            except subprocess.TimeoutExpired:
                with contextlib.suppress(ProcessLookupError):
                    os.killpg(child.pid, signal.SIGKILL)
                with contextlib.suppress(Exception):
                    child.wait(timeout=1.0)


def _extract_content_text(content) -> str:
    if content is None:
        return ""
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        parts: list[str] = []
        for item in content:
            if isinstance(item, str):
                parts.append(item)
            elif isinstance(item, dict):
                btype = str(item.get("type") or "")
                if btype in {"text", "input_text", "output_text"}:
                    parts.append(str(item.get("text") or ""))
        return "\n".join(p for p in parts if p)
    return str(content)


def _normalize_openai_tools(tools: list[dict] | None) -> list[dict]:
    normalized: list[dict] = []
    for entry in tools or ():
        if not isinstance(entry, dict):
            continue
        fn = entry.get("function") if entry.get("type") == "function" else entry
        if not isinstance(fn, dict):
            continue
        name = str(fn.get("name") or "").strip()
        if not name:
            continue
        normalized.append(
            {
                "name": name,
                "description": str(fn.get("description") or "").strip(),
                "parameters": fn.get("parameters") if isinstance(fn.get("parameters"), dict) else {"type": "object", "properties": {}},
            }
        )
    return normalized


def _format_conversation_chunk(msg: dict) -> str:
    role = str(msg.get("role") or "user").lower()
    text = _extract_content_text(msg.get("content"))
    if role == "assistant":
        tcalls = msg.get("tool_calls") or []
        rendered_calls: list[dict] = []
        for tc in tcalls:
            if not isinstance(tc, dict):
                continue
            fn = tc.get("function") or {}
            rendered_calls.append(
                {
                    "id": tc.get("id") or "",
                    "name": fn.get("name") or tc.get("name") or "",
                    "arguments": fn.get("arguments") if "arguments" in fn else (tc.get("arguments") or "{}"),
                }
            )
        block = f"[ASSISTANT]: {text}" if text else "[ASSISTANT]:"
        if rendered_calls:
            block += "\n<assistant_tool_calls>\n" + json.dumps(rendered_calls, ensure_ascii=False) + "\n</assistant_tool_calls>"
        return block
    if role == "tool":
        tc_id = str(msg.get("tool_call_id") or "")
        tc_name = str(msg.get("name") or "")
        return f"[TOOL_RESULT name={tc_name!r} id={tc_id!r}]:\n{text}"
    return f"[USER]:\n{text}"


def _compact_conversation_chunks(convo_chunks: list[str], convo_budget: int) -> str:
    full_convo = "\n\n".join(convo_chunks)
    if len(full_convo.encode("utf-8")) > convo_budget and len(convo_chunks) > 2:
        # Preserve the initial user/task framing plus as many recent turns/tool results as fit in budget.
        head_chunks: list[str] = []
        head_budget = min(20_000, convo_budget // 4)
        used_head = 0
        for chunk in convo_chunks[:2]:
            encoded = chunk.encode("utf-8")
            if len(encoded) > head_budget - used_head:
                clipped = encoded[: max(1024, head_budget - used_head)].decode("utf-8", errors="ignore")
                head_chunks.append(clipped + "\n...[首轮超长内容已截断]...")
                used_head += len(head_chunks[-1].encode("utf-8"))
                break
            head_chunks.append(chunk)
            used_head += len(encoded)

        tail_budget = max(16_000, convo_budget - used_head - 256)
        tail_chunks_rev: list[str] = []
        used_tail = 0
        for chunk in reversed(convo_chunks[len(head_chunks) :]):
            encoded = chunk.encode("utf-8")
            if used_tail + len(encoded) > tail_budget:
                if not tail_chunks_rev:
                    # Page cursors and tool identity precede the potentially large span list.
                    half = (tail_budget - 128) // 2
                    start = encoded[:half].decode("utf-8", errors="ignore")
                    end = encoded[-half:].decode("utf-8", errors="ignore")
                    tail_chunks_rev.append(start + "\n...[工具结果中段已截断]...\n" + end)
                break
            tail_chunks_rev.append(chunk)
            used_tail += len(encoded) + 2
        tail_chunks = list(reversed(tail_chunks_rev))
        omitted = max(0, len(convo_chunks) - len(head_chunks) - len(tail_chunks))
        marker = f"[SYSTEM_NOTE: 中间 {omitted} 条历史工具步骤已自动折叠，请结合首轮任务目标与最近进展直接继续完成剩余闭环。]"
        return "\n\n".join([*head_chunks, marker, *tail_chunks])
    if len(full_convo.encode("utf-8")) > convo_budget:
        encoded = full_convo.encode("utf-8")
        half = convo_budget // 2
        head_s = encoded[:half].decode("utf-8", errors="ignore")
        tail_s = encoded[-half:].decode("utf-8", errors="ignore")
        return f"{head_s}\n\n...[中间较早上下文已自动压缩以适配 CLI 参数上限]...\n\n{tail_s}"
    return full_convo


def build_antigravity_prompt(
    messages: list[dict],
    *,
    tools: list[dict] | None = None,
    tool_choice=None,
) -> tuple[str, dict | None, set[str]]:
    """Build a deterministic single-turn `agy -p` prompt and optional `--json-schema`."""
    declared_tools = [] if tool_choice == "none" else _normalize_openai_tools(tools)
    declared_names = {t["name"] for t in declared_tools}

    forced_tool_name: str | None = None
    if isinstance(tool_choice, dict):
        fn = tool_choice.get("function")
        if isinstance(fn, dict) and fn.get("name"):
            forced_tool_name = str(fn["name"])
    require_tool = tool_choice == "required" or bool(forced_tool_name)

    sections: list[str] = [
        "You are operating strictly as a stateless chat-completions inference engine.",
        "CRITICAL RULE: NEVER invoke any CLI built-in host tools (such as run_command, read_file, write_file, edit_file, search_web, invoke_subagent, or ask_question). Answer or emit function calls purely from the provided conversation.",
    ]

    schema: dict | None = None
    if declared_tools:
        schema = TOOL_ENVELOPE_SCHEMA
        sections.append(
            "Respond ONLY via the structured JSON output matching the schema `{\"content\": string, \"tool_calls\": [{\"name\": string, \"arguments_json\": string}]}`:\n"
            "- When you want to call one or more functions from <available_functions>, add each call to `tool_calls` with its exact `name` and a valid JSON object string in `arguments_json` (for example `\"{\\\"query\\\":\\\"test\\\"}\"`), and keep `content` empty or brief.\n"
            "- When no function call is needed, set `tool_calls` to `[]` and put your full assistant reply in `content`."
        )
        if forced_tool_name:
            sections.append(f"You MUST include at least one call to `{forced_tool_name}` in `tool_calls`.")
        elif require_tool:
            sections.append("You MUST include at least one function call in `tool_calls`.")
        sections.append(
            "<available_functions>\n"
            + json.dumps(declared_tools, ensure_ascii=False)
            + "\n</available_functions>"
        )

    system_chunks: list[str] = []
    convo_chunks: list[str] = []
    for msg in messages or ():
        if not isinstance(msg, dict):
            continue
        role = str(msg.get("role") or "user").lower()
        if role in {"system", "developer"}:
            text = _extract_content_text(msg.get("content"))
            if text.strip():
                system_chunks.append(text.strip())
            continue
        convo_chunks.append(_format_conversation_chunk(msg))

    if system_chunks:
        sections.append("<system_instructions>\n" + "\n\n".join(system_chunks) + "\n</system_instructions>")

    footer_sections: list[str] = []
    if not declared_tools:
        footer_sections.append("Write ONLY the assistant's direct response to the latest turn in <conversation>, with no meta-commentary.")

    fixed_overhead = sum(len(s.encode("utf-8")) for s in (*sections, *footer_sections)) + 512
    convo_budget = max(32_000, MAX_PROMPT_UTF8_BYTES - fixed_overhead)
    full_convo = _compact_conversation_chunks(convo_chunks, convo_budget)

    sections.append("<conversation>\n" + full_convo + "\n</conversation>")
    sections.extend(footer_sections)

    return "\n\n".join(sections), schema, declared_names


def _coerce_arguments_json(raw_args) -> str:
    if isinstance(raw_args, dict):
        return json.dumps(raw_args, ensure_ascii=False)
    if isinstance(raw_args, str):
        stripped = raw_args.strip()
        if not stripped:
            return "{}"
        try:
            parsed = json.loads(stripped)
            if isinstance(parsed, dict):
                return json.dumps(parsed, ensure_ascii=False)
            return json.dumps({"value": parsed}, ensure_ascii=False)
        except ValueError:
            return json.dumps({"raw": stripped}, ensure_ascii=False)
    return "{}"


def _extract_json_dict(raw_text: str) -> dict | None:
    """Extract a JSON object from raw or markdown-fenced model output."""
    text = (raw_text or "").strip()
    if not text:
        return None
    with contextlib.suppress(ValueError):
        parsed = json.loads(text)
        if isinstance(parsed, dict):
            return parsed
    fence_match = CODE_FENCE_RE.match(text)
    if fence_match:
        inner = fence_match.group(1).strip()
        with contextlib.suppress(ValueError):
            parsed = json.loads(inner)
            if isinstance(parsed, dict):
                return parsed
    decoder = json.JSONDecoder()
    idx = text.find("{")
    while idx != -1:
        with contextlib.suppress(ValueError):
            candidate, end = decoder.raw_decode(text, idx)
            if isinstance(candidate, dict) and ("tool_calls" in candidate or "content" in candidate or not text[end:].strip()):
                return candidate
        idx = text.find("{", idx + 1)
    return None


def _parse_tool_envelope_dict(
    envelope: dict,
    *,
    declared_names: set[str],
    usage: dict,
) -> dict:
    content = str(envelope.get("content") or "")
    tool_calls: list[dict] = []
    for raw_call in envelope.get("tool_calls") or ():
        if not isinstance(raw_call, dict):
            continue
        name = str(raw_call.get("name") or "").strip()
        if not name:
            continue
        if declared_names and name not in declared_names:
            stripped = name[5:] if name.startswith("mcp__") else name
            if stripped in declared_names:
                name = stripped
            else:
                continue
        args_json = _coerce_arguments_json(
            raw_call.get("arguments_json") if "arguments_json" in raw_call else raw_call.get("arguments")
        )
        tool_calls.append(
            {
                "id": f"call_{uuid.uuid4().hex[:16]}",
                "type": "function",
                "function": {
                    "name": name,
                    "arguments": args_json,
                },
            }
        )
    return {"content": content, "tool_calls": tool_calls, "usage": usage}


def parse_antigravity_cli_response(
    raw_stdout: str,
    *,
    expect_tool_envelope: bool,
    declared_names: set[str],
) -> dict:
    """Parse `agy --output-format json` stdout into `{content, tool_calls, usage}`."""
    cleaned = (raw_stdout or "").strip()
    payload: dict | None = None
    try:
        parsed = json.loads(cleaned)
        if isinstance(parsed, dict):
            payload = parsed
    except ValueError:
        for line in reversed(cleaned.splitlines()):
            line = line.strip()
            if line.startswith("{") and line.endswith("}"):
                with contextlib.suppress(ValueError):
                    candidate = json.loads(line)
                    if isinstance(candidate, dict):
                        payload = candidate
                        break

    if payload is None:
        return {
            "content": cleaned,
            "tool_calls": [],
            "usage": {"prompt_tokens": 0, "completion_tokens": 0, "total_tokens": 0},
        }

    status = str(payload.get("status") or "SUCCESS").upper()
    if status not in {"SUCCESS", "OK", "COMPLETED"}:
        err_msg = str(payload.get("error") or payload.get("response") or f"Antigravity CLI status={status}")
        raise RuntimeError(err_msg)

    raw_usage = payload.get("usage") if isinstance(payload.get("usage"), dict) else {}
    usage = {
        "prompt_tokens": int(raw_usage.get("input_tokens") or 0),
        "completion_tokens": int(raw_usage.get("output_tokens") or 0),
        "total_tokens": int(raw_usage.get("total_tokens") or 0),
    }

    if not expect_tool_envelope:
        structured = payload.get("structured_output")
        if structured is not None:
            content = json.dumps(structured, ensure_ascii=False) if not isinstance(structured, str) else structured
        else:
            content = str(payload.get("response") or "")
            if content.endswith("\n"):
                content = content[:-1]
        return {"content": content, "tool_calls": [], "usage": usage}

    envelope = payload.get("structured_output")
    if not isinstance(envelope, dict):
        envelope = _extract_json_dict(str(payload.get("response") or ""))
    if not isinstance(envelope, dict):
        return {
            "content": str(payload.get("response") or "").strip(),
            "tool_calls": [],
            "usage": usage,
        }
    return _parse_tool_envelope_dict(envelope, declared_names=declared_names, usage=usage)


# ── Persistent Multiplexed ACP Daemon & Stateful KV-Cache Session Pool ───────


@dataclass
class _PendingRPC:
    event: threading.Event = field(default_factory=threading.Event)
    result: dict | None = None
    error: Exception | None = None


@dataclass
class _StreamCollector:
    chunks: list[str] = field(default_factory=list)
    on_delta: Callable[[str], None] | None = None


@dataclass
class _WarmACPSession:
    session_id: str
    context_key: str
    model: str
    history_digests: list[str]
    approx_bytes: int
    last_used: float


class AntigravityACPDaemon:
    """Long-lived `agy acp` stdio JSON-RPC server multiplexing stateful cached sessions."""

    def __init__(self, cli_path: str, sandbox_dir: Path) -> None:
        self.cli_path = cli_path
        self.sandbox_dir = sandbox_dir
        self._write_lock = threading.Lock()
        self._state_lock = threading.Lock()
        self._next_id = 0
        self._pending: dict[int, _PendingRPC] = {}
        self._streams: dict[str, _StreamCollector] = {}
        self._stderr_lines: deque[str] = deque(maxlen=48)
        self._closed = False
        self._available_models: list[str] = []

        self._proc = subprocess.Popen(
            [
                cli_path,
                "acp",
                "--sandbox",
                "--include-default-customizations=false",
            ],
            cwd=str(sandbox_dir),
            env=_agy_env(),
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            encoding="utf-8",
            errors="replace",
            bufsize=1,
            start_new_session=True,
            close_fds=True,
        )
        self._stdout_thread = threading.Thread(
            target=self._reader_loop,
            name="momo-agy-acp-stdout",
            daemon=True,
        )
        self._stderr_thread = threading.Thread(
            target=self._stderr_loop,
            name="momo-agy-acp-stderr",
            daemon=True,
        )
        self._stdout_thread.start()
        self._stderr_thread.start()

        try:
            self.rpc(
                "initialize",
                {
                    "protocolVersion": 1,
                    "clientCapabilities": {},
                    "clientInfo": {"name": "MoMoAgent", "version": "1.0"},
                },
                timeout=20.0,
            )
        except Exception:
            self.close()
            raise

    def is_alive(self) -> bool:
        return not self._closed and self._proc.poll() is None

    def _stderr_tail(self) -> str:
        with self._state_lock:
            return "\n".join(self._stderr_lines).strip()

    def _stderr_loop(self) -> None:
        stream = self._proc.stderr
        if stream is None:
            return
        try:
            for raw in stream:
                cleaned = ANSI_ESCAPE_RE.sub("", raw).strip()
                if cleaned:
                    with self._state_lock:
                        self._stderr_lines.append(cleaned)
        except Exception:
            pass

    def _reader_loop(self) -> None:
        stream = self._proc.stdout
        if stream is None:
            return
        try:
            for raw_line in stream:
                line = raw_line.strip()
                if not line:
                    continue
                try:
                    msg = json.loads(line)
                except ValueError:
                    continue
                if not isinstance(msg, dict):
                    continue

                # Server -> Client request (e.g. session/request_permission if model attempts a host tool):
                # Immediately cancel/reject so host CLI tools can never execute or block inference.
                if "method" in msg and "id" in msg and "result" not in msg and "error" not in msg:
                    self._reject_server_request(msg)
                    continue

                if msg.get("method") == "session/update":
                    params = msg.get("params")
                    if isinstance(params, dict):
                        sid = str(params.get("sessionId") or "")
                        update = params.get("update")
                        if sid and isinstance(update, dict) and update.get("sessionUpdate") == "agent_message_chunk":
                            content = update.get("content")
                            if isinstance(content, dict) and content.get("type") == "text":
                                chunk = str(content.get("text") or "")
                                if chunk:
                                    with self._state_lock:
                                        collector = self._streams.get(sid)
                                    if collector is not None:
                                        collector.chunks.append(chunk)
                                        if collector.on_delta is not None:
                                            with contextlib.suppress(Exception):
                                                collector.on_delta(chunk)
                    continue

                req_id = msg.get("id")
                if isinstance(req_id, int):
                    with self._state_lock:
                        pending = self._pending.pop(req_id, None)
                    if pending is not None:
                        if "error" in msg and msg["error"] is not None:
                            err_obj = msg["error"]
                            if isinstance(err_obj, dict):
                                detail = str(err_obj.get("message") or "")
                                data_part = err_obj.get("data")
                                if data_part:
                                    detail = f"{detail}: {data_part}" if detail else str(data_part)
                                pending.error = RuntimeError(detail or f"ACP error code={err_obj.get('code')}")
                            else:
                                pending.error = RuntimeError(str(err_obj))
                        else:
                            res = msg.get("result")
                            pending.result = res if isinstance(res, dict) else {"value": res}
                        pending.event.set()
        except Exception as exc:
            log.debug("Antigravity ACP stdout reader ended: %s", exc)
        finally:
            self._fail_all_pending()

    def _reject_server_request(self, msg: dict) -> None:
        req_id = msg.get("id")
        method = str(msg.get("method") or "")
        if method == "session/request_permission":
            reply = {"jsonrpc": "2.0", "id": req_id, "result": {"outcome": {"outcome": "cancelled"}}}
        else:
            reply = {
                "jsonrpc": "2.0",
                "id": req_id,
                "error": {"code": -32601, "message": f"Client method {method} disabled in inference bridge"},
            }
        with contextlib.suppress(Exception), self._write_lock:
            if self._proc.stdin and not self._proc.stdin.closed:
                self._proc.stdin.write(json.dumps(reply, ensure_ascii=False) + "\n")
                self._proc.stdin.flush()

    def _fail_all_pending(self) -> None:
        with self._state_lock:
            self._closed = True
            pending_items = list(self._pending.values())
            self._pending.clear()
            self._streams.clear()
            stderr_tail = "\n".join(self._stderr_lines).strip()
        rc = self._proc.poll()
        err_msg = stderr_tail[-400:] if stderr_tail else f"Antigravity ACP daemon exited (status={rc})"
        for item in pending_items:
            item.error = RuntimeError(err_msg)
            item.event.set()

    def rpc(self, method: str, params: dict, *, timeout: float = 30.0) -> dict:
        if not self.is_alive():
            raise RuntimeError(self._stderr_tail()[-400:] or "Antigravity ACP daemon is not running")
        with self._state_lock:
            self._next_id += 1
            req_id = self._next_id
            pending = _PendingRPC()
            self._pending[req_id] = pending

        payload = json.dumps({"jsonrpc": "2.0", "id": req_id, "method": method, "params": params}, ensure_ascii=False)
        try:
            with self._write_lock:
                if self._proc.stdin is None or self._proc.stdin.closed:
                    raise RuntimeError("Antigravity ACP stdin closed")
                self._proc.stdin.write(payload + "\n")
                self._proc.stdin.flush()
        except Exception as exc:
            with self._state_lock:
                self._pending.pop(req_id, None)
            self.close()
            raise RuntimeError(f"Failed writing to Antigravity ACP daemon: {exc}") from exc

        if not pending.event.wait(timeout=timeout):
            with self._state_lock:
                self._pending.pop(req_id, None)
            raise TimeoutError(f"Antigravity ACP {method} timed out after {timeout:.1f}s")

        if pending.error is not None:
            raise pending.error
        return pending.result or {}

    def _record_session_models(self, new_res: dict) -> list[str]:
        models_block = new_res.get("models") if isinstance(new_res.get("models"), dict) else {}
        avail = models_block.get("availableModels") if isinstance(models_block.get("availableModels"), list) else []
        ids = [str(m.get("modelId") or "").strip() for m in avail if isinstance(m, dict) and m.get("modelId")]
        ordered = _order_model_ids(ids)
        if ordered:
            self._available_models = ordered
            _cache_models(self.cli_path, True, ordered)
        return ordered

    def discover_models(self, *, timeout: float = 10.0) -> list[str]:
        if self._available_models:
            return list(self._available_models)
        res = self.rpc(
            "session/new",
            {"cwd": str(self.sandbox_dir), "mcpServers": []},
            timeout=timeout,
        )
        sid = str(res.get("sessionId") or "")
        try:
            return self._record_session_models(res)
        finally:
            if sid:
                with contextlib.suppress(Exception):
                    self.rpc("session/close", {"sessionId": sid}, timeout=5.0)

    def create_session(self, *, model: str, system_prompt: str, timeout: float = 20.0) -> str:
        params: dict = {
            "cwd": str(self.sandbox_dir),
            "mcpServers": [],
        }
        if system_prompt.strip():
            params["_meta"] = {
                "antigravity": {
                    "systemPrompt": {"append": system_prompt.strip()},
                }
            }
        res = self.rpc("session/new", params, timeout=timeout)
        sid = str(res.get("sessionId") or "").strip()
        if not sid:
            raise RuntimeError("Antigravity ACP did not return a sessionId")
        self._record_session_models(res)
        current_model = str((res.get("models") or {}).get("currentModelId") or "").strip()
        if model and model != current_model:
            self.rpc("session/set_model", {"sessionId": sid, "modelId": model}, timeout=10.0)
        return sid

    def run_prompt(
        self,
        session_id: str,
        prompt_text: str,
        *,
        timeout: float = 180.0,
        on_delta: Callable[[str], None] | None = None,
    ) -> tuple[str, dict]:
        collector = _StreamCollector(on_delta=on_delta)
        with self._state_lock:
            self._streams[session_id] = collector
        try:
            res = self.rpc(
                "session/prompt",
                {
                    "sessionId": session_id,
                    "prompt": [{"type": "text", "text": prompt_text}],
                },
                timeout=timeout,
            )
        except TimeoutError:
            with contextlib.suppress(Exception):
                self.cancel_session_nowait(session_id)
            raise
        finally:
            with self._state_lock:
                self._streams.pop(session_id, None)

        raw_usage = res.get("usage") if isinstance(res.get("usage"), dict) else {}
        input_toks = int(raw_usage.get("inputTokens") or 0)
        cached_toks = int(raw_usage.get("cachedReadTokens") or 0)
        output_toks = int(raw_usage.get("outputTokens") or 0)
        total_toks = int(raw_usage.get("totalTokens") or (input_toks + cached_toks + output_toks))
        usage = {
            "prompt_tokens": input_toks + cached_toks,
            "completion_tokens": output_toks,
            "total_tokens": total_toks,
            "prompt_tokens_details": {"cached_tokens": cached_toks},
        }
        return "".join(collector.chunks), usage

    def cancel_session_nowait(self, session_id: str) -> None:
        if not session_id or not self.is_alive():
            return
        with self._state_lock:
            self._next_id += 1
            req_id = self._next_id
        payload = json.dumps(
            {"jsonrpc": "2.0", "id": req_id, "method": "session/cancel", "params": {"sessionId": session_id}},
            ensure_ascii=False,
        )
        with contextlib.suppress(Exception), self._write_lock:
            if self._proc.stdin and not self._proc.stdin.closed:
                self._proc.stdin.write(payload + "\n")
                self._proc.stdin.flush()

    def close_session_nowait(self, session_id: str) -> None:
        if not session_id or not self.is_alive():
            return
        with self._state_lock:
            self._next_id += 1
            req_id = self._next_id
        payload = json.dumps(
            {"jsonrpc": "2.0", "id": req_id, "method": "session/close", "params": {"sessionId": session_id}},
            ensure_ascii=False,
        )
        with contextlib.suppress(Exception), self._write_lock:
            if self._proc.stdin and not self._proc.stdin.closed:
                self._proc.stdin.write(payload + "\n")
                self._proc.stdin.flush()

    def close(self) -> None:
        with self._state_lock:
            if self._closed and self._proc.poll() is not None:
                return
            self._closed = True
        with contextlib.suppress(Exception), self._write_lock:
            if self._proc.stdin and not self._proc.stdin.closed:
                self._proc.stdin.close()
        if self._proc.poll() is None:
            with contextlib.suppress(ProcessLookupError):
                os.killpg(self._proc.pid, signal.SIGTERM)
            try:
                self._proc.wait(timeout=1.5)
            except subprocess.TimeoutExpired:
                with contextlib.suppress(ProcessLookupError):
                    os.killpg(self._proc.pid, signal.SIGKILL)
                with contextlib.suppress(Exception):
                    self._proc.wait(timeout=1.0)
        for pipe in (self._proc.stdout, self._proc.stderr):
            if pipe is not None:
                with contextlib.suppress(Exception):
                    pipe.close()
        self._fail_all_pending()


class AntigravitySessionPool:
    """Thread-safe LRU pool of warm ACP sessions matched by exact conversation prefix digest."""

    def __init__(self, max_sessions: int = MAX_WARM_SESSIONS, idle_ttl: float = SESSION_IDLE_TTL_SECONDS) -> None:
        self.max_sessions = max_sessions
        self.idle_ttl = idle_ttl
        self._lock = threading.Lock()
        self._idle: list[_WarmACPSession] = []

    def clear(self, daemon: AntigravityACPDaemon | None = None) -> None:
        with self._lock:
            evicted = list(self._idle)
            self._idle.clear()
        if daemon is not None:
            for item in evicted:
                daemon.close_session_nowait(item.session_id)

    def acquire_prefix_match(
        self,
        *,
        context_key: str,
        message_digests: list[str],
        daemon: AntigravityACPDaemon,
    ) -> tuple[_WarmACPSession | None, int]:
        now = time.monotonic()
        expired: list[_WarmACPSession] = []
        chosen: _WarmACPSession | None = None
        chosen_idx = -1
        best_len = 0

        with self._lock:
            kept: list[_WarmACPSession] = []
            for entry in self._idle:
                if now - entry.last_used > self.idle_ttl or entry.approx_bytes > MAX_SESSION_ACCUMULATED_BYTES:
                    expired.append(entry)
                else:
                    kept.append(entry)
            self._idle = kept

            # Match the longest committed conversation prefix strictly shorter than incoming `message_digests`.
            if len(message_digests) >= 2:
                for idx, entry in enumerate(self._idle):
                    hlen = len(entry.history_digests)
                    if entry.context_key != context_key:
                        continue
                    if 2 <= hlen < len(message_digests) and hlen >= best_len:
                        if message_digests[:hlen] == entry.history_digests:
                            chosen = entry
                            chosen_idx = idx
                            best_len = hlen
            if chosen is not None and chosen_idx >= 0:
                self._idle.pop(chosen_idx)

        for old in expired:
            daemon.close_session_nowait(old.session_id)

        return chosen, best_len

    def release(self, entry: _WarmACPSession, daemon: AntigravityACPDaemon) -> None:
        if entry.approx_bytes > MAX_SESSION_ACCUMULATED_BYTES:
            daemon.close_session_nowait(entry.session_id)
            return
        entry.last_used = time.monotonic()
        evicted: list[_WarmACPSession] = []
        with self._lock:
            self._idle.append(entry)
            while len(self._idle) > self.max_sessions:
                # Pop least-recently-used entry at index 0.
                evicted.append(self._idle.pop(0))
        for old in evicted:
            daemon.close_session_nowait(old.session_id)


_DAEMON_LOCK = threading.Lock()
_ACTIVE_DAEMON: AntigravityACPDaemon | None = None
_SESSION_POOL = AntigravitySessionPool()


def _peek_live_acp_daemon(cli_path: str) -> AntigravityACPDaemon | None:
    with _DAEMON_LOCK:
        if _ACTIVE_DAEMON is not None and _ACTIVE_DAEMON.cli_path == cli_path and _ACTIVE_DAEMON.is_alive():
            return _ACTIVE_DAEMON
        return None


def _get_or_start_acp_daemon(cli_path: str, sandbox_dir: Path) -> AntigravityACPDaemon:
    global _ACTIVE_DAEMON
    with _DAEMON_LOCK:
        if _ACTIVE_DAEMON is not None and _ACTIVE_DAEMON.cli_path == cli_path and _ACTIVE_DAEMON.is_alive():
            return _ACTIVE_DAEMON
        if _ACTIVE_DAEMON is not None:
            _SESSION_POOL.clear()
            with contextlib.suppress(Exception):
                _ACTIVE_DAEMON.close()
            _ACTIVE_DAEMON = None
        _SESSION_POOL.clear()
        _ACTIVE_DAEMON = AntigravityACPDaemon(cli_path, sandbox_dir)
        return _ACTIVE_DAEMON


def shutdown_antigravity_daemon() -> None:
    """Cleanly stop the persistent `agy acp` background daemon and release all sessions."""
    global _ACTIVE_DAEMON
    with _DAEMON_LOCK:
        daemon = _ACTIVE_DAEMON
        _ACTIVE_DAEMON = None
    _SESSION_POOL.clear(daemon)
    if daemon is not None:
        with contextlib.suppress(Exception):
            daemon.close()


atexit.register(shutdown_antigravity_daemon)


def _canonical_message_digest(msg: dict) -> str:
    role = str(msg.get("role") or "user").lower()
    text = _extract_content_text(msg.get("content")).strip()
    if role == "assistant":
        calls = []
        for tc in msg.get("tool_calls") or ():
            if not isinstance(tc, dict):
                continue
            fn = tc.get("function") or {}
            name = str(fn.get("name") or tc.get("name") or "").strip()
            raw_args = fn.get("arguments") if "arguments" in fn else tc.get("arguments")
            coerced = _coerce_arguments_json(raw_args)
            try:
                args_canon = json.dumps(json.loads(coerced), sort_keys=True, ensure_ascii=False, separators=(",", ":"))
            except ValueError:
                args_canon = coerced
            calls.append((str(tc.get("id") or ""), name, args_canon))
        payload = ["assistant", text, calls]
    elif role == "tool":
        payload = [
            "tool",
            str(msg.get("name") or "").strip(),
            str(msg.get("tool_call_id") or "").strip(),
            text,
        ]
    else:
        payload = ["user", text]
    encoded = json.dumps(payload, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
    return hashlib.sha256(encoded).hexdigest()


def _build_acp_session_contract(
    *,
    system_chunks: list[str],
    base_tools: list[dict],
    response_schema: dict | None,
) -> str:
    parts: list[str] = [
        "CRITICAL RUNTIME CONTRACT: You are operating strictly as a chat-completions inference engine for MoMo Agent. "
        "NEVER invoke any CLI built-in host tools (such as run_command, read_file, write_file, edit_file, search_web, "
        "invoke_subagent, swarm, schedule, or ask_question). Answer or emit function calls purely from the conversation.",
    ]
    if base_tools:
        parts.append(
            "TOOL CALLING OUTPUT FORMAT:\n"
            "Unless a turn explicitly disables tools, respond ONLY with a single raw JSON object (no ```json fences, no extra prose) matching:\n"
            '{"content": "<string>", "tool_calls": [{"name": "<string>", "arguments_json": "<json-object-string>"}]}\n'
            "- When calling one or more functions from <available_functions>, list each call in `tool_calls` with its exact `name` and a valid JSON object string in `arguments_json` (e.g. \"{\\\"query\\\":\\\"test\\\"}\"), keeping `content` empty or brief.\n"
            "- When no function call is needed, set `tool_calls` to `[]` and put your full assistant reply in `content`."
        )
        parts.append("<available_functions>\n" + json.dumps(base_tools, ensure_ascii=False) + "\n</available_functions>")
    elif response_schema is not None:
        parts.append(
            "STRUCTURED OUTPUT FORMAT:\n"
            "Respond ONLY with a single raw JSON object (no markdown fences) strictly conforming to this JSON Schema:\n"
            + json.dumps(response_schema, ensure_ascii=False)
        )
    if system_chunks:
        parts.append("<system_instructions>\n" + "\n\n".join(system_chunks) + "\n</system_instructions>")
    return "\n\n".join(parts)


def _build_acp_turn_prompt(
    delta_messages: list[dict],
    *,
    is_continuation: bool,
    expect_tool_envelope: bool,
    forced_tool_name: str | None,
    require_tool: bool,
    tool_choice_none: bool,
    response_schema: dict | None,
) -> str:
    convo_chunks = [_format_conversation_chunk(m) for m in delta_messages]
    convo_text = _compact_conversation_chunks(convo_chunks, MAX_PROMPT_UTF8_BYTES - 4096)

    directives: list[str] = []
    if expect_tool_envelope:
        if forced_tool_name:
            directives.append(
                f"Respond ONLY with raw JSON {{\"content\": string, \"tool_calls\": [...]}} and MUST include a call to `{forced_tool_name}`."
            )
        elif require_tool:
            directives.append(
                "Respond ONLY with raw JSON {\"content\": string, \"tool_calls\": [...]} and MUST include at least one function call."
            )
        else:
            directives.append(
                "Respond ONLY with raw JSON {\"content\": string, \"tool_calls\": [{\"name\": string, \"arguments_json\": string}]}, without markdown code fences."
            )
    elif tool_choice_none:
        directives.append("Tools are disabled for this turn. Write ONLY your direct plain-text assistant response.")
    elif response_schema is not None:
        directives.append("Respond ONLY with a valid raw JSON object matching the required schema, without markdown code fences.")
    elif not is_continuation:
        directives.append("Write ONLY the assistant's direct response to the latest turn, with no meta-commentary.")

    if directives:
        return convo_text + "\n\n" + "\n".join(directives)
    return convo_text


@contextlib.contextmanager
def _agy_concurrency_slot(*, background: bool = False):
    if background:
        with _AGY_BACKGROUND_SEM:
            with _AGY_TOTAL_SEM:
                yield
    else:
        with _AGY_TOTAL_SEM:
            yield


def _run_antigravity_acp_completion(
    *,
    cli: str,
    model: str,
    messages: list[dict],
    tools: list[dict] | None,
    tool_choice,
    response_format: dict | None,
    sandbox_dir: Path,
    timeout: float,
    background: bool,
    oneshot: bool,
) -> dict:
    base_tools = _normalize_openai_tools(tools)
    tool_choice_none = tool_choice == "none"
    active_tools = [] if tool_choice_none else base_tools
    declared_names = {t["name"] for t in active_tools}
    expect_tool_envelope = bool(active_tools)

    forced_tool_name: str | None = None
    if isinstance(tool_choice, dict):
        fn = tool_choice.get("function")
        if isinstance(fn, dict) and fn.get("name"):
            forced_tool_name = str(fn["name"])
    require_tool = tool_choice == "required" or bool(forced_tool_name)

    response_schema: dict | None = None
    if not expect_tool_envelope and isinstance(response_format, dict) and response_format.get("type") == "json_schema":
        js = response_format.get("json_schema") or {}
        if isinstance(js, dict) and isinstance(js.get("schema"), dict):
            response_schema = js["schema"]

    system_chunks: list[str] = []
    non_sys_messages: list[dict] = []
    for msg in messages or ():
        if not isinstance(msg, dict):
            continue
        role = str(msg.get("role") or "user").lower()
        if role in {"system", "developer"}:
            txt = _extract_content_text(msg.get("content")).strip()
            if txt:
                system_chunks.append(txt)
        else:
            non_sys_messages.append(msg)

    if not non_sys_messages:
        non_sys_messages = [{"role": "user", "content": ""}]

    system_contract = _build_acp_session_contract(
        system_chunks=system_chunks,
        base_tools=base_tools,
        response_schema=response_schema,
    )
    context_fingerprint_src = json.dumps(
        [cli, model, system_contract],
        ensure_ascii=False,
        separators=(",", ":"),
    ).encode("utf-8")
    context_key = hashlib.sha256(context_fingerprint_src).hexdigest()
    msg_digests = [_canonical_message_digest(m) for m in non_sys_messages]

    with _agy_concurrency_slot(background=background):
        daemon = _get_or_start_acp_daemon(cli, sandbox_dir)
        warm_session: _WarmACPSession | None = None
        matched_len = 0
        if not oneshot:
            warm_session, matched_len = _SESSION_POOL.acquire_prefix_match(
                context_key=context_key,
                message_digests=msg_digests,
                daemon=daemon,
            )

        session_id = ""
        created_fresh = False
        try:
            if warm_session is not None:
                session_id = warm_session.session_id
                delta_messages = non_sys_messages[matched_len:]
            else:
                session_id = daemon.create_session(
                    model=model,
                    system_prompt=system_contract,
                    timeout=min(25.0, max(10.0, timeout)),
                )
                created_fresh = True
                delta_messages = non_sys_messages

            turn_prompt = _build_acp_turn_prompt(
                delta_messages,
                is_continuation=(warm_session is not None),
                expect_tool_envelope=expect_tool_envelope,
                forced_tool_name=forced_tool_name,
                require_tool=require_tool,
                tool_choice_none=tool_choice_none,
                response_schema=response_schema,
            )
            prompt_bytes = len(turn_prompt.encode("utf-8"))
            raw_text, usage = daemon.run_prompt(session_id, turn_prompt, timeout=timeout)

            # Parse tool envelope or structured JSON output; self-heal once on the warm session if required.
            if expect_tool_envelope:
                envelope = _extract_json_dict(raw_text)
                if envelope is None and require_tool:
                    repair_text, repair_usage = daemon.run_prompt(
                        session_id,
                        "Your previous reply was not valid JSON. Respond ONLY with a raw JSON object matching "
                        '{"content": string, "tool_calls": [{"name": string, "arguments_json": string}]}.',
                        timeout=min(45.0, timeout),
                    )
                    raw_text = repair_text
                    usage["prompt_tokens"] += repair_usage["prompt_tokens"]
                    usage["completion_tokens"] += repair_usage["completion_tokens"]
                    usage["total_tokens"] += repair_usage["total_tokens"]
                    envelope = _extract_json_dict(raw_text)

                if isinstance(envelope, dict):
                    parsed = _parse_tool_envelope_dict(envelope, declared_names=declared_names, usage=usage)
                else:
                    parsed = {"content": raw_text.strip(), "tool_calls": [], "usage": usage}
            elif response_schema is not None:
                extracted = _extract_json_dict(raw_text)
                if extracted is None:
                    repair_text, repair_usage = daemon.run_prompt(
                        session_id,
                        "Respond ONLY with a valid raw JSON object matching the required JSON schema.",
                        timeout=min(45.0, timeout),
                    )
                    raw_text = repair_text
                    usage["total_tokens"] += repair_usage["total_tokens"]
                    extracted = _extract_json_dict(raw_text)
                content_str = json.dumps(extracted, ensure_ascii=False) if extracted is not None else raw_text.strip()
                parsed = {"content": content_str, "tool_calls": [], "usage": usage}
            else:
                text_out = raw_text[:-1] if raw_text.endswith("\n") else raw_text
                parsed = {"content": text_out, "tool_calls": [], "usage": usage}

            tool_calls = parsed["tool_calls"]
            content = parsed["content"]
            message_obj: dict = {
                "role": "assistant",
                "content": content if (content or not tool_calls) else None,
            }
            if tool_calls:
                message_obj["tool_calls"] = tool_calls

            if oneshot:
                daemon.close_session_nowait(session_id)
            else:
                assistant_digest = _canonical_message_digest(message_obj)
                total_bytes = (warm_session.approx_bytes if warm_session else len(system_contract.encode("utf-8"))) + prompt_bytes + len(raw_text.encode("utf-8"))
                updated_entry = _WarmACPSession(
                    session_id=session_id,
                    context_key=context_key,
                    model=model,
                    history_digests=[*msg_digests, assistant_digest],
                    approx_bytes=total_bytes,
                    last_used=time.monotonic(),
                )
                _SESSION_POOL.release(updated_entry, daemon)

            return {
                "id": f"chatcmpl-{uuid.uuid4().hex[:20]}",
                "object": "chat.completion",
                "created": int(time.time()),
                "model": model,
                "choices": [
                    {
                        "index": 0,
                        "message": message_obj,
                        "finish_reason": "tool_calls" if tool_calls else "stop",
                    }
                ],
                "usage": parsed["usage"],
            }
        except Exception as err:
            if session_id:
                daemon.close_session_nowait(session_id)
            lowered = str(err).lower()
            if "unauthenticated" in lowered or "unauthorized" in lowered or "not logged in" in lowered or "sign in" in lowered:
                clear_antigravity_caches()
            # If a warm session vanished server-side, transparently retry once on a fresh session.
            if warm_session is not None and not created_fresh and ("session" in lowered and ("not found" in lowered or "closed" in lowered)):
                return _run_antigravity_acp_completion(
                    cli=cli,
                    model=model,
                    messages=messages,
                    tools=tools,
                    tool_choice=tool_choice,
                    response_format=response_format,
                    sandbox_dir=sandbox_dir,
                    timeout=timeout,
                    background=background,
                    oneshot=True,
                )
            raise


def _run_antigravity_legacy_print_completion(
    *,
    cli: str,
    model: str,
    messages: list[dict],
    tools: list[dict] | None,
    tool_choice,
    response_format: dict | None,
    sandbox_dir: Path,
    timeout: float,
    background: bool,
) -> dict:
    """Fallback single-turn `agy -p` execution (used only when `MOMO_ANTIGRAVITY_TRANSPORT=print` or mocked subprocess)."""
    prompt, tool_schema, declared_names = build_antigravity_prompt(
        messages,
        tools=tools,
        tool_choice=tool_choice,
    )
    expect_tool_envelope = tool_schema is not None
    effective_schema = tool_schema
    if effective_schema is None and isinstance(response_format, dict):
        if response_format.get("type") == "json_schema":
            js = response_format.get("json_schema") or {}
            if isinstance(js, dict) and isinstance(js.get("schema"), dict):
                effective_schema = js["schema"]

    encoded_prompt = prompt.encode("utf-8")
    if len(encoded_prompt) > MAX_PROMPT_UTF8_BYTES + 16_000:
        head = encoded_prompt[:56_000].decode("utf-8", errors="ignore")
        tail = encoded_prompt[-56_000:].decode("utf-8", errors="ignore")
        prompt = f"{head}\n\n...[中间较早上下文已自动压缩以适配 CLI 参数上限]...\n\n{tail}"

    schema_file: Path | None = None
    cmd = [
        cli,
        "-p",
        prompt,
        "--model",
        model,
        "--disable-slash-commands",
        "--sandbox",
        "--output-format",
        "json",
    ]
    if effective_schema is not None:
        schema_str = json.dumps(effective_schema, ensure_ascii=False)
        if len(schema_str.encode("utf-8")) > 8_192:
            schema_file = sandbox_dir / f"schema-{uuid.uuid4().hex}.json"
            schema_file.write_text(schema_str, encoding="utf-8")
            cmd.extend(["--json-schema", str(schema_file)])
        else:
            cmd.extend(["--json-schema", schema_str])

    try:
        with _agy_concurrency_slot(background=background):
            proc = subprocess.run(
                cmd,
                cwd=str(sandbox_dir),
                env=_agy_env(),
                stdin=subprocess.DEVNULL,
                capture_output=True,
                text=True,
                timeout=timeout,
                check=False,
            )
    finally:
        if schema_file is not None:
            with contextlib.suppress(OSError):
                schema_file.unlink()
    if proc.returncode != 0:
        detail = ANSI_ESCAPE_RE.sub("", (proc.stderr or proc.stdout or "").strip())
        raise RuntimeError(detail[:400] or f"agy exited with status {proc.returncode}")

    parsed = parse_antigravity_cli_response(
        proc.stdout,
        expect_tool_envelope=expect_tool_envelope,
        declared_names=declared_names,
    )
    tool_calls = parsed["tool_calls"]
    content = parsed["content"]
    message_obj: dict = {
        "role": "assistant",
        "content": content if (content or not tool_calls) else None,
    }
    if tool_calls:
        message_obj["tool_calls"] = tool_calls

    return {
        "id": f"chatcmpl-{uuid.uuid4().hex[:20]}",
        "object": "chat.completion",
        "created": int(time.time()),
        "model": model,
        "choices": [
            {
                "index": 0,
                "message": message_obj,
                "finish_reason": "tool_calls" if tool_calls else "stop",
            }
        ],
        "usage": parsed["usage"],
    }


def run_antigravity_completion(
    *,
    model: str,
    messages: list[dict],
    tools: list[dict] | None = None,
    tool_choice=None,
    response_format: dict | None = None,
    data_dir: Path | None = None,
    timeout: float = 180.0,
    background: bool = False,
    oneshot: bool = False,
) -> dict:
    """Execute a chat completion via the persistent `agy acp` session daemon (with KV-cache reuse across turns)."""
    cli = find_antigravity_cli()
    if not cli:
        raise RuntimeError("未找到 Antigravity CLI (agy)，请先安装 agy。")

    sandbox_dir = _empty_sandbox_dir(data_dir)
    transport = os.environ.get("MOMO_ANTIGRAVITY_TRANSPORT", "acp").strip().lower()
    if transport == "print" or _is_mocked_subprocess():
        return _run_antigravity_legacy_print_completion(
            cli=cli,
            model=model,
            messages=messages,
            tools=tools,
            tool_choice=tool_choice,
            response_format=response_format,
            sandbox_dir=sandbox_dir,
            timeout=timeout,
            background=background,
        )

    return _run_antigravity_acp_completion(
        cli=cli,
        model=model,
        messages=messages,
        tools=tools,
        tool_choice=tool_choice,
        response_format=response_format,
        sandbox_dir=sandbox_dir,
        timeout=timeout,
        background=background,
        oneshot=oneshot,
    )


def format_sse_chunks_from_completion(completion: dict) -> bytes:
    """Convert a chat.completion payload into OpenAI-compatible SSE stream bytes."""
    cid = completion["id"]
    created = completion["created"]
    model = completion["model"]
    choice = (completion.get("choices") or [{}])[0]
    msg = choice.get("message") or {}
    finish_reason = choice.get("finish_reason") or "stop"
    content = msg.get("content")
    tool_calls = msg.get("tool_calls") or []

    events: list[str] = []
    events.append(
        json.dumps(
            {
                "id": cid,
                "object": "chat.completion.chunk",
                "created": created,
                "model": model,
                "choices": [{"index": 0, "delta": {"role": "assistant", "content": ""}, "finish_reason": None}],
            },
            ensure_ascii=False,
        )
    )
    if content:
        events.append(
            json.dumps(
                {
                    "id": cid,
                    "object": "chat.completion.chunk",
                    "created": created,
                    "model": model,
                    "choices": [{"index": 0, "delta": {"content": content}, "finish_reason": None}],
                },
                ensure_ascii=False,
            )
        )
    if tool_calls:
        streamed_calls = [
            {
                "index": idx,
                "id": tc["id"],
                "type": "function",
                "function": {
                    "name": tc["function"]["name"],
                    "arguments": tc["function"]["arguments"],
                },
            }
            for idx, tc in enumerate(tool_calls)
        ]
        events.append(
            json.dumps(
                {
                    "id": cid,
                    "object": "chat.completion.chunk",
                    "created": created,
                    "model": model,
                    "choices": [{"index": 0, "delta": {"tool_calls": streamed_calls}, "finish_reason": None}],
                },
                ensure_ascii=False,
            )
        )
    events.append(
        json.dumps(
            {
                "id": cid,
                "object": "chat.completion.chunk",
                "created": created,
                "model": model,
                "choices": [{"index": 0, "delta": {}, "finish_reason": finish_reason}],
                "usage": completion.get("usage") or {"prompt_tokens": 0, "completion_tokens": 0, "total_tokens": 0},
            },
            ensure_ascii=False,
        )
    )
    body = "".join(f"data: {item}\n\n" for item in events) + "data: [DONE]\n\n"
    return body.encode("utf-8")


async def run_antigravity_completion_async(
    *,
    model: str,
    messages: list[dict],
    tools: list[dict] | None = None,
    tool_choice=None,
    response_format: dict | None = None,
    data_dir: Path | None = None,
    timeout: float = 180.0,
    background: bool = False,
    oneshot: bool = False,
) -> dict:
    """Async non-blocking wrapper around `run_antigravity_completion`."""
    return await asyncio.to_thread(
        run_antigravity_completion,
        model=model,
        messages=messages,
        tools=tools,
        tool_choice=tool_choice,
        response_format=response_format,
        data_dir=data_dir,
        timeout=timeout,
        background=background,
        oneshot=oneshot,
    )
