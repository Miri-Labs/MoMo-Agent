"""Checker negative controls only: synthetic files/SQLite in TemporaryDirectory, no App or API."""
import copy
import importlib.util
import json
from pathlib import Path
import sqlite3
import subprocess
import sys
import tempfile
import unittest
import uuid

SCRIPT = Path(__file__).with_name("verify-controlled-ui-ledger.py")
SPEC = importlib.util.spec_from_file_location("controlled_ledger", SCRIPT)
VERIFY = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(VERIFY)


def identifier():
    return str(uuid.uuid4()).upper()


class EvidenceFixture:
    def __init__(self, parent, scenario):
        self.container = parent / "container"
        self.run = identifier()
        self.scenario = scenario
        self.root = self.container / "Library/Caches/MoMoAgentUITests" / self.run
        self.support = self.root / VERIFY.SUPPORT
        self.support.mkdir(parents=True)
        self.session, first, replacement = identifier(), identifier(), identifier()
        count = VERIFY.REQUEST_COUNTS[scenario]
        self.sources, self.audio = [], []
        archive = sqlite3.connect(self.support / "archive.sqlite")
        archive.executescript("""
            CREATE TABLE sessions(id TEXT,generation INTEGER,deleted INTEGER,transcript_version INTEGER,projection_blocked INTEGER);
            CREATE TABLE transcript_versions(session_id TEXT,version INTEGER,document BLOB);
            CREATE TABLE chunks(id TEXT,session_id TEXT,manifest BLOB,manifest_hash TEXT,relative_path TEXT,retention TEXT,receipt_applied INTEGER);
        """)
        chunks = []
        for index in range(2):
            recording, span, chunk = identifier(), identifier(), identifier()
            ref = {"sessionID": recording, "spanID": span, "transcriptVersion": 1, "generation": 0}
            self.sources.append({"reference": ref, "text": f"synthetic source {index}"})
            frames = {"start": 0, "count": 1600}
            document = {"sessionID": recording, "version": 1, "generation": 0,
                        "spans": [{"id": span, "text": f"synthetic source {index}", "sourceRanges": [{"chunkID": chunk, "frames": frames}]}]}
            manifest = json.dumps({"chunkID": chunk, "sessionID": recording, "frames": frames}).encode()
            relative = f"Documents/recordings/{recording}/audio.wav"
            path = self.root / relative
            path.parent.mkdir(parents=True)
            if count != 2:
                path.write_bytes(b"synthetic checker file; not audio")
            self.audio.append(path); chunks.append(chunk)
            archive.execute("INSERT INTO sessions VALUES(?,0,0,1,0)", (recording,))
            archive.execute("INSERT INTO transcript_versions VALUES(?,1,?)", (recording, json.dumps(document).encode()))
            archive.execute("INSERT INTO chunks VALUES(?,?,?,?,?,?,?)", (chunk, recording, manifest,
                VERIFY.hashlib.sha256(manifest).hexdigest(), relative, "present" if count != 2 else "expired", 1))
        archive.commit(); archive.close()
        refs = [s["reference"] for s in self.sources]
        self.ledger = {"schemaVersion": 2, "runID": self.run, "scenario": scenario, "sources": self.sources,
                       "launches": 2, "launchRequestCounts": [0, count], "requests": [], "events": [],
                       "expiredChunkIDs": chunks if count == 2 else [], "expiredSourceVersionsPreserved": count == 2}
        for seq in range(1, count + 1):
            item = {"sequence": seq, "sessionID": self.session, "operationID": first if count == 2 or seq == 1 else replacement,
                    "appAttempt": 1 if count != 1 and seq == count else 0, "bodySHA256": "a" * 64,
                    "citationURL": VERIFY.citation(VERIFY.reference(refs[0])), "startedAt": seq * 10.0}
            if count == 4 and seq > 1:
                item["replacingTurn"] = "2:0"
            self.ledger["requests"].append(item)
            terminal = "cancelled" if seq == 1 and count == 4 else "injected-stream-failure" if seq == 1 else "http-503" if count == 4 and seq in (2, 3) else "completed"
            event_kinds = ["request", "headers-200", "cancelled"] if count == 1 else [
                "request", "headers-503" if terminal == "http-503" else "headers-200", "body", terminal]
            for offset, kind in enumerate(event_kinds):
                self.ledger["events"].append({"sequence": seq, "kind": kind, "at": seq * 10.0 + offset, "byteCount": 10 if kind == "body" else 0})
        self.save_ledger()
        self.agent = self.support / "Agent" / self.session
        self.agent.mkdir(parents=True)
        self.metadata = {"id": self.session, "operationID": self.ledger["requests"][-1]["operationID"], "attempt": 0 if count == 1 else 1,
                         "state": "cancelled" if count == 1 else "finished", "durableStoreCreated": True,
                         "requestText": VERIFY.QUESTION, "selectedSources": refs}
        if count == 4:
            self.metadata["replacingTurn"] = "2:0"
        self.save_metadata()
        (self.support / "assistant-presentation.json").write_text(json.dumps({"version": 1,
            "selectedSessionID": self.session, "draft": VERIFY.DRAFT, "pending": []}))
        self.pi = self.agent / "pi.sqlite"
        db = sqlite3.connect(self.pi)
        db.executescript("""
            CREATE TABLE durable_schema(singleton INTEGER,version INTEGER);
            INSERT INTO durable_schema VALUES(1,1);
            CREATE TABLE entries(id INTEGER,record TEXT,conversation_id INTEGER,head INTEGER,commit_seq INTEGER);
            CREATE TABLE submissions(id INTEGER,record TEXT,request_id TEXT,status TEXT);
            CREATE TABLE tasks(id INTEGER,record TEXT,status TEXT);
            CREATE TABLE conversations(id INTEGER,record TEXT);
        """)
        db.execute("INSERT INTO conversations VALUES(1,?)", (json.dumps({"id": 1}),))
        db.execute("INSERT INTO tasks VALUES(30,?,?)", (json.dumps({"id": 30, "state": {"status": "terminal"}}), "terminal"))
        requests = [self.ledger["requests"][0], self.ledger["requests"][1], self.ledger["requests"][-1]] if count == 4 else self.ledger["requests"]
        for index, request in enumerate(requests):
            entry_id = 2 + index * 3
            data = {"selectedSources": refs, "selectedSource": refs[0]}
            if index:
                data["replacingTurn"] = "2:0"
            user = {"id": entry_id, "conversationId": 1, "kind": "momoagent.replacement" if index else "momoagent.input",
                    "data": data, "model": [{"role": "user", "content": VERIFY.QUESTION}]}
            stop = "aborted" if count == 1 else "stop" if index == len(requests) - 1 else "aborted" if index == 0 and count == 4 else "error"
            answer = {"id": entry_id + 1, "conversationId": 1, "kind": "pi.assistant", "model": [{"role": "assistant",
                "content": [{"type": "text", "text": "synthetic partial or final " + VERIFY.citation(VERIFY.reference(refs[0]))}], "stopReason": stop}]}
            if count == 1:
                answer["model"][0]["content"] = []
            if count == 4 and index == 1:
                answer["model"][0]["diagnostics"] = [{"type": "pi.transport_failure.v1", "details": {
                    "kind": "http", "httpStatus": 503, "httpAttempts": 2,
                    "context": {"requestIDs": [request["operationID"]]}}}]
            for entry in (user, answer):
                db.execute("INSERT INTO entries VALUES(?,?,1,NULL,?)", (entry["id"], json.dumps(entry), entry["id"]))
            key = request["operationID"] + (":retry:1" if request["appAttempt"] else "")
            submission = {"id": 20 + index, "conversationId": 1, "type": "input", "requestId": key, "entry": entry_id,
                          "status": "done" if count != 1 and index == len(requests) - 1 else "unanswered"}
            if count == 1:
                submission["reason"] = "aborted"
            if submission["status"] == "done":
                submission["answer"] = entry_id + 1
            db.execute("INSERT INTO submissions VALUES(?,?,?,?)", (submission["id"], json.dumps(submission), json.dumps(key), submission["status"]))
        db.commit(); db.close()

    def save_ledger(self):
        (self.root / "controlled-stream-ledger.json").write_text(json.dumps(self.ledger))

    def save_metadata(self):
        (self.agent / "session.json").write_text(json.dumps(self.metadata))

    def verify(self):
        return VERIFY.verify(self.container, self.run, self.scenario)


class ControlledLedgerCheckerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="momo-ledger-checker-")
        self.addCleanup(self.temp.cleanup)
        self.parent = Path(self.temp.name)

    def fixture(self, scenario=VERIFY.SCENARIOS[0]):
        return EvidenceFixture(self.parent, scenario)

    def failed(self, fixture, name):
        result = fixture.verify()
        self.assertEqual(result["status"], "failed")
        self.assertTrue(any(item["check"] == name and item["status"] == "failed" for item in result["checks"]))

    def test_complete_a_raw_three_inputs_project_to_one_and_files_stable(self):
        fixture = self.fixture()
        result = fixture.verify()
        self.assertEqual(result["status"], "passed", result)
        self.assertEqual(result["metrics"]["rawUserInputs"], 3)
        self.assertEqual(result["metrics"]["logicalUserQuestions"], 1)
        self.assertNotIn(VERIFY.QUESTION, json.dumps(result))
        self.assertNotIn("synthetic source", json.dumps(result))

    def test_complete_b_expired_audio_is_independently_absent(self):
        result = self.fixture(VERIFY.SCENARIOS[1]).verify()
        self.assertEqual(result["status"], "passed", result)
        self.assertEqual(result["metrics"]["sourceChunks"], 2)

    def test_cancel_before_body_accepts_only_admitted_cancelled_empty_answer(self):
        fixture = self.fixture(VERIFY.SCENARIOS[2])
        result = fixture.verify()
        self.assertEqual(result["status"], "passed", result)
        self.assertEqual(result["metrics"]["rawUserInputs"], 1)
        self.assertEqual(result["metrics"]["logicalUserQuestions"], 1)
        self.assertEqual(result["metrics"]["assistantMessages"], 1)
        # Pi may retain an empty aborted assistant entry or no assistant entry.
        # Neither form is evidence of received answer text.
        with sqlite3.connect(fixture.pi) as db:
            db.execute("DELETE FROM entries WHERE id=3")
        self.assertEqual(fixture.verify()["status"], "passed")

    def test_cancel_before_body_rejects_missing_request_body_timeout_and_relaunch(self):
        for mutation, check in (("no_request", "request_count"), ("body", "stream_1_ordered_terminal"),
                                ("bytes", "stream_1_ordered_terminal"), ("timeout", "session_final_operation"),
                                ("model_error", "durable_admissions_match_operations"),
                                ("answer", "cancelled_before_body_has_no_assistant_content"),
                                ("relaunch", "relaunch_did_not_add_requests")):
            with self.subTest(mutation=mutation):
                fixture = self.fixture(VERIFY.SCENARIOS[2])
                if mutation == "no_request":
                    fixture.ledger["requests"] = []
                elif mutation == "body":
                    fixture.ledger["events"].insert(2, {"sequence": 1, "kind": "body", "at": 11.5, "byteCount": 1})
                elif mutation == "bytes":
                    fixture.ledger["events"][1]["byteCount"] = 1
                elif mutation == "timeout":
                    fixture.metadata["state"] = "failed"
                    fixture.save_metadata()
                elif mutation == "relaunch":
                    fixture.ledger["launchRequestCounts"] = [0, 0]
                else:
                    with sqlite3.connect(fixture.pi) as db:
                        table, entry_id = ("submissions", 20) if mutation == "model_error" else ("entries", 3)
                        record = json.loads(db.execute(f"SELECT record FROM {table} WHERE id=?", (entry_id,)).fetchone()[0])
                        if mutation == "model_error":
                            record["reason"] = "model_error"
                        else:
                            record["model"][0]["content"] = [{"type": "text", "text": "unexpected answer"}]
                        db.execute(f"UPDATE {table} SET record=? WHERE id=?", (json.dumps(record), entry_id))
                fixture.save_ledger()
                self.failed(fixture, check)

    def test_http_503_response_cleanup_may_cancel_after_positive_body(self):
        fixture = self.fixture()
        for event in fixture.ledger["events"]:
            if event["sequence"] in (2, 3) and event["kind"] == "http-503":
                event["kind"] = "cancelled"
        fixture.save_ledger()
        result = fixture.verify()
        self.assertEqual(result["status"], "passed", result)

    def test_http_503_requires_exact_headers_positive_body_and_terminal_order(self):
        for mutation in ("wrong_header", "zero_body", "no_body", "late_body", "duplicate_terminal"):
            with self.subTest(mutation=mutation):
                fixture = self.fixture()
                group = [e for e in fixture.ledger["events"] if e["sequence"] == 3]
                group[-1]["kind"] = "cancelled"
                if mutation == "wrong_header":
                    group[1]["kind"] = "headers-200"
                elif mutation == "zero_body":
                    group[2]["byteCount"] = 0
                elif mutation == "no_body":
                    fixture.ledger["events"].remove(group[2])
                else:
                    event = {"sequence": 3, "kind": "body" if mutation == "late_body" else "http-503",
                             "at": 34, "byteCount": 10 if mutation == "late_body" else 0}
                    fixture.ledger["events"].insert(fixture.ledger["events"].index(group[-1]) + 1, event)
                fixture.save_ledger()
                self.failed(fixture, "stream_3_ordered_terminal")

    def test_http_503_requires_independent_pi_failure_identity_and_attempts(self):
        for mutation in ("missing", "status", "attempts", "request"):
            with self.subTest(mutation=mutation):
                fixture = self.fixture()
                with sqlite3.connect(fixture.pi) as db:
                    entry = json.loads(db.execute("SELECT record FROM entries WHERE id=6").fetchone()[0])
                    message = entry["model"][0]
                    if mutation == "missing":
                        message.pop("diagnostics")
                    else:
                        details = message["diagnostics"][0]["details"]
                        if mutation == "status":
                            details["httpStatus"] = 401
                        elif mutation == "attempts":
                            details["httpAttempts"] = 1
                        else:
                            details["context"]["requestIDs"] = [identifier()]
                    db.execute("UPDATE entries SET record=? WHERE id=6", (json.dumps(entry),))
                self.failed(fixture, "regeneration_503_failure_is_durable")

    def test_body_after_cancel_and_rejection_are_failures(self):
        fixture = self.fixture()
        fixture.ledger["events"].insert(4, {"sequence": 1, "kind": "body", "at": 14, "byteCount": 10})
        fixture.ledger["events"].append({"sequence": 4, "kind": "fixture-rejected", "at": 100, "byteCount": 0})
        fixture.save_ledger()
        self.failed(fixture, "stream_1_ordered_terminal")
        self.failed(fixture, "no_rejection_limit_or_unknown_events")

    def test_relaunch_request_and_operation_drift_are_rejected(self):
        fixture = self.fixture()
        fixture.ledger["launchRequestCounts"] = [0, 3]
        fixture.ledger["requests"][2]["operationID"] = identifier()
        fixture.save_ledger()
        self.failed(fixture, "relaunch_did_not_add_requests")
        self.failed(fixture, "operation_identity")

    def test_missing_schema_does_not_skip_to_pass(self):
        fixture = self.fixture()
        with sqlite3.connect(fixture.pi) as db:
            db.execute("DROP TABLE entries")
        result = fixture.verify()
        self.assertEqual(result["status"], "failed")
        self.assertTrue(any(c["check"] == "one_logical_user_question" and c["status"] == "unchecked" for c in result["checks"]))

    def test_regeneration_cannot_point_to_unrelated_turn(self):
        fixture = self.fixture()
        for request in fixture.ledger["requests"][1:]:
            request["replacingTurn"] = "999:0"
        fixture.save_ledger()
        self.failed(fixture, "regenerate_binds_original_turn")

    def test_expiry_claim_cannot_hide_remaining_audio_or_version_change(self):
        fixture = self.fixture(VERIFY.SCENARIOS[1])
        fixture.audio[0].write_bytes(b"still present")
        with sqlite3.connect(fixture.support / "archive.sqlite") as db:
            db.execute("UPDATE sessions SET generation=1")
        self.failed(fixture, "expired_audio_removed_and_receipts_applied")
        self.failed(fixture, "source_1_version_generation_unchanged")

    def test_symlinked_ledger_is_rejected(self):
        fixture = self.fixture()
        ledger = fixture.root / "controlled-stream-ledger.json"
        external = self.parent / "external.json"
        ledger.replace(external); ledger.symlink_to(external)
        self.failed(fixture, "ledger_read")

    def test_missing_ledger_is_failed_with_unchecked_dependents(self):
        fixture = self.fixture()
        (fixture.root / "controlled-stream-ledger.json").unlink()
        result = fixture.verify()
        self.assertEqual(result["status"], "failed")
        self.assertTrue(any(c["status"] == "unchecked" for c in result["checks"]))

    def test_output_inside_container_is_never_written(self):
        fixture = self.fixture()
        output = fixture.root / "must-not-write.json"
        result = subprocess.run([sys.executable, str(SCRIPT), "--container", str(fixture.container), "--run-id", fixture.run,
                                 "--scenario", fixture.scenario, "--output", str(output)], capture_output=True, text=True)
        self.assertEqual(result.returncode, 1)
        self.assertFalse(output.exists())
        self.assertNotIn(VERIFY.QUESTION, result.stdout)


if __name__ == "__main__":
    unittest.main()
