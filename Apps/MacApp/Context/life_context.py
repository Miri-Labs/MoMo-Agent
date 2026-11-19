"""Unified, directory-agnostic Life Context assembly & cross-source memory recall.

Bridges canonical core memory (`USER.md` + `MEMORY.md`), dynamic BM25+RRF recall across
the entire `memories/` vault + historical recordings + chat (`MemorySearch`), and live
situational awareness (`read_situational_context`) without hardcoding any folder layout.
"""
from __future__ import annotations

from collections import Counter
from contextlib import closing
import datetime as _dt
from pathlib import Path
import re
import time
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

from context_store import ContextStore
from momo_memory import MoMoMemory
from situational_context import read_situational_context

_SPEAKER_TAG_RE = re.compile(r"^\s*\[[^\]]{1,24}\]\s*")
_QUOTED_NAME_RE = re.compile(r"[“\"'‘「『《]([\w\u4e00-\u9fff]{1,16})[”\"'’」』》]")
_STOP_PHRASES = frozenset({
    "说话人", "今天", "昨天", "明天", "现在", "刚刚", "刚才", "然后", "就是", "那个", "这个",
    "什么", "怎么", "为什么", "可以", "没有", "不是", "已经", "如果", "因为", "所以", "但是",
    "我们", "你们", "他们", "自己", "一下", "一点", "一个", "觉得", "感觉", "知道", "看看",
})


def core_memory_snapshot(data_dir: str | Path | None) -> dict[str, str]:
    """Return canonical (`USER.md`, `MEMORY.md`) strings without assuming any subfolder layout."""
    if data_dir is None:
        return {"user": "", "memory": "", "combined": ""}
    try:
        mem = MoMoMemory(Path(data_dir))
        with mem.store() as store:
            user_txt = "\n§\n".join(store.user_entries).strip()
            mem_txt = "\n§\n".join(store.memory_entries).strip()
    except Exception:
        return {"user": "", "memory": "", "combined": ""}
    parts: list[str] = []
    if user_txt:
        parts.append(f"[USER.md]\n{user_txt}")
    if mem_txt:
        parts.append(f"[MEMORY.md]\n{mem_txt}")
    return {
        "user": user_txt,
        "memory": mem_txt,
        "combined": "\n\n".join(parts),
    }


