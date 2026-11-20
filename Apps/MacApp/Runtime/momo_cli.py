#!/usr/bin/env python3
"""MoMo personal context & memory CLI for DeepSeek SuperAgent worker sessions.

Workers use the shared MoMo context store and Markdown memory notebook.
"""
from __future__ import annotations

import argparse
import asyncio
import contextlib
from html import unescape
from html.parser import HTMLParser
import ipaddress
import json
import os
from pathlib import Path
import re
import socket
import sqlite3
import sys
import time
from urllib.parse import parse_qs, quote_plus, unquote, urlparse
import urllib.request
import uuid

REPOSITORY = Path(__file__).resolve().parents[3]
if str(REPOSITORY / "Apps/MacApp/Runtime") not in sys.path:
    sys.path.insert(0, str(REPOSITORY / "Apps/MacApp/Runtime"))
sys.path.insert(0, str(REPOSITORY / "Apps/MacApp/Context"))
sys.path.insert(0, str(REPOSITORY / "Vendor/HermesAgent"))

from superagent_runtime import classify_transcript_span


def _speaker_role(is_owner: bool | None) -> str:
    if is_owner is True:
        return "owner"
    if is_owner is False:
        return "other"
    return "unattributed"


def _local_dt(ts: float | int | None) -> str | None:
    if ts is None:
        return None
    try:
        val = float(ts)
    except (TypeError, ValueError):
        return None
    if val <= 0:
        return None
    return time.strftime("%Y-%m-%d %H:%M:%S %z", time.localtime(val))


def _open_context(data: Path):
    from context_store import ContextStore
    return ContextStore(data / "context")


def _cmd_recordings(data: Path, args: argparse.Namespace) -> dict:
    store = _open_context(data)
    try:
        result = store.list_sources(args.after, args.limit)
        items = result.get("items") or []
        for item in items:
            windows = item.pop("windows", None) or []
            item.pop("recorded_summary", None)
            if item.get("recorded_at") is None and windows:
                item["recorded_at"] = windows[0].get("recorded_at")
            if windows:
                item["ended_at"] = windows[-1].get("end_at")
            item["recorded_at_local"] = _local_dt(item.get("recorded_at"))
            item["ended_at_local"] = _local_dt(item.get("ended_at"))
        items.sort(key=lambda x: float(x.get("ended_at") or x.get("recorded_at") or 0.0), reverse=True)
        result["current_local_time"] = _local_dt(time.time())
        return result
    finally:
        store.close()


def _cmd_life_illustrations(data: Path, args: argparse.Namespace) -> dict:
    if getattr(args, "regenerate", None):
        conn = json.loads((data / "connection.json").read_text(encoding="utf-8"))
        api_key = (data / "api-key").read_text(encoding="utf-8").strip()
        url = f"{conn['data_url'].rstrip('/')}/v1/life-illustrations/regenerate"
        body = json.dumps({"id": args.regenerate}).encode("utf-8")
        req = urllib.request.Request(
            url,
            data=body,
            headers={"Authorization": f"Bearer {api_key}", "Content-Type": "application/json"},
            method="POST",
        )
        opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
        with opener.open(req, timeout=20) as resp:
            return json.loads(resp.read().decode("utf-8"))
    from life_illustrations import LifeIllustrations
    from life_illustration_generator import CodexIllustrationGenerator
    queue = LifeIllustrations(data)
    try:
        return dict(settings=queue.settings(CodexIllustrationGenerator(data).availability()),
                    **queue.status(args.after, args.limit))
    finally:
        queue.close()


def _cmd_recording(data: Path, args: argparse.Namespace) -> dict:
    store = _open_context(data)
    try:
        result = store.read_source(args.source_id, args.revision or None, args.offset, args.limit, location_offset=args.location_offset)
        spans = result.get("spans") or []
        for span in spans:
            span["recorded_at_local"] = _local_dt(span.get("recorded_at"))
            spk_label, spk_is_owner, _ = classify_transcript_span(span)
            if spk_label and "speaker" not in span:
                span["speaker"] = spk_label
            span["speaker_role"] = _speaker_role(spk_is_owner)
        if spans:
            result["recorded_start_local"] = spans[0].get("recorded_at_local")
            result["recorded_end_local"] = spans[-1].get("recorded_at_local")
        result["speaker_ownership_note"] = (
            "Spans with speaker_role='owner' ([我]) matched the user's voiceprint; "
            "speaker_role='other' matched a known non-owner speaker; "
            "speaker_role='unattributed' (e.g. [说话人 N] or untagged spans) has unverified voiceprint identity "
            "(in far-field, Watch, or multi-person meetings this may be a colleague or the user) — "
            "infer speaker and action ownership from conversational context rather than assuming [说话人 N] cannot be the user."
        )
        result["current_local_time"] = _local_dt(time.time())
        return result
    finally:
        store.close()


