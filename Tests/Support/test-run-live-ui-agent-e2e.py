"""Synthetic runner-decision checks only: no Swift build, simulator, ASR, or model API."""

from contextlib import redirect_stdout
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import plistlib
import signal
import sqlite3
import stat
import tempfile
import unittest
from unittest.mock import patch
import uuid

SPEC = importlib.util.spec_from_file_location("live_ui_runner", Path(__file__).with_name("run-live-ui-agent-e2e.py"))
runner = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(runner)
RUN = "11111111-1111-4111-8111-111111111111"
AGENT = "22222222-2222-4222-8222-222222222222"
PLAN = "33333333-3333-4333-8333-333333333333"
OPERATION = "44444444-4444-4444-8444-444444444444"
MODEL = "synthetic/model-for-runner-self-test"
KEY = "synthetic-runner-key-not-a-provider-credential"
AUDIO = b"Synthetic bytes for runner hash validation; this is not ASR audio."
AUDIO_HASH = hashlib.sha256(AUDIO).hexdigest()


def fixture(root):
    """Minimal SQLite rows model the documented contracts, not a successful product run."""
    support = root / runner.SUPPORT
    support.mkdir(parents=True)
    audio_path = root / "Documents/recordings/synthetic/audio.wav"
    audio_path.parent.mkdir(parents=True)
    audio_path.write_bytes(AUDIO)
    frames = dict(start=0, count=32000)
    core = dict(start=1600, count=16000)
    source = dict(sessionID=RUN, spanID=PLAN, transcriptVersion=1, generation=0)
    manifest = dict(sourceKind="fixture", sourceBuild="debug-ui-fixture", sessionID=RUN, chunkID=RUN,
                    epochID=RUN, representation="full", codec="pcmInt16", sampleRate=16000, channels=1,
                    audioSHA256=AUDIO_HASH, byteCount=len(AUDIO), frames=frames, decodedFrameCount=32000)
    manifest_bytes = json.dumps(manifest).encode()
    manifest_hash = hashlib.sha256(manifest_bytes).hexdigest()
    window = dict(id="synthetic-window", configurationFingerprint="a" * 64, sessionID=RUN, epochID=RUN,
                  coreFrames=core, sources=[dict(chunkID=RUN, audioSHA256=AUDIO_HASH,
                                               manifestSHA256=manifest_hash, sourceFrames=frames)])
    transcript = dict(sessionID=RUN, version=1, generation=0, spans=[dict(id=PLAN, chunkID=RUN,
                      text="开放时间早上9点至下午5点。", frames=core, sourceRanges=[dict(chunkID=RUN, frames=core)])])
    database = sqlite3.connect(support / "archive.sqlite")
    database.executescript("""
      CREATE TABLE sessions(id,source_kind,generation,deleted,transcript_version,projection_version,projection_blocked);
      CREATE TABLE chunks(id,session_id,epoch_id,manifest,manifest_hash,audio_hash,relative_path,retention);
      CREATE TABLE analysis_windows(id,session_id,epoch_id,generation,configuration_hash,descriptor,state,raw_result);
      CREATE TABLE transcript_versions(session_id,version,document);
      CREATE TABLE plans(id,operation_id,document,state,revision,projection_hash);
      CREATE TABLE plan_sources(plan_id,session_id);
      CREATE TABLE agent_sources(agent_session_id,session_id,version,generation);
    """)
    database.execute("INSERT INTO sessions VALUES(?,?,?,?,?,?,?)", (RUN, "fixture", 0, 0, 1, 1, 0))
    database.execute("INSERT INTO chunks VALUES(?,?,?,?,?,?,?,?)", (RUN, RUN, RUN, manifest_bytes,
                     manifest_hash, AUDIO_HASH, str(audio_path.relative_to(root)), "present"))
    database.execute("INSERT INTO analysis_windows VALUES(?,?,?,?,?,?,?,?)",
                     (window["id"], RUN, RUN, 0, "a" * 64, json.dumps(window), "complete", b"synthetic-asr-result"))
    database.execute("INSERT INTO transcript_versions VALUES(?,?,?)", (RUN, 1, json.dumps(transcript)))
    database.execute("INSERT INTO agent_sources VALUES(?,?,?,?)", (AGENT, RUN, 1, 0))
    database.commit()
    database.close()
    agent_directory = support / "Agent" / AGENT
    agent_directory.mkdir(parents=True)
    (agent_directory / "session.json").write_text(json.dumps(dict(operationID=OPERATION)))
    (support / "Agent/provider.json").write_text(json.dumps(dict(baseURL=runner.PROVIDER_URL,
        modelID=MODEL, apiProtocol=runner.PROVIDER_PROTOCOL, compatibility="standard")))
    database = sqlite3.connect(agent_directory / "pi.sqlite")
    database.executescript("""
      CREATE TABLE entries(id,conversation_id,record);
      CREATE TABLE submissions(id,conversation_id,request_id,status,record);
      CREATE TABLE tasks(private_value);
      CREATE TABLE documents(private_value);
      INSERT INTO tasks VALUES('raw-task-must-never-be-exported');
      INSERT INTO documents VALUES('raw-document-must-never-be-exported');
    """)
    messages = [
        dict(role="user", content=[dict(type="text", text=runner.PROMPT)]),
        dict(role="assistant", model=MODEL, stopReason="toolUse", content=[
            dict(type="thinking", thinking="private-thinking-must-not-be-exported"),
            dict(type="toolCall", id="call-1", name="search_transcripts", arguments=dict(query="时间"))]),
        dict(role="toolResult", toolCallId="call-1", toolName="search_transcripts", isError=False,
             content=[dict(type="text", text=json.dumps(dict(passages=[dict(source=source, text="早上9点至下午5点。")])))], details="private-tool-details"),
        dict(role="assistant", model=MODEL, stopReason="stop", content=[dict(type="text", text="早上9点至下午5点。")]),
        dict(role="system", content=[dict(type="text", text="private-system-prompt")])]
    for entry_id, message in enumerate(messages, 1):
        if message["role"] == "assistant":
            message.update(provider=runner.PROVIDER_ID, api="openai-completions")
        record = dict(id=entry_id, conversationId=1, model=[message], data="private-entry-data")
        database.execute("INSERT INTO entries VALUES(?,?,?)", (entry_id, 1, json.dumps(record)))
    submission = dict(id=8, conversationId=1, requestId=OPERATION, type="input", status="done", entry=1, answer=4)
    database.execute("INSERT INTO submissions VALUES(?,?,?,?,?)", (8, 1, json.dumps(OPERATION), "done", json.dumps(submission)))
    database.commit()
    database.close()
    return source