def extract_recall_queries(texts: list[str] | tuple[str, ...], *, max_queries: int = 4) -> list[str]:
    """Extract up to `max_queries` focused search queries from raw chat or transcript lines."""
    cleaned_lines: list[str] = []
    quoted_terms: list[str] = []
    token_counts: Counter[str] = Counter()

    for raw in texts:
        if not isinstance(raw, str) or not raw.strip():
            continue
        for line in raw.splitlines():
            stripped = _SPEAKER_TAG_RE.sub("", line).strip()
            if not stripped:
                continue
            cleaned_lines.append(stripped)
            for qm in _QUOTED_NAME_RE.findall(stripped):
                q_clean = qm.strip()
                if len(q_clean) >= 2 and q_clean not in _STOP_PHRASES and q_clean not in quoted_terms:
                    quoted_terms.append(q_clean)
            for tok in re.findall(r"[\u4e00-\u9fff]{2,6}|[A-Za-z][A-Za-z0-9_-]{2,20}", stripped):
                norm = tok.strip()
                if len(norm) >= 2 and norm.lower() not in _STOP_PHRASES:
                    token_counts[norm] += 1

    queries: list[str] = []

    # 1. If short single message (e.g. user chat turn), keep it directly as primary query.
    joined = " ".join(cleaned_lines).strip()
    if 0 < len(joined) <= 180:
        queries.append(joined)

    # 2. Explicit quoted entities + repeated salient tokens across the passage.
    salient_entities: list[str] = list(quoted_terms[:6])
    for tok, count in token_counts.most_common(18):
        if tok not in salient_entities and (count >= 2 or len(joined) <= 300):
            salient_entities.append(tok)
        if len(salient_entities) >= 10:
            break
    if salient_entities:
        entity_q = " ".join(salient_entities[:8])[:180].strip()
        if entity_q and entity_q not in queries:
            queries.append(entity_q)

    # 3. Representative dense clauses from beginning / middle / end of longer transcripts.
    if len(joined) > 180 and cleaned_lines:
        clauses = [
            c.strip()
            for ln in cleaned_lines
            for c in re.split(r"[。！？!?；;\n]+", ln)
            if len(c.strip()) >= 6
        ]
        if clauses:
            picks = [clauses[0]]
            if len(clauses) >= 3:
                picks.append(clauses[len(clauses) // 2])
            if len(clauses) >= 2:
                picks.append(clauses[-1])
            for pick in picks:
                q = pick[:160].strip()
                if q and q not in queries:
                    queries.append(q)
                if len(queries) >= max_queries:
                    break

    return queries[:max_queries]


def contextual_memory_recall(
    data_dir: str | Path | None,
    texts: list[str] | tuple[str, ...],
    *,
    exclude_source_ids: set[str] | tuple[str, ...] | list[str] = (),
    exclude_window: tuple[float, float] | None = None,
    limit: int = 8,
    max_chars: int = 2400,
) -> list[dict]:
    """Recall relevant Markdown notes, past recordings, and chats via `MemorySearch` without folder hardcoding."""
    if data_dir is None:
        return []
    base = Path(data_dir)
    queries = extract_recall_queries(texts, max_queries=4)
    if not queries:
        return []

    try:
        from memory_search import MemorySearch

        searcher = MemorySearch(base)
        # Blend general cross-source recall with note-focused recall so distilled vault knowledge
        # and raw historical evidence both surface naturally regardless of directory structure.
        all_res = searcher.search(
            queries[0],
            alternative_queries=queries[1:4],
            kind="all",
            limit=min(24, max(12, limit * 3)),
        )
        note_res = searcher.search(
            queries[0],
            alternative_queries=queries[1:4],
            kind="note",
            limit=min(10, max(4, limit)),
        )
    except Exception:
        return []

    excluded_sources = {str(s) for s in exclude_source_ids if s}
    seen_ids: set[str] = set()
    candidates: list[dict] = []

    # Reserve up to half the slots for distilled notes (excluding USER.md/MEMORY.md which are already in core memory),
    # then fill remaining slots with fused cross-source hits (notes, past recordings, user chats).
    note_Quota = max(2, limit // 2)
    ordered_raw: list[dict] = []
    for m in note_res.get("matches") or []:
        m_path = str(m.get("path") or "")
        if m_path not in ("USER.md", "MEMORY.md", "BRIEFING.md") and not m_path.startswith("archive/"):
            ordered_raw.append(m)
            if len(ordered_raw) >= note_Quota:
                break
    ordered_raw.extend(all_res.get("matches") or [])

    used_chars = 0
    tz = _dt.datetime.now().astimezone().tzinfo or _dt.timezone.utc
    try:
        tz = ZoneInfo("Asia/Shanghai") if str(tz) == "CST" else tz
    except ZoneInfoNotFoundError:
        pass

    for match in ordered_raw:
        doc_id = str(match.get("id") or "")
        if not doc_id or doc_id in seen_ids:
            continue
        kind = match.get("kind")
        match_path = str(match.get("path") or "")
        if kind == "note" and (match_path in ("USER.md", "MEMORY.md") or match_path.startswith("archive/")):
            continue
        if kind == "recording":
            sid = str(match.get("source_id") or "")
            rec_at = match.get("recorded_at")
            if sid and sid in excluded_sources:
                continue
            if (
                exclude_window is not None
                and isinstance(rec_at, (int, float))
                and exclude_window[0] - 5.0 <= float(rec_at) <= exclude_window[1] + 5.0
            ):
                continue
        if kind == "chat" and match.get("basis") == "assistant_statement":
            # Assistant replies are never independent evidence when user statements/notes exist.
            continue

        snippet = str(match.get("text") or match.get("snippet") or "").strip()
        if not snippet:
            continue
        clipped = snippet[:420]
        if used_chars + len(clipped) > max_chars and candidates:
            break

        seen_ids.add(doc_id)
        entry: dict = {
            "id": doc_id,
            "revision": match.get("revision"),
            "kind": kind,
            "basis": match.get("basis"),
            "snippet": clipped,
        }
        if kind == "note" and match.get("path"):
            entry["path"] = match["path"]
        elif kind == "recording":
            entry["source_id"] = match.get("source_id")
            if isinstance(match.get("recorded_at"), (int, float)):
                entry["recorded_at_local"] = _dt.datetime.fromtimestamp(float(match["recorded_at"]), tz).strftime("%Y-%m-%d %H:%M")
            if match.get("speaker"):
                entry["speaker"] = match["speaker"]
        elif kind == "chat" and isinstance(match.get("created_at"), (int, float)):
            entry["created_at_local"] = _dt.datetime.fromtimestamp(float(match["created_at"]), tz).strftime("%Y-%m-%d %H:%M")

        candidates.append(entry)
        used_chars += len(clipped)
        if len(candidates) >= limit:
            break

    return candidates


def ambient_situation_digest(
    data_dir: str | Path | None,
    *,
    store: ContextStore | None = None,
    now: float | None = None,
) -> dict | None:
    """Build a compact, freshness-tagged situational digest (time, place, physiology, schedule, devices)."""
    if data_dir is None and store is None:
        return None
    now_ts = time.time() if now is None else float(now)

    def _build(cstore: ContextStore) -> dict | None:
        sit = read_situational_context(cstore, data_dir=data_dir, now=now_ts)
        mobility = sit.get("mobility_and_place") or {}
        body = sit.get("body_and_sleep") or {}
        sched = sit.get("schedule") or {}
        devs = sit.get("devices") or {}

        has_signal = bool(
            mobility.get("visit")
            or mobility.get("motion")
            or body.get("latest_sleep")
            or (body.get("today_activity") or {}).get("steps") is not None
            or sched.get("upcoming_events")
            or sched.get("due_reminders")
            or devs.get("phone")
            or devs.get("watch")
        )
        if not has_signal:
            return None

        visit = mobility.get("visit")
        place_summary = None
        if isinstance(visit, dict):
            place_summary = {
                **({"title": visit["title"]} if visit.get("title") else {}),
                "latitude": round(float(visit["latitude"]), 5),
                "longitude": round(float(visit["longitude"]), 5),
                "accuracy_m": round(float(visit["accuracy"]), 1),
                "ongoing": bool(visit.get("ongoing")),
                "start_local": visit.get("start_local"),
                "end_local": visit.get("end_local"),
                "source_name": visit.get("source_name"),
            }

        sleep = body.get("latest_sleep")
        sleep_summary = None
        if isinstance(sleep, dict):
            sleep_summary = {
                "window": f"{sleep.get('bedtime_local')}–{sleep.get('wake_time_local')}",
                "asleep_hours": sleep.get("asleep_hours"),
                "deep_hours": (sleep.get("stages_hours") or {}).get("deep"),
                "rem_hours": (sleep.get("stages_hours") or {}).get("rem"),
                "age_hours": round(float(sleep.get("age_seconds") or 0.0) / 3600.0, 1),
            }

        vitals = body.get("vitals") or {}
        fresh_vitals = {
            k: f"{v['value']}{v['unit']}"
            for k, v in vitals.items()
            if isinstance(v, dict) and not v.get("stale") and k in ("resting_heart_rate", "hrv_sdnn", "heart_rate")
        }

        return {
            "clock": {
                "iso_local": sit["clock"]["iso_local"],
                "weekday_zh": sit["clock"]["weekday_zh"],
                "timezone": sit["clock"]["timezone"],
            },
            "concise_summary": sit.get("concise_summary") or "",
            **({"place": place_summary} if place_summary else {}),
            **({"motion": mobility["motion"]["activity"]} if isinstance(mobility.get("motion"), dict) else {}),
            **({"latest_sleep": sleep_summary} if sleep_summary else {}),
            **({"today_steps": int(round(body["today_activity"]["steps"]))} if (body.get("today_activity") or {}).get("steps") is not None else {}),
            **({"vitals": fresh_vitals} if fresh_vitals else {}),
            **(
                {
                    "upcoming_events_12h": [
                        {
                            "title": e["title"],
                            "when": "全天" if e.get("all_day") else f"{e.get('start_local')}–{e.get('end_local')}",
                            "ongoing": bool(e.get("ongoing")),
                        }
                        for e in (sched.get("upcoming_events") or [])[:6]
                    ]
                }
                if sched.get("upcoming_events")
                else {}
            ),
            **(
                {
                    "due_reminders": [
                        {"title": r["title"], "due_local": r.get("due_local"), "overdue": bool(r.get("overdue"))}
                        for r in (sched.get("due_reminders") or [])[:6]
                    ]
                }
                if sched.get("due_reminders")
                else {}
            ),
        }

    if store is not None:
        return _build(store)

    ctx_db = Path(data_dir) / "context" / "context.sqlite"
    if not ctx_db.is_file():
        return None
    try:
        with closing(ContextStore(ctx_db.parent)) as cstore:
            return _build(cstore)
    except Exception:
        return None


def build_life_context_pack(
    data_dir: str | Path | None,
    *,
    texts: list[str] | tuple[str, ...] = (),
    exclude_source_ids: set[str] | tuple[str, ...] | list[str] = (),
    exclude_window: tuple[float, float] | None = None,
    include_core_memory: bool = True,
    include_situation: bool = True,
    recall_limit: int = 6,
    max_recall_chars: int = 2200,
    now: float | None = None,
) -> dict:
    """Assemble unified Life Context (core memory + dynamic cross-source recall + live situation)."""
    out: dict = {}
    if include_core_memory:
        core = core_memory_snapshot(data_dir)
        if core["user"]:
            out["user_profile"] = core["user"]
        if core["memory"]:
            out["core_memory"] = core["memory"]
    if texts and recall_limit > 0:
        recalled = contextual_memory_recall(
            data_dir,
            texts,
            exclude_source_ids=exclude_source_ids,
            exclude_window=exclude_window,
            limit=recall_limit,
            max_chars=max_recall_chars,
        )
        if recalled:
            out["recalled_context"] = recalled
    if include_situation:
        sit = ambient_situation_digest(data_dir, now=now)
        if sit:
            out["ambient_situation"] = sit
    return out