def _cmd_recording_reference(data: Path, args: argparse.Namespace) -> dict:
    operation = str(uuid.UUID(args.operation_id))
    if args.offset < 0 or not 1 <= args.limit <= 100:
        raise ValueError("Use a nonnegative offset and a limit between 1 and 100 spans")
    db_path = data / "runtime/conversation.sqlite"
    with contextlib.closing(sqlite3.connect(f"{db_path.as_uri()}?mode=ro", uri=True)) as db:
        row = db.execute("SELECT attachments_json FROM inputs WHERE operation_id=?", (operation,)).fetchone()
    attachments = json.loads(row[0] or "[]") if row else []
    reference = next((item["recording"] for item in attachments if "recording" in item), None)
    if reference is None:
        raise ValueError("Recording reference not found for this operation")
    from context_store import Conflict
    with contextlib.closing(_open_context(data)) as store:
        try:
            spans = store.recording_reference_spans(reference)
        except Conflict as error:
            raise ValueError("recording_reference_changed") from error
    page = []
    text_bytes = 0
    for span in spans[args.offset:args.offset + args.limit]:
        size = len(span["text"].encode("utf-8"))
        if page and text_bytes + size > 12_000:
            break
        page.append(span)
        text_bytes += size
    end = args.offset + len(page)
    return {"spans": page, "next_offset": end if end < len(spans) else None}


def _cmd_search(data: Path, args: argparse.Namespace) -> dict:
    from memory_search import MemorySearch
    result = MemorySearch(data).search(args.query, args.alternative_query, kind="recording", limit=max(1, min(args.limit, 50)))
    for match in result["matches"]:
        speaker, owner, _ = classify_transcript_span(match)
        match["speaker"] = speaker
        match["speaker_role"] = _speaker_role(owner)
        match["recorded_at_local"] = _local_dt(match["recorded_at"])
        match["evidence_revision"] = match["revision"]
        match["revision"] = match["source_revision"]  # Existing recording --revision contract.
    return {"query": args.query, "current_local_time": _local_dt(time.time()), **result}


def _cmd_save_recording_result(data: Path, args: argparse.Namespace) -> dict:
    store = _open_context(data)
    try:
        return store.write_result(args.source_id, args.revision, args.title, args.text)
    finally:
        store.close()


def _cmd_phone_context(data: Path, args: argparse.Namespace) -> dict:
    from phone_sources import read_phone_sources
    store = _open_context(data)
    try:
        return read_phone_sources(store, args.kind, "" if args.kind == "all" else args.after, args.limit)
    finally:
        store.close()


def _cmd_health(data: Path, args: argparse.Namespace) -> dict:
    from health_store import read_health
    store = _open_context(data)
    try:
        return read_health(store, args.after, args.limit, category=args.category)
    finally:
        store.close()


def _context_server_post(data: Path, path: str, body: dict) -> dict | None:
    conn_file = data / "connection.json"
    key_file = data / "api-key"
    if not conn_file.is_file() or not key_file.is_file():
        return None
    try:
        conn_info = json.loads(conn_file.read_text(encoding="utf-8"))
        base_url = str(conn_info.get("data_url") or "").rstrip("/")
        token = key_file.read_text(encoding="utf-8").strip()
        if not base_url or not token:
            return None
        req = urllib.request.Request(
            f"{base_url}{path}",
            data=json.dumps(body, ensure_ascii=False).encode("utf-8"),
            headers={
                "Authorization": f"Bearer {token}",
                "Content-Type": "application/json",
                "Accept": "application/json",
            },
            method="POST",
        )
        with urllib.request.urlopen(req, timeout=30) as resp:
            return json.loads(resp.read().decode("utf-8"))
    except urllib.error.HTTPError as exc:
        raw = exc.read().decode("utf-8", errors="replace")
        try:
            err_obj = json.loads(raw)
            msg = err_obj.get("message") or err_obj.get("error") or raw
        except ValueError:
            msg = raw or str(exc)
        raise ValueError(msg) from exc
    except Exception:
        return None


