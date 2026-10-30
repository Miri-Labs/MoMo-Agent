"""Read-only controlled UI evidence check. Run with the App stopped; no SDK/App/API calls.

uv run Tests/Support/verify-controlled-ui-ledger.py --container /absolute/App/Data \
  --run-id UUID --scenario stop-regenerate-retry --output /outside/container/report.json

Schema sources: PhoneControlledStreamUITest.swift (v2), AgentSessionPolicy.swift,
AgentTranscriptHistory.swift, AssistantPresentationState.swift, MoMoArchive SQLite.swift,
and pinned pi-durable 1.2.0 storage/sqlite/migrations.js (schema 1).
Only the named UUID under Library/Caches/MoMoAgentUITests is read. SQLite uses
mode=ro and query_only; no checkpoint or migration is executed. SQLite may update
its shared-memory coordination file; database/WAL and JSON bytes are checked stable.
Exit 0 means all requested checks passed, 1 means failed, 2 means unchecked evidence.
Raw prompts, source text, responses, keys, and arbitrary exception messages are never output.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import math
from pathlib import Path
import re
import sqlite3
import stat
import uuid

QUESTION = "Summarize only this selected timeline and cite its source."
DRAFT = "Keep this unsent draft."
SCENARIOS = ("stop-regenerate-retry", "interrupted-citation", "cancel-before-body")
REQUEST_COUNTS = dict(zip(SCENARIOS, (4, 2, 1)))
SUPPORT = Path("Library/Application Support/MoMoAgent")
MAX_JSON = 10_000_000


class EvidenceError(Exception):
    """Only static, non-payload error codes may be passed here."""


def require(condition, code):
    if not condition:
        raise EvidenceError(code)


def uid(value):
    require(isinstance(value, str), "invalid_uuid")
    try:
        return str(uuid.UUID(value)).upper()
    except ValueError:
        raise EvidenceError("invalid_uuid") from None


def number(value):
    return type(value) in (int, float) and math.isfinite(value)


def text(message):
    content = message.get("content")
    if isinstance(content, str):
        return content
    require(isinstance(content, list), "unsupported_message_content")
    return "".join(block["text"] for block in content
                   if isinstance(block, dict) and block.get("type") == "text" and isinstance(block.get("text"), str))


def reference(value):
    require(isinstance(value, dict) and set(value) == {"sessionID", "spanID", "transcriptVersion", "generation"},
            "invalid_source_reference_shape")
    require(type(value["transcriptVersion"]) is int and value["transcriptVersion"] > 0
            and type(value["generation"]) is int and value["generation"] >= 0, "invalid_source_reference_version")
    return (uid(value["sessionID"]), uid(value["spanID"]), value["transcriptVersion"], value["generation"])


def citation(ref):
    return f"momoagent://source/{ref[0]}/{ref[1]}?version={ref[2]}&generation={ref[3]}"


class Reader:
    def __init__(self, root):
        self.root = root
        self.fingerprints = {}

    def path(self, relative, required=True):
        relative = Path(relative)
        require(not relative.is_absolute() and ".." not in relative.parts, "path_outside_isolation")
        path = self.root / relative
        for item in (path, *path.parents):
            if item == self.root.parent:
                break
            require(not item.is_symlink(), "symlink_in_evidence_path")
        if required:
            require(path.is_file() and stat.S_ISREG(path.stat().st_mode), "missing_regular_evidence_file")
        return path

    @staticmethod
    def fingerprint(path):
        if not path.exists():
            return None
        require(path.is_file() and not path.is_symlink(), "invalid_evidence_file")
        require(path.stat().st_size <= 128 * 1024 * 1024, "evidence_file_too_large")
        digest = hashlib.sha256()
        with path.open("rb") as stream:
            for block in iter(lambda: stream.read(1024 * 1024), b""):
                digest.update(block)
        return {"bytes": path.stat().st_size, "sha256": digest.hexdigest()}

    def track(self, relative, required=True):
        path = self.path(relative, required)
        self.fingerprints[str(relative)] = self.fingerprint(path)
        return path

    def json(self, relative, limit=MAX_JSON):
        path = self.track(relative)
        require(path.stat().st_size <= limit, "json_evidence_too_large")
        data = path.read_bytes()
        require(len(data) <= limit, "json_evidence_too_large")
        value = json.loads(data)
        require(isinstance(value, dict), "json_object_required")
        return value

    def database(self, relative, expected):
        path = self.track(relative)
        self.track(str(relative) + "-wal", required=False)
        connection = sqlite3.connect(path.as_uri() + "?mode=ro", uri=True, timeout=2)
        try:
            connection.execute("PRAGMA query_only=ON")
            connection.execute("PRAGMA trusted_schema=OFF")
            connection.execute("BEGIN")
            require(connection.execute("PRAGMA quick_check").fetchall() == [("ok",)], "database_integrity")
            tables = {row[0] for row in connection.execute("SELECT name FROM sqlite_schema WHERE type='table'")}
            for table, columns in expected.items():
                require(table in tables, "unsupported_database_schema")
                actual = {row[1] for row in connection.execute(f'PRAGMA table_info("{table}")')}
                require(set(columns) <= actual, "unsupported_database_columns")
            return connection
        except Exception:
            connection.close()
            raise

    def stable(self):
        return all(self.fingerprint(self.path(name, required=False)) == before
                   for name, before in self.fingerprints.items())


def records(connection, table):
    # Table names are the fixed schema allowlist supplied below, never data-derived SQL.
    rows = connection.execute(f'SELECT id,record FROM "{table}" ORDER BY id LIMIT 4097').fetchall()
    require(len(rows) <= 4096, "too_many_durable_records")
    result = []
    for identifier, raw in rows:
        require(isinstance(raw, str) and len(raw.encode()) <= 2 * 1024 * 1024, "durable_record_too_large")
        record = json.loads(raw)
        require(isinstance(record, dict) and record.get("id") == identifier, "durable_record_identity_mismatch")
        result.append(record)
    return result


def check_ledger(r, ledger, run_id, scenario):
    require(ledger.get("schemaVersion") == 2 and uid(ledger.get("runID")) == run_id
            and ledger.get("scenario") == scenario, "ledger_identity_or_schema")
    requests, events = ledger.get("requests"), ledger.get("events")
    require(isinstance(requests, list) and isinstance(events, list) and len(events) <= 256, "ledger_collections")
    count = REQUEST_COUNTS[scenario]
    r.check("request_count", len(requests) == count)
    require(len(requests) == count, "request_count_prevents_identity_check")
    require(all(isinstance(item, dict) and type(item.get("sequence")) is int
                and type(item.get("appAttempt")) is int and item["appAttempt"] >= 0 for item in requests),
            "invalid_request_ledger_shape")
    r.check("relaunch_did_not_add_requests", ledger.get("launches") == 2
            and ledger.get("launchRequestCounts") == [0, count]
            and ledger["launchRequestCounts"][-1] == len(requests))
    r.check("request_sequence", [item.get("sequence") for item in requests] == list(range(1, count + 1)))
    sessions = [uid(item.get("sessionID")) for item in requests]
    operations = [uid(item.get("operationID")) for item in requests]
    r.check("single_session", len(set(sessions)) == 1)
    r.check("operation_identity", operations[0] != operations[1] == operations[2] == operations[3]
            if count == 4 else len(set(operations)) == 1)
    r.check("app_attempts", [item.get("appAttempt") for item in requests] ==
            ([0, 0, 0, 1] if count == 4 else [0, 1] if count == 2 else [0]))
    if count == 4:
        target = requests[1].get("replacingTurn")
        r.check("regeneration_target_consistency", isinstance(target, str) and re.fullmatch(r"[1-9][0-9]*:0", target) is not None
                and all(item.get("replacingTurn") == target for item in requests[1:])
                and requests[0].get("replacingTurn") is None)
    r.check("request_body_hashes", all(isinstance(item.get("bodySHA256"), str)
            and re.fullmatch(r"[0-9a-f]{64}", item["bodySHA256"]) for item in requests))
    r.check("request_times_ordered", all(number(item.get("startedAt")) for item in requests)
            and [item["startedAt"] for item in requests] == sorted(item["startedAt"] for item in requests))
    allowed = {"request", "headers-200", "headers-503", "body", "cancelled", "http-503", "completed", "injected-stream-failure"}
    require(all(isinstance(e, dict) for e in events), "invalid_event")
    r.check("no_rejection_limit_or_unknown_events", all(e.get("kind") in allowed for e in events))
    r.check("event_sequences_and_times", bool(events) and all(type(e.get("sequence")) is int
            and 1 <= e["sequence"] <= count and number(e.get("at")) for e in events)
            and [e["at"] for e in events] == sorted(e["at"] for e in events))
    for seq in range(1, count + 1):
        group = [e for e in events if e.get("sequence") == seq]
        kinds = [e.get("kind") for e in group]
        if scenario == SCENARIOS[2]:
            r.check(f"stream_{seq}_ordered_terminal", kinds == ["request", "headers-200", "cancelled"]
                    and all(type(e.get("byteCount")) is int and e["byteCount"] == 0 for e in group))
            continue
        is_http_failure = count == 4 and seq in (2, 3)
        # Pi cancels non-success response bodies after headers. URLProtocol may
        # observe that cleanup before its normal 503 completion callback.
        terminals = {"http-503", "cancelled"} if is_http_failure else {
            "cancelled" if seq == 1 and count == 4 else "injected-stream-failure" if seq == 1 else "completed"}
        header = "headers-503" if is_http_failure else "headers-200"
        valid = len(kinds) >= 4 and kinds[:2] == ["request", header] and kinds[-1] in terminals
        valid = valid and kinds.count("request") == kinds.count(header) == sum(kinds.count(t) for t in terminals) == 1
        valid = valid and all(kind == "body" for kind in kinds[2:-1])
        valid = valid and all(type(e.get("byteCount")) is int and e["byteCount"] > 0 for e in group[2:-1])
        r.check(f"stream_{seq}_ordered_terminal", valid)
    return sessions[0], operations


def check_pi(r, reader, session_id, ledger):
    before_body = ledger["scenario"] == SCENARIOS[2]
    directory = SUPPORT / "Agent" / session_id
    metadata = reader.json(directory / "session.json", 512 * 1024)
    r.check("session_final_operation", uid(metadata.get("id")) == session_id
            and uid(metadata.get("operationID")) == uid(ledger["requests"][-1]["operationID"])
            and metadata.get("attempt") == (0 if before_body else 1)
            and metadata.get("state") == ("cancelled" if before_body else "finished")
            and (not before_body or (metadata.get("failure") is None and metadata.get("replacingTurn") is None))
            and metadata.get("durableStoreCreated") is True and metadata.get("requestText") == QUESTION)
    presentation = reader.json(SUPPORT / "assistant-presentation.json")
    r.check("presentation_session_and_draft", presentation.get("version") == 1
            and uid(presentation.get("selectedSessionID")) == session_id and presentation.get("draft") == DRAFT
            and presentation.get("pending") == [])
    schema = {"durable_schema": ["singleton", "version"], "entries": ["id", "record", "conversation_id", "head", "commit_seq"],
              "submissions": ["id", "record", "request_id", "status"], "tasks": ["id", "record", "status"], "conversations": ["id", "record"]}
    db = reader.database(directory / "pi.sqlite", schema)
    try:
        require(db.execute("SELECT version FROM durable_schema WHERE singleton=1").fetchall() == [(1,)], "unsupported_pi_schema_version")
        entries, submissions, tasks, conversations = [records(db, table) for table in ("entries", "submissions", "tasks", "conversations")]
    finally:
        db.close()
    require(len(conversations) == 1 and conversations[0].get("id") == 1 and not conversations[0].get("parent")
            and all(e.get("conversationId") == 1 and e.get("head") is None for e in entries), "unsupported_fork_or_head_projection")
    r.check("pi_tasks_and_submissions_settled", bool(tasks) and all(t.get("state", {}).get("status") == "terminal" for t in tasks)
            and bool(submissions) and all(s.get("status") in ("done", "unanswered") for s in submissions))
    request_ids = []
    for item in ledger["requests"]:
        key = uid(item["operationID"]) + (f':retry:{item["appAttempt"]}' if item["appAttempt"] else "")
        if key not in request_ids:
            request_ids.append(key)
    inputs = [s for s in submissions if s.get("type") == "input"]
    admissions_settled = (all(s.get("status") == "unanswered" and s.get("reason") == "aborted"
                              and s.get("answer") is None for s in inputs) if before_body else
                          all(s.get("status") == "unanswered" for s in inputs[:-1]) and bool(inputs)
                          and inputs[-1].get("status") == "done")
    r.check("durable_admissions_match_operations", len(inputs) == len(request_ids)
            and [s.get("requestId") for s in inputs] == request_ids
            and admissions_settled)
    require(len(inputs) == len(request_ids), "cannot_bind_durable_inputs")
    by_id = {e["id"]: e for e in entries}
    original = by_id.get(inputs[0].get("entry"))
    require(original is not None, "missing_original_question")
    turn_id = f'{original["id"]}:0'
    if ledger["scenario"] == SCENARIOS[0]:
        r.check("regenerate_binds_original_turn", all(item.get("replacingTurn") == turn_id for item in ledger["requests"][1:])
                and metadata.get("replacingTurn") == turn_id)
        diagnostics = []
        for entry in entries:
            if inputs[1]["entry"] < entry["id"] < inputs[2]["entry"] and entry.get("kind") == "pi.assistant":
                for message in entry.get("model") or []:
                    if message.get("role") == "assistant" and message.get("stopReason") == "error":
                        diagnostics.extend(d for d in message.get("diagnostics") or []
                                           if isinstance(d, dict) and d.get("type") == "pi.transport_failure.v1")
        details = diagnostics[0].get("details") if len(diagnostics) == 1 else None
        r.check("regeneration_503_failure_is_durable", isinstance(details, dict)
                and details.get("kind") == "http" and details.get("httpStatus") == 503
                and details.get("httpAttempts") == 2 and isinstance(details.get("context"), dict)
                and details["context"].get("requestIDs") == [request_ids[1]])
    turns = []
    current = None
    raw_user_count = 0
    for entry in entries:
        if entry.get("kind") in ("pi.system", "momoagent.context"):
            continue
        model = entry.get("model") or []
        require(isinstance(model, list), "unsupported_model_messages")
        if model and model[0].get("role") == "user":
            raw_user_count += 1
            require(len(model) == 1 and text(model[0]) == QUESTION, "unexpected_durable_question")
            data = entry.get("data") or {}
            replacement = data.get("replacingTurn")
            if replacement:
                target = next((t for t in turns if t["id"] == replacement), None)
                require(target is not None and entry.get("kind") == "momoagent.replacement", "orphan_replacement")
                target["replies"] = []; current = target
            else:
                require(entry.get("kind") == "momoagent.input", "unsupported_user_entry_kind")
                current = {"id": f'{entry["id"]}:0', "question": entry, "replies": []}; turns.append(current)
        elif current is not None and model:
            current["replies"].append(entry)
    r.check("one_logical_user_question", raw_user_count == len(request_ids) and len(turns) == 1 and turns[0]["id"] == turn_id)
    r.metrics["rawUserInputs"] = raw_user_count
    r.metrics["logicalUserQuestions"] = len(turns)
    r.metrics["durableInputAdmissions"] = len(inputs)
    original_data = original.get("data") or {}
    references = {reference(s["reference"]) for s in ledger["sources"]}
    r.check("selected_sources_preserved", {reference(s) for s in original_data.get("selectedSources", [])} == references
            and {reference(s) for s in metadata.get("selectedSources", [])} == references
            and all({reference(s) for s in (by_id.get(item.get("entry"), {}).get("data") or {}).get("selectedSources", [])} == references for item in inputs))
    if before_body:
        assistants = [m for e in entries for m in e.get("model") or [] if m.get("role") == "assistant"]
        r.check("cancelled_before_body_has_no_assistant_content", all(not text(m).strip()
                and m.get("stopReason") == "aborted" for m in assistants))
        r.metrics["assistantMessages"] = len(assistants)
        return
    answer = by_id.get(inputs[-1].get("answer"), {})
    messages = answer.get("model") or []
    final = messages[0] if messages else {}
    r.check("final_answer_is_durable_and_projected", answer in turns[0]["replies"] if turns else False)
    r.check("final_answer_completed_with_formal_citation", final.get("role") == "assistant"
            and final.get("stopReason") == "stop" and not final.get("errorMessage")
            and any(citation(ref) in text(final) for ref in references))
    first_end = inputs[1].get("entry")
    partial = [e for e in entries if original["id"] < e["id"] < first_end and e.get("kind") == "pi.assistant"]
    expected_stop = "aborted" if ledger["scenario"] == SCENARIOS[0] else "error"
    r.check("partial_answer_retained_in_immutable_history", any((e.get("model") or [{}])[0].get("stopReason") == expected_stop
            and bool(text(e["model"][0]).strip()) for e in partial))


def check_sources(r, reader, ledger):
    source_values = ledger.get("sources")
    require(isinstance(source_values, list) and len(source_values) == 2, "two_sources_required")
    refs = [reference(s["reference"]) for s in source_values]
    require(len(set(refs)) == 2 and len({s[0] for s in refs}) == 2, "distinct_source_recordings_required")
    r.check("request_citations_are_formal_source_references", all(req.get("citationURL") in {citation(ref) for ref in refs}
            for req in ledger["requests"]))
    db = reader.database(SUPPORT / "archive.sqlite", {
        "sessions": ["id", "generation", "deleted", "transcript_version", "projection_blocked"],
        "transcript_versions": ["session_id", "version", "document"],
        "chunks": ["id", "session_id", "manifest", "manifest_hash", "relative_path", "retention", "receipt_applied"]})
    referenced_chunks = set()
    source_rows = []
    try:
        for index, (source, ref) in enumerate(zip(source_values, refs), start=1):
            rows = db.execute("SELECT generation,deleted,transcript_version,projection_blocked FROM sessions WHERE id=?", (ref[0],)).fetchall()
            require(len(rows) == 1, "missing_source_recording")
            r.check(f"source_{index}_version_generation_unchanged", rows[0] == (ref[3], 0, ref[2], 0))
            documents = db.execute("SELECT document FROM transcript_versions WHERE session_id=? AND version=?", (ref[0], ref[2])).fetchall()
            require(len(documents) == 1 and len(documents[0][0]) <= MAX_JSON, "missing_source_transcript")
            document = json.loads(documents[0][0])
            require(uid(document.get("sessionID")) == ref[0] and document.get("version") == ref[2]
                    and document.get("generation") == ref[3], "source_document_identity")
            spans = [s for s in document.get("spans", []) if uid(s.get("id")) == ref[1]]
            require(len(spans) == 1 and spans[0].get("text") == source.get("text"), "source_span_changed")
            ranges = spans[0].get("sourceRanges")
            require(isinstance(ranges, list) and ranges, "missing_source_audio_ranges")
            for audio_range in ranges:
                chunk = uid(audio_range.get("chunkID")); referenced_chunks.add(chunk)
                chunks = db.execute("SELECT session_id,manifest,manifest_hash,relative_path,retention,receipt_applied FROM chunks WHERE id=?", (chunk,)).fetchall()
                require(len(chunks) == 1, "missing_source_chunk")
                row = chunks[0]
                raw = row[1].encode() if isinstance(row[1], str) else row[1]
                require(hashlib.sha256(raw).hexdigest() == row[2], "source_manifest_hash")
                manifest = json.loads(raw)
                require(uid(row[0]) == ref[0] and uid(manifest.get("sessionID")) == ref[0]
                        and uid(manifest.get("chunkID")) == chunk, "source_chunk_identity")
                part, full = audio_range.get("frames", {}), manifest.get("frames", {})
                require(all(type(v) is int for v in (part.get("start"), part.get("count"), full.get("start"), full.get("count")))
                        and part["count"] > 0 and full["start"] <= part["start"]
                        and part["start"] + part["count"] <= full["start"] + full["count"], "source_frame_range")
                path = reader.track(row[3], required=False)
                source_rows.append((chunk, row[4], row[5], path.exists()))
        expired = ledger.get("expiredChunkIDs")
        require(isinstance(expired, list), "missing_expired_chunk_list")
        if ledger["scenario"] == SCENARIOS[1]:
            r.check("expired_chunks_cover_exactly_both_sources", {uid(v) for v in expired} == referenced_chunks
                    and len(expired) == len(set(expired)))
            r.check("expired_audio_removed_and_receipts_applied", all(state == "expired" and applied == 1 and not exists
                    for _, state, applied, exists in source_rows))
        else:
            r.check("playable_source_audio_retained", expired == [] and all(state == "present" and exists
                    for _, state, _, exists in source_rows))
        r.metrics["validatedSources"] = len(refs)
        r.metrics["sourceChunks"] = len(referenced_chunks)
    finally:
        db.close()


class Report:
    def __init__(self, run_id, scenario):
        self.checks, self.metrics = [], {}
        self.run_id, self.scenario = run_id, scenario

    def check(self, name, condition):
        self.checks.append({"check": name, "status": "passed" if condition else "failed"})

    def group(self, name, operation):
        start = len(self.checks)
        try:
            result = operation()
            status = "failed" if any(c["status"] == "failed" for c in self.checks[start:]) else "passed"
            self.checks.append({"check": name, "status": status})
            return result
        except EvidenceError as error:
            self.checks.append({"check": name, "status": "failed", "reason": str(error)})
        except (OSError, sqlite3.Error, ValueError, KeyError, TypeError, IndexError):
            self.checks.append({"check": name, "status": "failed", "reason": "unreadable_or_unsupported_evidence"})
        return None

    def output(self, reader):
        statuses = [c["status"] for c in self.checks]
        return {"schemaVersion": 1, "runID": self.run_id, "scenario": self.scenario,
                "status": "failed" if "failed" in statuses else "unchecked" if "unchecked" in statuses else "passed",
                "checks": self.checks, "metrics": self.metrics, "inputs": reader.fingerprints,
                "scope": "Read-only persisted evidence; does not replace screenshots, real button interaction, external network, ASR, or audio listening."}


def verify(container, run_id, scenario):
    run_id = uid(run_id)
    require(scenario in SCENARIOS and container.is_absolute() and container.is_dir(), "invalid_checker_arguments")
    root = container / "Library/Caches/MoMoAgentUITests" / run_id
    require(root.is_dir(), "missing_isolated_run_root")
    for item in (root, *root.parents):
        require(not item.is_symlink(), "symlink_in_container_path")
        if item == container:
            break
    reader, report = Reader(root), Report(run_id, scenario)
    ledger = report.group("ledger_read", lambda: reader.json("controlled-stream-ledger.json", 256 * 1024))
    identity = report.group("ledger_schema_and_identity", lambda: check_ledger(report, ledger, run_id, scenario)) if ledger else None
    if identity:
        report.group("archive_source_validation", lambda: check_sources(report, reader, ledger))
        report.group("pi_durable_and_presentation", lambda: check_pi(report, reader, identity[0], ledger))
    else:
        report.checks += [{"check": name, "status": "unchecked", "reason": "valid_ledger_identity_required"}
                          for name in ("archive_source_validation", "pi_durable_and_presentation")]
    report.group("evidence_unchanged_during_read", lambda: require(reader.stable(), "evidence_changed_during_read"))
    expected = {"request_count", "relaunch_did_not_add_requests", "request_sequence", "single_session", "operation_identity",
                "app_attempts", "request_body_hashes", "request_times_ordered", "no_rejection_limit_or_unknown_events",
                "event_sequences_and_times", "session_final_operation", "presentation_session_and_draft",
                "pi_tasks_and_submissions_settled", "durable_admissions_match_operations", "one_logical_user_question",
                "selected_sources_preserved", "request_citations_are_formal_source_references",
                "source_1_version_generation_unchanged", "source_2_version_generation_unchanged"}
    expected |= {f"stream_{seq}_ordered_terminal" for seq in range(1, REQUEST_COUNTS[scenario] + 1)}
    if scenario == SCENARIOS[0]:
        expected |= {"regeneration_target_consistency", "regenerate_binds_original_turn", "regeneration_503_failure_is_durable"}
    expected |= {"expired_chunks_cover_exactly_both_sources", "expired_audio_removed_and_receipts_applied"} if scenario == SCENARIOS[1] else {"playable_source_audio_retained"}
    expected |= {"cancelled_before_body_has_no_assistant_content"} if scenario == SCENARIOS[2] else {
        "final_answer_is_durable_and_projected", "final_answer_completed_with_formal_citation", "partial_answer_retained_in_immutable_history"}
    seen = {item["check"] for item in report.checks}
    report.checks += [{"check": name, "status": "unchecked", "reason": "earlier_error_prevented_check"} for name in sorted(expected - seen)]
    return report.output(reader)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--container", required=True, type=Path)
    parser.add_argument("--run-id", required=True)
    parser.add_argument("--scenario", required=True, choices=SCENARIOS)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    output = args.output
    try:
        if output and output.resolve().is_relative_to(args.container.resolve()):
            output = None
            raise EvidenceError("output_must_be_outside_app_container")
        result = verify(args.container, args.run_id, args.scenario)
    except EvidenceError as error:
        result = {"schemaVersion": 1, "status": "failed", "checks": [{"check": "isolation", "status": "failed", "reason": str(error)}]}
    except (OSError, ValueError):
        result = {"schemaVersion": 1, "status": "failed", "checks": [{"check": "isolation", "status": "failed", "reason": "unreadable_isolation_root"}]}
    encoded = json.dumps(result, ensure_ascii=False, indent=2) + "\n"
    if output:
        # Never create parent directories or overwrite an existing evidence report.
        with output.open("x", encoding="utf-8") as stream:
            stream.write(encoded)
    print(encoded, end="")
    return {"passed": 0, "failed": 1, "unchecked": 2}[result["status"]]


if __name__ == "__main__":
    raise SystemExit(main())
