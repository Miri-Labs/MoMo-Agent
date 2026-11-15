"""Scoped speaker suggestions. Consent enters only through an authenticated chat POST."""
import datetime
import json
import re
import time
import unicodedata

from context_store import Conflict, canonical, digest
from transcript_speakers import classify_transcript_span

DECISION = re.compile(r"(确认标注|暂不标注)\s+([1-9][0-9]{0,15})")
IMPORTANCE = {"incidental": 0, "recurring": 1, "task": 2}


def _person_key(name):
    # Used only to avoid repeat questions, never to merge identities or voiceprints.
    return unicodedata.normalize("NFKC", name).strip().casefold()


def _worth_asking(store, item):
    importance = item.get("importance", "incidental")
    if importance not in ("recurring", "task") or not item.get("benefit"):
        return False
    if importance == "task":
        return True
    days = set()
    for source_id in item.get("supporting_source_ids", []):
        try:
            _, spans, _ = _snapshot(store, source_id)
        except (ValueError, KeyError):
            continue
        times = [s["recorded_at"] for s in spans if s.get("recorded_at")]
        if times:
            days.add(datetime.datetime.fromtimestamp(min(times)).date())
    return len(days) >= 2


def _snapshot(store, source_id):
    if store.db.execute("SELECT 1 FROM memory_exclusions WHERE source_id=?", (source_id,)).fetchone():
        raise Conflict("Automatic memory for this recording was disabled by a forget request")
    row = store.source(source_id)
    spans = store._apply_speaker_overrides(source_id, json.loads(row["payload"]).get("spans", []))
    stamp = digest(canonical([row["revision"], row["updated"], spans]))
    return row, spans, stamp


def propose(store, source_id, target_speaker, *, is_owner=False, from_speaker=None,
            span_ids=None, scope="selection", reason="", importance="incidental", benefit="",
            supporting_source_ids=None):
    target = "我" if is_owner else str(target_speaker or "").strip()
    if (type(is_owner) is not bool or not target or len(target) > 80 or target == "身份待确认"
            or any(c in target for c in "\r\n[]") or target == "我" and not is_owner):
        raise ValueError("A specific speaker name and boolean is_owner are required")
    if scope not in ("selection", "cluster") or not isinstance(reason, str) or not reason.strip() or len(reason) > 400:
        raise ValueError("A valid scope and evidence-based reason (1-400 chars) are required")
    if span_ids is not None and (not isinstance(span_ids, list) or any(not isinstance(s, str) for s in span_ids)):
        raise ValueError("span_ids must be a list of IDs")
    if (not isinstance(importance, str) or importance not in IMPORTANCE
            or not isinstance(benefit, str) or len(benefit) > 80 or "\n" in benefit or "\r" in benefit):
        raise ValueError("A valid importance and concise benefit (<=80 chars) are required")
    if supporting_source_ids is not None and (not isinstance(supporting_source_ids, list)
            or len(supporting_source_ids) > 10 or any(not isinstance(s, str) for s in supporting_source_ids)):
        raise ValueError("supporting_source_ids must contain at most 10 recording IDs")
    wanted = set(s.lower() for s in (span_ids or []))
    label = str(from_speaker or "").strip().strip("[]")
    with store.write():
        row, spans, stamp = _snapshot(store, source_id)
        if scope == "cluster":
            if not re.fullmatch(r"(?:说话人\s*|speaker\s*)[0-9]+", label, re.I):
                raise ValueError("Only an anonymous cluster can use cluster scope; otherwise give exact span_ids")
            selected = [s for s in spans if classify_transcript_span(s)[0] == label]
        else:
            if not wanted:
                raise ValueError("selection requires exact span_ids")
            selected = [s for s in spans if s["id"].lower() in wanted]
        if not selected or (wanted and not wanted <= {s["id"].lower() for s in selected}):
            raise ValueError("No matching spans, or a selected span is missing")
        if any(s.get("speaker_attribution_excluded") for s in selected):
            raise Conflict("Speaker identity was rejected; do not infer another identity for these spans")
        if all(classify_transcript_span(s)[0] == target and s.get("is_owner") is is_owner for s in selected):
            return {"success": True, "changed": False, "state": "already_labeled"}
        # Freeze exact turns even for anonymous clusters: later turns never inherit consent.
        ids = [s["id"].lower() for s in selected]
        args = dict(source_id=source_id, target_speaker=target, is_owner=is_owner,
                    span_ids=ids, scope="selection", reason=reason.strip())
        evidence_key = digest(canonical([source_id, sorted(selected, key=lambda s: s["id"]), target, is_owner]))
        rejected = store.db.execute("""SELECT id FROM speaker_proposals WHERE source_id=? AND state='rejected'
            AND json_extract(payload,'$.evidence_key')=?""", (source_id, evidence_key)).fetchone()
        if rejected:
            return {"success": True, "changed": False, "proposal_id": rejected["id"], "state": "rejected"}
        fingerprint = digest(canonical([source_id, stamp, sorted(ids), target, is_owner]))
        times = [s["recorded_at"] for s in selected if s.get("recorded_at")]
        display = dict(args=args, evidence_key=evidence_key, source_revision=row["revision"], title=json.loads(row["payload"]).get("title") or "录音",
                       start=min(times) if times else None, end=max(times) if times else None,
                       labels=sorted({classify_transcript_span(s)[0] or "未标注" for s in selected}),
                       importance=importance, benefit=benefit.strip(),
                       supporting_source_ids=list(dict.fromkeys([source_id, *(supporting_source_ids or [])])))
        store.db.execute("""INSERT OR IGNORE INTO speaker_proposals
            (fingerprint,source_id,source_stamp,payload,created) VALUES(?,?,?,?,?)""",
            (fingerprint, source_id, stamp, canonical(display), time.time()))
        proposal = store.db.execute("SELECT * FROM speaker_proposals WHERE fingerprint=?", (fingerprint,)).fetchone()
        # New useful evidence can promote a quiet candidate, without changing its consent scope.
        if proposal["state"] == "pending" and proposal["delivered"] is None:
            store.db.execute("UPDATE speaker_proposals SET payload=? WHERE id=?", (canonical(display), proposal["id"]))
        eligible = _worth_asking(store, display)
    return {"success": True, "changed": False, "proposal_id": proposal["id"], "state": proposal["state"],
            "eligible_for_question": eligible,
            "guidance": "No labels or voiceprints changed. Candidates are quiet by default. Only a useful recurring person "
                        "or an identity needed for a real current task may be selected for one concise question; at most once per 24 hours. "
                        "Do not ask separately, list every candidate in a briefing, or treat pending as consent. No answer means stop asking."}