def _cmd_connectors(data: Path, args: argparse.Namespace) -> dict:
    from connectors import (
        configure_email_connector,
        connector_policy_stats,
        connectors_status,
        delete_connector_policy_rule,
        disconnect_connector,
        list_connector_items,
        load_connector_policy,
        mute_connector_channel,
        read_connector_item,
        read_feishu_doc_live,
        read_feishu_thread_live,
        search_feishu_live,
        sync_connectors,
        upsert_connector_policy_rule,
    )
    action = str(getattr(args, "action", "") or "").strip()
    if args.item_id or action == "item":
        store = _open_context(data)
        try:
            item = read_connector_item(store, args.item_id)
            if item is None:
                raise ValueError(f"Connector item not found: {args.item_id}")
            return item
        finally:
            store.close()
    if args.items or action == "items":
        store = _open_context(data)
        try:
            return {"items": list_connector_items(store, connector=args.connector, limit=args.limit)}
        finally:
            store.close()
    if action == "configure-email":
        payload: dict[str, object] = {
            "username": args.username,
            "enabled": True,
        }
        if args.password:
            payload["password"] = args.password
        if args.preset:
            payload["preset"] = args.preset
        if args.host:
            payload["host"] = args.host
        if args.port:
            payload["port"] = args.port
        if args.folder:
            payload["folder"] = args.folder
        if args.sync_days:
            payload["sync_days"] = args.sync_days
        live = _context_server_post(data, "/v1/connectors/email/configure", payload)
        if live is not None:
            return live
        res = configure_email_connector(data, payload)
        store = _open_context(data)
        try:
            sync_connectors(data, store, connector="email")
        finally:
            store.close()
        return res
    if action == "start-feishu-oauth":
        payload = {
            "domain": args.domain or "feishu",
            "app_id": args.app_id,
        }
        if args.app_secret:
            payload["app_secret"] = args.app_secret
        live = _context_server_post(data, "/v1/connectors/feishu/oauth/start", payload)
        if live is None:
            raise ValueError("MoMo 本地上下文服务未运行，请确认 MoMo Agent 已启动后重试。")
        if getattr(args, "open_browser", False) and live.get("authorize_url"):
            import subprocess
            subprocess.Popen(["open", str(live["authorize_url"])], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            live["opened_in_browser"] = True
        return live
    if action == "sync":
        live = _context_server_post(data, "/v1/connectors/sync", {"connector": args.connector})
        if live is not None:
            return live
        store = _open_context(data)
        try:
            return sync_connectors(data, store, connector=args.connector)
        finally:
            store.close()
    if action == "live-doc":
        return read_feishu_doc_live(data, args.url or args.target)
    if action == "live-thread":
        return read_feishu_thread_live(
            data,
            args.chat_id or args.target,
            limit=args.limit,
            include_bots=bool(getattr(args, "include_bots", False)),
        )
    if action == "live-search":
        return search_feishu_live(data, args.query or args.target, limit=args.limit)
    if action in ("mute", "unmute"):
        conn_target = args.connector if args.connector in ("feishu", "email") else "feishu"
        store = _open_context(data)
        try:
            return mute_connector_channel(
                data,
                store,
                conn_target,
                args.target or args.chat_id,
                mute=(action == "mute"),
            )
        finally:
            store.close()
    if action == "policy-list":
        return load_connector_policy(data)
    if action == "policy-stats":
        store = _open_context(data)
        try:
            return connector_policy_stats(data, store, days=args.sync_days or 7, limit=args.limit)
        finally:
            store.close()
    if action == "policy-upsert":
        if not args.rule_json:
            raise ValueError("Provide --rule-json with the policy rule JSON object")
        rule = json.loads(args.rule_json)
        store = _open_context(data)
        try:
            return upsert_connector_policy_rule(data, store, rule)
        finally:
            store.close()
    if action == "policy-delete":
        store = _open_context(data)
        try:
            return delete_connector_policy_rule(data, store, args.rule_id or args.target)
        finally:
            store.close()
    if action == "disconnect":
        target = args.connector
        if target not in ("feishu", "email"):
            raise ValueError("Specify --connector feishu or --connector email to disconnect")
        live = _context_server_post(data, "/v1/connectors/disconnect", {"connector": target, "clear_data": False})
        if live is not None:
            return live
        store = _open_context(data)
        try:
            return disconnect_connector(data, store, target)
        finally:
            store.close()
    store = _open_context(data)
    try:
        return connectors_status(data, store)
    finally:
        store.close()


def _cmd_situation(data: Path, args: argparse.Namespace) -> dict:
    from situational_context import read_situational_context
    store = _open_context(data)
    try:
        return read_situational_context(store, data_dir=data)
    finally:
        store.close()


def _cmd_memories(data: Path, args: argparse.Namespace) -> dict:
    from momo_memory import MoMoMemory
    return MoMoMemory(data).list(after=args.after, limit=args.limit)


def _cmd_search_memory(data: Path, args: argparse.Namespace) -> dict:
    from memory_search import MemorySearch
    return MemorySearch(data).search(args.query, args.alternative_query, args.kind, args.limit)


def _cmd_read_memory_evidence(data: Path, args: argparse.Namespace) -> dict:
    from memory_search import MemorySearch
    return MemorySearch(data).read(args.id, args.revision, args.offset, args.limit)


def _cmd_remember(data: Path, args: argparse.Namespace) -> dict:
    from momo_memory import MoMoMemory
    memory = MoMoMemory(data)
    with memory.store() as store:
        result = store.add(args.target, args.text.strip())
    return result


def _cmd_forget(data: Path, args: argparse.Namespace) -> dict:
    from momo_memory import MoMoMemory
    return MoMoMemory(data).forget(args.memory_id)


def _cmd_notebook(data: Path, args: argparse.Namespace) -> dict:
    from momo_memory import MoMoMemory
    memory = MoMoMemory(data)
    act = args.action
    rel_path = getattr(args, "path", None) or None
    if act == "list":
        return {"notes": memory.list_notebook(args.category or None, path_prefix=rel_path)}
    if act == "read":
        return memory.read_notebook(args.category or (None if rel_path else "briefing"), args.slug or None, path=rel_path)
    if act == "write":
        return memory.write_notebook(
            args.category or (None if rel_path else "briefing"),
            args.content or "",
            slug=args.slug or None,
            title=args.title or None,
            mode=args.mode or "replace",
            path=rel_path,
        )
    if act == "remove":
        return memory.remove_notebook(args.category or None, args.slug or None, path=rel_path)
    if act == "move":
        return memory.move_notebook(
            args.category or None,
            args.slug or None,
            path=rel_path,
            to_path=getattr(args, "to_path", None) or None,
            overwrite=bool(getattr(args, "overwrite", False)),
        )
    raise ValueError(f"Unknown notebook action: {act}")


def _cmd_exclude_speaker(data: Path, args: argparse.Namespace) -> dict:
    store = _open_context(data)
    try:
        return store.exclude_speaker(args.speaker, source_id=args.source_id,
                                     span_ids=args.span_ids.split(",") if args.span_ids else None,
                                     recorded_from=args.recorded_from)
    finally:
        store.close()


def _cmd_relabel_speakers(data: Path, args: argparse.Namespace) -> dict:
    store = _open_context(data)
    try:
        span_ids = [s.strip() for s in (args.span_ids or "").split(",") if s.strip()] or None
        return store.relabel_speakers(
            args.source_id,
            args.target_speaker,
            is_owner=bool(args.is_owner),
            from_speaker=args.from_speaker or None,
            span_ids=span_ids,
            scope=args.scope,
            reason=args.reason or "",
            importance=args.importance,
            benefit=args.benefit,
            supporting_source_ids=args.supporting_source,
        )
    finally:
        store.close()


def _cmd_pim(data: Path, args: argparse.Namespace) -> dict:
    from apple_pim import ApplePIM

    payload = json.loads(args.args_json) if args.args_json else {}
    if not isinstance(payload, dict):
        raise ValueError("--args-json must decode to a JSON object")
    return ApplePIM(data).call_sync(args.op, payload)


def _cmd_conversation(data: Path, args: argparse.Namespace) -> dict:
    db_path = data / "runtime/conversation.sqlite"
    if not db_path.is_file():
        return {"current_local_time": _local_dt(time.time()), "messages": []}
    conn = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True)
    conn.row_factory = sqlite3.Row
    try:
        rows = conn.execute(
            "SELECT seq, id, role, content, created_at, run_id FROM messages ORDER BY seq DESC LIMIT ?",
            (max(1, min(args.limit, 50)),),
        ).fetchall()
        messages = []
        for row in reversed(rows):
            item = dict(row)
            item["created_at_local"] = _local_dt(item.get("created_at"))
            messages.append(item)
        return {"current_local_time": _local_dt(time.time()), "messages": messages}
    finally:
        conn.close()