class RunnerTests(unittest.TestCase):
    def setUp(self):
        # All files are ephemeral self-test inputs; no user archive or credential source is inspected.
        self.temporary = tempfile.TemporaryDirectory(prefix="momoagent-ui-runner-selftest-")
        self.root = Path(self.temporary.name).resolve()

    def tearDown(self):
        self.temporary.cleanup()

    def test_xctestrun_v1_and_v2_keep_paths_and_only_one_target(self):
        target = dict(IsUITestBundle=True, TestBundlePath="__TESTROOT__/Debug/Runner.app/Tests.xctest",
                      TestHostPath="__TESTROOT__/Debug/Runner.app", UITargetAppPath="__TESTROOT__/Debug/App.app",
                      EnvironmentVariables=dict(EXISTING="retained"), SkipTestIdentifiers=["old"])
        fixtures = [dict(MoMoAgentUITests=target, __xctestrun_metadata__=dict(FormatVersion=1)),
                    dict(TestConfigurations=[dict(TestTargets=[dict(target, BlueprintName="MoMoAgentUITests")])],
                         __xctestrun_metadata__=dict(FormatVersion=2))]
        for value in fixtures:
            with self.subTest(version=value["__xctestrun_metadata__"]):
                source, destination = self.root / "input.plist", self.root / "output.plist"
                source.write_bytes(plistlib.dumps(value))
                runner.prepare_xctestrun(source, self.root / "original Products", destination, RUN)
                output = plistlib.loads(destination.read_bytes())
                selected = output.get("MoMoAgentUITests") or output["TestConfigurations"][0]["TestTargets"][0]
                self.assertEqual(selected["EnvironmentVariables"], dict(EXISTING="retained", MOMO_LIVE_UI_RUN_ID=RUN))
                self.assertEqual(selected["OnlyTestIdentifiers"], [runner.TEST_NAME.split("/", 1)[1]])
                self.assertEqual(selected["SkipTestIdentifiers"], [])
                self.assertEqual(selected["TestHostPath"], str(self.root / "original Products/Debug/Runner.app"))
                self.assertNotIn(b"__TESTROOT__", destination.read_bytes())
                self.assertNotIn(KEY.encode(), destination.read_bytes())

    def test_credentials_are_exclusive_0600_and_stay_until_cleanup(self):
        (self.root / "tmp").mkdir()
        path = self.root / "tmp" / runner.CREDENTIAL_NAME
        runner.write_credentials(path, KEY, MODEL, RUN, "direct")
        self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o600)
        self.assertEqual(json.loads(path.read_text()), dict(enabled=True, apiKey=KEY, modelID=MODEL, runID=RUN, networkRoute="direct"))
        with self.assertRaises(FileExistsError):
            runner.write_credentials(path, "replacement", MODEL, RUN, "direct")
        with self.assertRaisesRegex(runner.Failure, "credential_cleanup_wrong_run"):
            runner.remove_credential(self.root, str(uuid.uuid4()))
        self.assertTrue(path.exists())
        runner.remove_credential(self.root, RUN)
        self.assertFalse(path.exists())

    def test_bad_credentials_are_rejected_without_evaluation(self):
        path = self.root / "chosen.env"
        for text in ("OPENROUTER_API_KEY=", "OPENROUTER_API_KEY=a b", 'OPENROUTER_API_KEY="missing',
                     "OPENROUTER_API_KEY=$(whoami)", "OPENROUTER_API_KEY=one\nOPENROUTER_API_KEY=two"):
            with self.subTest(case=text):
                path.write_text(text)
                with self.assertRaisesRegex(runner.Failure, "credentials_invalid"):
                    runner.read_key(path)
        path.write_text("UNRELATED=ignored\nexport OPENROUTER_API_KEY='" + KEY + "'\n")
        self.assertEqual(runner.read_key(path), KEY)

    def test_partial_credential_write_and_owned_malformed_file_are_cleaned(self):
        (self.root / "tmp").mkdir()
        path = self.root / "tmp" / runner.CREDENTIAL_NAME
        with patch.object(runner.os, "fsync", side_effect=OSError("synthetic fsync failure")):
            with self.assertRaises(OSError):
                runner.write_credentials(path, KEY, MODEL, RUN, "direct")
        self.assertFalse(path.exists())
        identity = runner.write_credentials(path, KEY, MODEL, RUN, "direct")
        path.write_text("malformed partial JSON")
        runner.remove_credential(self.root, RUN, identity)
        self.assertFalse(path.exists())

    def test_readonly_evidence_accepts_contract_and_omits_private_fields(self):
        fixture(self.root)
        before = {path: path.read_bytes() for path in self.root.rglob("*.sqlite")}
        with patch.object(runner, "PUBLIC_AUDIO_SHA256", AUDIO_HASH):
            evidence = runner.collect_evidence(self.root, RUN, MODEL, "direct")
        self.assertTrue(evidence["storageAndAgentChecksPassed"])
        self.assertNotIn("accepted", evidence)
        self.assertEqual(evidence["agent"]["submission"]["requestId"], OPERATION)
        output = json.dumps(evidence)
        for forbidden in ("private-", "raw-task-", "raw-document-", "synthetic-asr-result"):
            self.assertNotIn(forbidden, output)
        for path, data in before.items():
            self.assertEqual(path.read_bytes(), data)

    def test_wrong_model_is_rejected(self):
        fixture(self.root)
        path = self.root / runner.SUPPORT / "Agent" / AGENT / "pi.sqlite"
        with sqlite3.connect(path) as database:
            row = json.loads(database.execute("SELECT record FROM entries WHERE id=4").fetchone()[0])
            row["model"][0]["model"] = "wrong/model"
            database.execute("UPDATE entries SET record=? WHERE id=4", (json.dumps(row),))
        with patch.object(runner, "PUBLIC_AUDIO_SHA256", AUDIO_HASH):
            with self.assertRaisesRegex(runner.Failure, "model_mismatch"):
                runner.collect_evidence(self.root, RUN, MODEL, "direct")

    def test_wrong_provider_is_rejected(self):
        fixture(self.root)
        path = self.root / runner.SUPPORT / "Agent/provider.json"
        value = json.loads(path.read_text())
        value["baseURL"] = "https://wrong-provider.invalid/v1"
        path.write_text(json.dumps(value))
        with patch.object(runner, "PUBLIC_AUDIO_SHA256", AUDIO_HASH):
            with self.assertRaisesRegex(runner.Failure, "provider_configuration_mismatch"):
                runner.collect_evidence(self.root, RUN, MODEL, "direct")

    def test_failed_acceptance_still_retains_safe_diagnostics(self):
        fixture(self.root)
        path = self.root / runner.SUPPORT / "Agent" / AGENT / "pi.sqlite"
        with sqlite3.connect(path) as database:
            value = json.loads(database.execute("SELECT record FROM entries WHERE id=4").fetchone()[0])
            value["model"][0].update(stopReason="error", errorMessage="private-provider-error-body")
            database.execute("UPDATE entries SET record=? WHERE id=4", (json.dumps(value),))
        with patch.object(runner, "PUBLIC_AUDIO_SHA256", AUDIO_HASH):
            with self.assertRaisesRegex(runner.Failure, "model_failed"):
                runner.collect_evidence(self.root, RUN, MODEL, "direct")
        diagnostic = runner.collect_diagnostics(self.root, RUN)
        self.assertNotIn("accepted", diagnostic)
        messages = diagnostic["sessions"][0]["messages"]
        self.assertEqual(messages[-1]["stopReason"], "error")
        self.assertGreater(messages[-1]["errorUTF8Bytes"], 0)
        output = json.dumps(diagnostic)
        self.assertIn(runner.PROMPT, output)
        self.assertIn("search_transcripts", output)
        self.assertNotIn("private-", output)

    def test_unexpected_plan_creation_is_rejected(self):
        fixture(self.root)
        with sqlite3.connect(self.root / runner.SUPPORT / "archive.sqlite") as database:
            database.execute("INSERT INTO plans VALUES(?,?,?,?,?,?)", (PLAN, OPERATION, "{}", "ready", 1, None))
        with patch.object(runner, "PUBLIC_AUDIO_SHA256", AUDIO_HASH):
            with self.assertRaisesRegex(runner.Failure, "unexpected_plan_created"):
                runner.collect_evidence(self.root, RUN, MODEL, "direct")

    def test_wrong_audio_hash_and_frames_are_rejected(self):
        fixture(self.root)
        with self.assertRaisesRegex(runner.Failure, "audio_source_invalid"):
            runner.collect_evidence(self.root, RUN, MODEL, "direct")
        with sqlite3.connect(self.root / runner.SUPPORT / "archive.sqlite") as database:
            row = database.execute("SELECT document FROM transcript_versions").fetchone()
            document = json.loads(row[0])
            document["spans"][0]["sourceRanges"][0]["frames"]["start"] += 1
            database.execute("UPDATE transcript_versions SET document=?", (json.dumps(document),))
        with patch.object(runner, "PUBLIC_AUDIO_SHA256", AUDIO_HASH):
            with self.assertRaisesRegex(runner.Failure, "transcript_source_invalid"):
                runner.collect_evidence(self.root, RUN, MODEL, "direct")

    def test_summary_requires_one_pass_without_skips(self):
        value = dict(totalTestCount=1, passedTests=1, failedTests=0, skippedTests=0)
        self.assertEqual(runner.summary_evidence(value), value)
        for change in (dict(skippedTests=1), dict(failedTests=1), dict(totalTestCount=0), dict(passedTests=0)):
            with self.assertRaisesRegex(runner.Failure, "ui_test_not_passed"):
                runner.summary_evidence(dict(value, **change))

    def test_redaction_and_symlink_protection(self):
        text = json.dumps(dict(text="Bearer " + KEY, detail=KEY))
        self.assertNotIn(KEY, runner.redact(text, KEY))
        outside = self.root / "outside"
        outside.write_text("preserve")
        nested = self.root / "nested"
        nested.mkdir()
        (nested / "linked").symlink_to(outside)
        with self.assertRaisesRegex(runner.Failure, "evidence_path_invalid"):
            runner.safe_path(nested, "linked")
        with self.assertRaisesRegex(runner.Failure, "evidence_path_invalid"):
            runner.safe_path(nested, "../outside")

    def test_simulator_data_root_matches_only_the_selected_simulator(self):
        data = self.root / "Devices" / RUN / "data"
        bundle = data / "Containers/Bundle/Application" / AGENT / "MoMoAgent.app"
        self.assertEqual(runner.simulator_data_root(bundle, RUN), data)
        with self.assertRaisesRegex(runner.Failure, "host_path_invalid"):
            runner.simulator_data_root(bundle, AGENT)

    def test_missing_credentials_report_not_executed(self):
        output = self.root / "report"
        console = io.StringIO()
        with redirect_stdout(console), patch.object(runner, "command_output") as command:
            result = runner.main(["--model", MODEL, "--simulator", RUN, "--output", str(output)])
        command.assert_not_called()
        report = json.loads((output / "run.json").read_text())
        self.assertEqual(result, 1)
        self.assertEqual(report["status"], "not_executed")
        self.assertEqual(report["errorCodes"], ["credentials_missing"])

    def test_sigterm_handler_enters_cleanup_and_restores_prior_handlers(self):
        previous = {number: signal.getsignal(number) for number in (signal.SIGTERM, signal.SIGINT)}
        output = self.root / "term-report"

        def interrupted_read(_path):
            handler = signal.getsignal(signal.SIGTERM)
            self.assertIs(handler, runner.interrupt_requested)
            handler(signal.SIGTERM, None)

        with redirect_stdout(io.StringIO()), patch.object(runner, "read_key", side_effect=interrupted_read):
            self.assertEqual(runner.main(["--model", MODEL, "--simulator", RUN, "--output", str(output)]), 1)
        self.assertEqual({number: signal.getsignal(number) for number in previous}, previous)
        report = json.loads((output / "run.json").read_text())
        self.assertEqual(report["errorCodes"], ["interrupted"])

    def test_keyboard_interrupt_deletes_credentials_and_isolated_database(self):
        products = self.root / "derived/Build/Products"
        (products / "Debug-iphonesimulator/MoMoAgent.app").mkdir(parents=True)
        test_plan = products / "MoMoAgent_test.xctestrun"
        test_plan.write_bytes(plistlib.dumps(dict(MoMoAgentUITests=dict(IsUITestBundle=True))))
        container = self.root / "container"
        (container / "tmp").mkdir(parents=True)
        workspace = container / "Library/Caches/MoMoAgentUITests" / RUN
        workspace.mkdir(parents=True)
        (workspace / "archive.sqlite").write_text("synthetic-database-placeholder")
        credentials = self.root / "chosen.env"
        credentials.write_text("OPENROUTER_API_KEY=" + KEY)
        output = self.root / "interrupted"
        arguments = ["--credential-env-file", str(credentials), "--model", MODEL, "--simulator", RUN,
                     "--output", str(output), "--derived-data", str(self.root / "derived"), "--xctestrun", str(test_plan)]
        with redirect_stdout(io.StringIO()), patch.object(runner.uuid, "uuid4", return_value=uuid.UUID(RUN)), \
                patch.object(runner, "command_output", return_value=""), patch.object(runner, "stop_host"), \
                patch.object(runner, "app_container", return_value=container), \
                patch.object(runner, "run_test", side_effect=KeyboardInterrupt):
            self.assertEqual(runner.main(arguments), 1)
        report = json.loads((output / "run.json").read_text())
        self.assertIn("interrupted", report["errorCodes"])
        self.assertTrue(report["credentialFileRemoved"])
        self.assertTrue(report["isolatedWorkspaceRemoved"])
        self.assertFalse(workspace.exists())
        self.assertNotIn(KEY, (output / "run.json").read_text())


if __name__ == "__main__":
    unittest.main()