def _current(store, proposal):
    try:
        return _snapshot(store, proposal["source_id"])[2] == proposal["source_stamp"]
    except (ValueError, KeyError):
        return False


def next_question(store, now=None):
    """Select one useful question, never drain a queue of everyone the user meets."""
    now = time.time() if now is None else now
    candidates = []
    unanswered = store.db.execute("""SELECT 1 FROM speaker_proposals
        WHERE delivered IS NOT NULL AND decision_operation IS NULL LIMIT 1""").fetchone() is not None
    for row in store.db.execute("SELECT * FROM speaker_proposals WHERE state='pending' ORDER BY id").fetchall():
        if not _current(store, row):
            store.db.execute("UPDATE speaker_proposals SET state='obsolete' WHERE id=? AND state='pending'", (row["id"],))
            continue
        if row["delivered"] is not None:
            continue
        item = json.loads(row["payload"])
        if now - row["created"] > 7 * 86400 or not _worth_asking(store, item):
            continue
        candidates.append((row, item))
    latest = store.db.execute("SELECT MAX(delivered) FROM speaker_proposals").fetchone()[0]
    if unanswered or latest is not None and now - latest < 86400:
        return None
    recent = [json.loads(row["payload"])["args"] for row in store.db.execute(
        "SELECT payload FROM speaker_proposals WHERE delivered>?", (now - 30 * 86400,))]
    recent_names = {_person_key(args["target_speaker"]) for args in recent}
    candidates.sort(key=lambda pair: (IMPORTANCE[pair[1]["importance"]], pair[0]["created"]), reverse=True)
    for row, item in candidates:
        args = item["args"]
        if (_person_key(args["target_speaker"]) in recent_names or any(
                args["source_id"] == prior["source_id"] and set(args["span_ids"]) & set(prior["span_ids"])
                for prior in recent)):
            continue
        stamp = datetime.datetime.fromtimestamp(item["start"]).astimezone().strftime("%m月%d日 %H:%M") if item["start"] else item["title"]
        if item["end"] and item["end"] != item["start"]:
            stamp += "–" + datetime.datetime.fromtimestamp(item["end"]).astimezone().strftime("%m月%d日 %H:%M")
        source = json.loads(store.source(row["source_id"])["payload"])
        url = f"momoagent://source/{source['session_id']}/{args['span_ids'][0]}?version={source['version']}&generation={source['generation']}"
        message = (f"[{stamp}这段声音]({url})是「{args['target_speaker']}」吗？{item['benefit']}\n\n"
                   f"确认后仅标注这次录音的 {len(args['span_ids'])} 段发言，并同步手机声纹。\n\n"
                   f"回复「确认标注 {row['id']}」即可；不接受请回复「暂不标注 {row['id']}」。")
        return {"id": row["id"], "key": f"speaker-proposal:{row['id']}", "message": message}
    return None


def decide(store, proposal_id, approve, operation_id):
    """Called by chat ingress, never exposed as a model tool or CLI command."""
    with store.write():
        row = store.db.execute("SELECT * FROM speaker_proposals WHERE id=?", (proposal_id,)).fetchone()
        if not row or row["delivered"] is None:
            raise Conflict("标注建议尚未展示，请先查看具体人物和录音范围。")
        if row["state"] in ("applied", "rejected"):
            return json.loads(row["result"])
        if row["state"] != "pending" or not _current(store, row):
            store.db.execute("UPDATE speaker_proposals SET state='obsolete' WHERE id=?", (proposal_id,))
            result = {"success": False, "changed": False, "state": "obsolete", "message": "录音或说话人信息已变化，这条建议已失效，需要重新核对。"}
        elif not approve:
            result = {"success": True, "changed": False, "state": "rejected", "message": "已保留原标注，不会重复询问这条建议。"}
        else:
            result = store._relabel_speakers(**json.loads(row["payload"])["args"])
            result["state"] = "applied" if result.get("success") else "obsolete"
            result["message"] = (f"已标注 {result.get('updated_span_count', 0)} 段发言；手机同步待确认。" if result.get("success") else "未能应用标注，请重新核对录音。")
        store.db.execute("UPDATE speaker_proposals SET state=?,result=?,decision_operation=? WHERE id=?",
                         (result["state"], canonical(result), operation_id, proposal_id))
        return result