class _ReadableHTMLParser(HTMLParser):
    def __init__(self) -> None:
        super().__init__(convert_charrefs=True)
        self._skip_depth = 0
        self._in_title = False
        self.title_parts: list[str] = []
        self.chunks: list[str] = []

    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        lower = tag.lower()
        if lower in ("script", "style", "noscript", "svg", "template"):
            self._skip_depth += 1
        elif lower == "title":
            self._in_title = True
        elif self._skip_depth == 0 and lower in ("p", "div", "section", "article", "li", "h1", "h2", "h3", "h4", "br", "tr"):
            self.chunks.append("\n")

    def handle_endtag(self, tag: str) -> None:
        lower = tag.lower()
        if lower in ("script", "style", "noscript", "svg", "template") and self._skip_depth > 0:
            self._skip_depth -= 1
        elif lower == "title":
            self._in_title = False
        elif self._skip_depth == 0 and lower in ("p", "div", "section", "article", "li", "h1", "h2", "h3", "h4", "tr"):
            self.chunks.append("\n")

    def handle_data(self, data: str) -> None:
        if self._in_title:
            self.title_parts.append(data)
        if self._skip_depth == 0:
            self.chunks.append(data)


def _is_public_http_url(url: str) -> bool:
    parsed = urlparse(url)
    if parsed.scheme not in ("http", "https") or not parsed.hostname:
        return False
    host = parsed.hostname.strip().lower()
    if host in ("localhost", "ip6-localhost") or host.endswith(".local"):
        return False
    try:
        infos = socket.getaddrinfo(host, parsed.port or (443 if parsed.scheme == "https" else 80), type=socket.SOCK_STREAM)
    except OSError:
        return False
    if not infos:
        return False
    for info in infos:
        addr = info[4][0]
        try:
            ip = ipaddress.ip_address(addr)
        except ValueError:
            return False
        if ip.is_private or ip.is_loopback or ip.is_link_local or ip.is_multicast or ip.is_reserved or ip.is_unspecified:
            return False
    return True


def _stdlib_duckduckgo_search(query: str, limit: int) -> dict:
    url = f"https://html.duckduckgo.com/html/?q={quote_plus(query)}"
    req = urllib.request.Request(
        url,
        headers={
            "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0 Safari/537.36",
            "Accept": "text/html,application/xhtml+xml",
        },
    )
    with urllib.request.urlopen(req, timeout=15) as resp:
        html = resp.read(512_000).decode("utf-8", errors="replace")
    items: list[dict] = []
    pattern = re.compile(
        r'<a[^>]*class="[^"]*result__a[^"]*"[^>]*href="([^"]+)"[^>]*>(.*?)</a>',
        re.IGNORECASE | re.DOTALL,
    )
    snippet_pattern = re.compile(
        r'<a[^>]*class="[^"]*result__snippet[^"]*"[^>]*>(.*?)</a>|<div[^>]*class="[^"]*result__snippet[^"]*"[^>]*>(.*?)</div>',
        re.IGNORECASE | re.DOTALL,
    )
    snippets = [
        unescape(re.sub(r"<[^>]+>", "", m.group(1) or m.group(2) or "")).strip()
        for m in snippet_pattern.finditer(html)
    ]
    for idx, match in enumerate(pattern.finditer(html)):
        raw_href, raw_title = match.group(1), match.group(2)
        href = unescape(raw_href).strip()
        if "uddg=" in href:
            qs = parse_qs(urlparse(href).query)
            if qs.get("uddg"):
                href = unquote(qs["uddg"][0])
        title = unescape(re.sub(r"<[^>]+>", "", raw_title)).strip()
        if not href.startswith(("http://", "https://")) or not title:
            continue
        items.append(
            {
                "position": len(items) + 1,
                "title": title,
                "url": href,
                "description": snippets[idx] if idx < len(snippets) else "",
            }
        )
        if len(items) >= limit:
            break
    return {"success": bool(items), "data": {"web": items}, **({} if items else {"error": "No web results returned"})}


def _stdlib_fetch_extract(urls: list[str], char_limit: int) -> dict:
    results: list[dict] = []
    for url in urls:
        clean_url = str(url or "").strip()
        if not _is_public_http_url(clean_url):
            results.append({"url": clean_url, "title": "", "content": "", "error": "Blocked or invalid URL"})
            continue
        try:
            req = urllib.request.Request(
                clean_url,
                headers={
                    "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0 Safari/537.36",
                    "Accept": "text/html,application/xhtml+xml,text/plain,text/markdown;q=0.9,*/*;q=0.5",
                },
            )
            with urllib.request.urlopen(req, timeout=20) as resp:
                ctype = (resp.headers.get("Content-Type") or "").lower()
                raw = resp.read(1_500_000).decode("utf-8", errors="replace")
            if "html" in ctype or "<html" in raw[:1000].lower():
                parser = _ReadableHTMLParser()
                parser.feed(raw)
                title = " ".join("".join(parser.title_parts).split()).strip()
                lines = [" ".join(line.split()) for line in "".join(parser.chunks).splitlines()]
                content = "\n".join(line for line in lines if line).strip()
            else:
                title = ""
                content = raw.strip()
            if char_limit > 0 and len(content) > char_limit:
                content = content[:char_limit] + "\n...[truncated]"
            results.append({"url": clean_url, "title": title, "content": content, "error": None if content else "Empty page content"})
        except Exception as exc:
            results.append({"url": clean_url, "title": "", "content": "", "error": str(exc)})
    return {"results": results}


def _configure_provider_env(data: Path) -> None:
    from momo_agent import credentials_directory
    os.environ.setdefault("HERMES_HOME", str(credentials_directory(data)))


def _cmd_web_search(data: Path, args: argparse.Namespace) -> dict:
    limit = max(1, min(int(args.limit), 20))
    _configure_provider_env(data)
    try:
        with contextlib.redirect_stdout(sys.stderr):
            from tools import web_tools

            web_tools._ensure_web_plugins_loaded()
            orig_get = web_tools._get_search_backend
            backend = orig_get()
            # openai-native is a server-side Responses API tool and cannot execute standalone in CLI subprocesses.
            if backend == "openai-native":
                fallback_backend = (
                    web_tools._keyless_backend()
                    or ("ddgs" if web_tools._ddgs_package_importable() else None)
                )
                if fallback_backend:
                    web_tools._get_search_backend = lambda: fallback_backend
            try:
                raw_json = web_tools.web_search_tool(args.query, limit=limit)
            finally:
                web_tools._get_search_backend = orig_get
        parsed = json.loads(raw_json)
        if isinstance(parsed, dict) and parsed.get("success") and parsed.get("data", {}).get("web"):
            return parsed
    except Exception:
        parsed = None

    with contextlib.suppress(Exception):
        fallback = _stdlib_duckduckgo_search(args.query, limit)
        if fallback.get("success"):
            return fallback
    return parsed if isinstance(parsed, dict) else {"success": False, "error": "Web search unavailable"}


def _cmd_web_extract(data: Path, args: argparse.Namespace) -> dict:
    urls = [str(u).strip() for u in (args.urls or ()) if str(u).strip()][:8]
    char_limit = max(1000, min(int(args.char_limit), 60_000))
    _configure_provider_env(data)
    parsed: dict | None = None
    try:
        with contextlib.redirect_stdout(sys.stderr):
            from agent.web_search_registry import get_provider as _wsp_get_provider
            from tools import web_tools

            web_tools._ensure_web_plugins_loaded()
            orig_get = web_tools._get_extract_backend
            pin = web_tools._configured_backend("extract_backend") or web_tools._configured_backend("backend")
            if not pin:
                cand = orig_get()
                prov = _wsp_get_provider(cand) if cand else None
                if prov is None or not prov.supports_extract():
                    keyless = web_tools._keyless_backend()
                    if keyless:
                        web_tools._get_extract_backend = lambda: keyless
            try:
                raw_json = asyncio.run(web_tools.web_extract_tool(urls, char_limit=char_limit))
            finally:
                web_tools._get_extract_backend = orig_get
        loaded = json.loads(raw_json)
        if isinstance(loaded, dict):
            parsed = loaded
            entries = loaded.get("results")
            if isinstance(entries, list) and entries and any(bool(e.get("content")) and not e.get("error") for e in entries if isinstance(e, dict)):
                return loaded
    except Exception:
        parsed = None

    with contextlib.suppress(Exception):
        fallback = _stdlib_fetch_extract(urls, char_limit)
        if any(bool(e.get("content")) for e in fallback.get("results", ())):
            return fallback
    return parsed if isinstance(parsed, dict) else {"success": False, "error": "Web extract unavailable"}


def _cmd_dream(data: Path, args: argparse.Namespace) -> dict:
    conn = json.loads((data / "connection.json").read_text(encoding="utf-8"))
    api_key = (data / "api-key").read_text(encoding="utf-8").strip()
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    if args.run:
        url = f"{conn['data_url'].rstrip('/')}/v1/memories/dream"
        req = urllib.request.Request(
            url,
            data=b"{}",
            headers={"Authorization": f"Bearer {api_key}", "Content-Type": "application/json"},
            method="POST",
        )
        with opener.open(req, timeout=20) as resp:
            return json.loads(resp.read().decode("utf-8"))
    url = f"{conn['data_url'].rstrip('/')}/v1/status"
    req = urllib.request.Request(url, headers={"Authorization": f"Bearer {api_key}"}, method="GET")
    with opener.open(req, timeout=20) as resp:
        payload = json.loads(resp.read().decode("utf-8"))
    return payload.get("memory_review") or payload


def _cmd_briefing(data: Path, args: argparse.Namespace) -> dict:
    if args.regenerate:
        conn = json.loads((data / "connection.json").read_text(encoding="utf-8"))
        api_key = (data / "api-key").read_text(encoding="utf-8").strip()
        url = f"{conn['base_url'].rstrip('/')}/momo/v1/briefing/regenerate"
        req = urllib.request.Request(
            url,
            data=b"{}",
            headers={"Authorization": f"Bearer {api_key}", "Content-Type": "application/json"},
            method="POST",
        )
        opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
        with opener.open(req, timeout=110) as resp:
            return json.loads(resp.read().decode("utf-8"))
    import memory_review
    import morning_briefing
    conv_path = data / "runtime/conversation.sqlite"
    if not conv_path.is_file():
        return {"has_rich_context": False, "pack": {}}
    with contextlib.closing(memory_review.readonly(conv_path)) as db:
        bundle = morning_briefing.build_holistic_briefing_pack(data, db)
    return {"has_rich_context": bundle["has_rich_context"], "pack": bundle["pack"]}


def main() -> int:
    default_data = Path(os.environ["MOMO_DATA_DIR"]) if os.environ.get("MOMO_DATA_DIR") else None
    parser = argparse.ArgumentParser(description="MoMo personal context & memory CLI")
    parser.add_argument("--data-dir", type=Path, default=default_data, required=default_data is None)
    sub = parser.add_subparsers(dest="command", required=True)

    rec_list = sub.add_parser("recordings", help="List synchronized voice recordings")
    illustrations = sub.add_parser('life-illustrations', help='Read actual background illustration states or queue single-slot regeneration')
    illustrations.add_argument('--after', type=int, default=0)
    illustrations.add_argument('--limit', type=int, default=50)
    illustrations.add_argument('--regenerate', default=None, help='Queue regeneration of a specific illustration slot ID via ContextService')
    rec_list.add_argument("--after", default="")
    rec_list.add_argument("--limit", type=int, default=25)

    rec_read = sub.add_parser("recording", help="Read full voice transcript with citations")
    rec_read.add_argument("source_id")
    rec_read.add_argument("--revision", default="")
    rec_read.add_argument("--offset", type=int, default=0)
    rec_read.add_argument("--location-offset", type=int, default=0)
    rec_read.add_argument("--limit", type=int, default=12000)

    rec_reference = sub.add_parser("recording-reference", help="Read selected recording spans for a chat operation")
    rec_reference.add_argument("operation_id")
    rec_reference.add_argument("--offset", type=int, default=0)
    rec_reference.add_argument("--limit", type=int, default=50)

    rec_search = sub.add_parser("search", help="Search voice recording transcripts")
    rec_search.add_argument("query")
    rec_search.add_argument("--limit", type=int, default=20)
    rec_search.add_argument("--alternative-query", action="append", default=[])

    rec_save = sub.add_parser("save-result", help="Save a Markdown note attached to a recording")
    rec_save.add_argument("source_id")
    rec_save.add_argument("--revision", required=True)
    rec_save.add_argument("--title", required=True)
    rec_save.add_argument("--text", required=True)

    phone = sub.add_parser("phone-context", help="Read calendar, reminders, visits, or motion snapshots")
    phone.add_argument("--kind", choices=("calendar", "reminders", "visits", "motion", "all"), default="all")
    phone.add_argument("--after", default="")
    phone.add_argument("--limit", type=int, default=30)

    health = sub.add_parser("health", help="Read HealthKit v2 snapshots across sleep, workouts, activity, vitals, and audio")
    health.add_argument("--category", choices=("all", "overview", "sleep", "workouts", "activity", "vitals", "audio"), default="all")
    health.add_argument("--after", default="")
    health.add_argument("--limit", type=int, default=20)

    conn_p = sub.add_parser("connectors", help="Read and configure read-only external connectors (Feishu personal OAuth & IMAP Email)")
    conn_p.add_argument(
        "--action",
        choices=(
            "status",
            "items",
            "item",
            "sync",
            "configure-email",
            "start-feishu-oauth",
            "disconnect",
            "live-doc",
            "live-thread",
            "live-search",
            "mute",
            "unmute",
            "policy-list",
            "policy-stats",
            "policy-upsert",
            "policy-delete",
        ),
        default="status",
        help="Action to perform on connectors",
    )
    conn_p.add_argument("--connector", choices=("all", "feishu", "email"), default="all")
    conn_p.add_argument("--items", action="store_true", help="List recent synced connector items")
    conn_p.add_argument("--item-id", default="", help="Read full content of a specific connector item")
    conn_p.add_argument("--limit", type=int, default=25)
    conn_p.add_argument("--username", default="", help="Email address for configure-email")
    conn_p.add_argument("--password", default="", help="App password or IMAP authorization code for configure-email")
    conn_p.add_argument("--preset", default="", help="Optional email preset (auto-inferred from email domain if omitted)")
    conn_p.add_argument("--host", default="", help="Optional custom IMAP host")
    conn_p.add_argument("--port", type=int, default=0, help="Optional custom IMAP port (default 993)")
    conn_p.add_argument("--folder", default="", help="Optional IMAP folder (default INBOX)")
    conn_p.add_argument("--sync-days", type=int, default=0, help="Optional lookback days (1-30)")
    conn_p.add_argument("--app-id", default="", help="Feishu app_id for start-feishu-oauth")
    conn_p.add_argument("--app-secret", default="", help="Feishu app_secret for start-feishu-oauth")
    conn_p.add_argument("--domain", choices=("feishu", "lark"), default="feishu", help="Feishu or Lark domain")
    conn_p.add_argument("--open", dest="open_browser", action="store_true", help="Open Feishu OAuth authorize URL in default browser")
    conn_p.add_argument("--url", default="", help="Feishu document URL or token for live-doc")
    conn_p.add_argument("--chat-id", default="", help="Feishu chat_id for live-thread or mute/unmute")
    conn_p.add_argument("--query", default="", help="Keyword for live-search")
    conn_p.add_argument("--target", default="", help="Target chat_id/channel name for mute/unmute")
    conn_p.add_argument("--include-bots", action="store_true", help="Include bot/app messages in live-thread")
    conn_p.add_argument("--rule-json", default="", help="JSON rule object for policy-upsert")
    conn_p.add_argument("--rule-id", default="", help="Rule ID for policy-delete")

    sub.add_parser("situation", help="Read unified situational context across devices, mobility, sleep/vitals, and schedule")

    mem_list = sub.add_parser("memories", help="List shared MoMo memories and user profile facts")
    mem_list.add_argument("--after", default="")
    mem_list.add_argument("--limit", type=int, default=100)

    recall = sub.add_parser("search-memory", help="Rank all Markdown, recordings and chat; add focused query variants for broader recall")
    recall.add_argument("query")
    recall.add_argument("--alternative-query", action="append", default=[])
    recall.add_argument("--kind", choices=("all", "note", "recording", "chat"), default="all")
    recall.add_argument("--limit", type=int, default=10)
    evidence = sub.add_parser("read-memory-evidence", help="Read a search result in full with revision validation and paging")
    evidence.add_argument("id")
    evidence.add_argument("--revision", required=True)
    evidence.add_argument("--offset", type=int, default=0)
    evidence.add_argument("--limit", type=int, default=12000)

    mem_add = sub.add_parser("remember", help="Add an entry to shared MEMORY.md or USER.md")
    mem_add.add_argument("--target", choices=("memory", "user"), default="memory")
    mem_add.add_argument("text")

    mem_del = sub.add_parser("forget", help="Delete a shared memory entry by id")
    mem_del.add_argument("memory_id")

    nb = sub.add_parser("notebook", help="List, read, write, move, or remove pure Markdown (.md) living memory notes")
    nb.add_argument("action", choices=("list", "read", "write", "remove", "move"))
    nb.add_argument("--path", default=None, help="Relative path inside memories/ (supports multi-level folders)")
    nb.add_argument("--to-path", default=None, help="Destination relative path for action=move")
    nb.add_argument("--category", default=None)
    nb.add_argument("--slug", default=None)
    nb.add_argument("--title", default=None)
    nb.add_argument("--content", default=None)
    nb.add_argument("--mode", choices=("replace", "append"), default="replace")
    nb.add_argument("--overwrite", action="store_true")

    exclude = sub.add_parser("exclude-speaker", help="Exclude a known speaker from selected spans or from a timezone-qualified date forward")
    exclude.add_argument("speaker")
    exclude.add_argument("--source-id")
    exclude.add_argument("--span-ids")
    exclude.add_argument("--recorded-from")

    relabel = sub.add_parser("relabel-speakers", help="Propose speaker labels for explicit user confirmation in chat")
    relabel.add_argument("source_id")
    relabel.add_argument("target_speaker")
    relabel.add_argument("--from-speaker", default="")
    relabel.add_argument("--span-ids", default="")
    relabel.add_argument("--is-owner", action="store_true")
    relabel.add_argument("--scope", choices=("cluster", "selection"), default="cluster")
    relabel.add_argument("--reason", required=True)
    relabel.add_argument("--importance", choices=("incidental", "recurring", "task"), default="incidental")
    relabel.add_argument("--benefit", default="")
    relabel.add_argument("--supporting-source", action="append", default=[])

    conv = sub.add_parser("conversation", help="Read recent MoMo chat history")
    conv.add_argument("--limit", type=int, default=20)

    wsearch = sub.add_parser("web-search", help="Search the public web via configured or keyless search providers")
    wsearch.add_argument("query")
    wsearch.add_argument("--limit", type=int, default=5)

    wextract = sub.add_parser("web-extract", help="Extract clean readable text from public web URLs")
    wextract.add_argument("urls", nargs="+")
    wextract.add_argument("--char-limit", type=int, default=15000)

    pim_cmd = sub.add_parser("pim", help="Manage Apple Reminders, Calendar events, and Notes")
    pim_cmd.add_argument("op")
    pim_cmd.add_argument("--args-json", default="{}")

    brief_cmd = sub.add_parser("briefing", help="Inspect holistic morning briefing evidence or trigger live regeneration")
    brief_cmd.add_argument("--regenerate", action="store_true", help="Regenerate today's holistic Morning Briefing via gateway")

    dream_cmd = sub.add_parser("dream", help="Inspect Dream memory curation status or enqueue a manual Dream run")
    dream_cmd.add_argument("--run", action="store_true", help="Enqueue immediate manual Dream curation via ContextService")

    args = parser.parse_args()
    data = args.data_dir.expanduser().resolve()
    handlers = {
        "recordings": _cmd_recordings,
        "life-illustrations": _cmd_life_illustrations,
        "recording": _cmd_recording,
        "recording-reference": _cmd_recording_reference,
        "search": _cmd_search,
        "save-result": _cmd_save_recording_result,
        "phone-context": _cmd_phone_context,
        "health": _cmd_health,
        "situation": _cmd_situation,
        "memories": _cmd_memories,
        "search-memory": _cmd_search_memory,
        "read-memory-evidence": _cmd_read_memory_evidence,
        "remember": _cmd_remember,
        "forget": _cmd_forget,
        "notebook": _cmd_notebook,
        "exclude-speaker": _cmd_exclude_speaker,
        "relabel-speakers": _cmd_relabel_speakers,
        "conversation": _cmd_conversation,
        "web-search": _cmd_web_search,
        "web-extract": _cmd_web_extract,
        "pim": _cmd_pim,
        "briefing": _cmd_briefing,
        "dream": _cmd_dream,
        "connectors": _cmd_connectors,
    }
    try:
        output = handlers[args.command](data, args)
        print(json.dumps(output, ensure_ascii=False, indent=2))
        return 0
    except Exception as error:
        print(json.dumps({"error": str(error)}, ensure_ascii=False), file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
