"""Runner orchestration self-checks with synthetic reports; no model API, simulator, or Swift build."""

import argparse
import importlib.util
import json
import os
from pathlib import Path
import stat
import signal
import subprocess
import tempfile
import unittest
from unittest.mock import Mock, patch

SPEC = importlib.util.spec_from_file_location("live_agent_runner", Path(__file__).with_name("run-live-agent-e2e.py"))
runner = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(runner)
KEY = "synthetic-non-provider-key"
MODEL = "synthetic/model"
RUN_ID = "11111111-1111-4111-8111-111111111111"


def report(name, run_id=RUN_ID, repetition=1):
    return dict(scenario=name, runID=run_id, modelID=MODEL, networkRoute="direct", totalTokens=80,
        quality=dict(fixture=dict(id=name, split="development", facts=dict(required=["Synthetic required fact"],
            forbidden=["Synthetic forbidden fact"], clarify=[])), fixtureSHA256="a" * 64, repetition=repetition,
            modelRequestAdmissions=2, outputTokens=40))


class RunnerTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="momo-agent-runner-selftest-")
        self.root = Path(self.temporary.name)
        self.container = self.root / "container"
        (self.container / "tmp").mkdir(parents=True)
        self.args = argparse.Namespace(suite="quality", model=MODEL, simulator="synthetic-simulator",
            network_route="direct", xctestrun=None)

    def tearDown(self):
        self.temporary.cleanup()

    def test_default_includes_memory_lifecycle_and_one_run(self):
        plan = runner.execution_plan("context", None, None, 24, 24 * 12 * 2048)
        self.assertEqual(set(plan["cases"]), runner.SCENARIOS)
        self.assertEqual(plan["caseRuns"], 6)
        self.assertEqual(plan["repetitions"], 1)
        self.args.suite = "context"
        command = runner.test_command(self.args, self.root, self.root / "Derived", self.root / "result", plan["cases"])
        self.assertEqual([v for v in command if v.startswith("-only-testing:")],
                         ["-only-testing:MoMoAgentIntegrationTests/LiveAgentContextTests"])

    def test_quality_defaults_three_independent_runs_with_hard_admission_budget(self):
        plan = runner.execution_plan("quality", None, None, 24, 24 * 12 * 2048)
        self.assertEqual(plan["caseRuns"], 24)
        self.assertEqual(plan["conservativeOutputTokenCeiling"], 589824)
        for limit in (23, 0, 121):
            with self.assertRaises(ValueError):
                runner.execution_plan("quality", None, None, limit, 589824)
        with self.assertRaisesRegex(ValueError, "output_token_budget_exceeded"):
            runner.execution_plan("quality", None, 3, 24, 589823)
        with self.assertRaises(ValueError):
            runner.execution_plan("quality", None, 4, 100, 9999999)

    def test_context_subset_does_not_repeat_unselected_paid_scenarios(self):
        plan = runner.execution_plan("context", ["same-session-new-context"], 1, 1, 24576)
        self.assertEqual(plan["cases"], ["same-session-new-context"])
        self.assertEqual(plan["caseRuns"], 1)
        self.args.suite = "context"
        command = runner.test_command(self.args, self.root, self.root, self.root, plan["cases"])
        self.assertEqual([value for value in command if value.startswith("-only-testing:")],
                         ["-only-testing:MoMoAgentIntegrationTests/LiveAgentContextTests/testSameSessionRefreshesNewRecording"])
        for suite, case in (("context", "d3-selected-old"), ("quality", "real-asr-context")):
            with self.assertRaises(ValueError):
                runner.execution_plan(suite, [case], 1, 1, 24576)

    def test_context_selector_names_exist_in_xctest_source(self):
        source = Path(__file__).resolve().parents[1] / "iPhoneIntegrationTests/LiveAgentContextTests.swift"
        text = source.read_text()
        for method in runner.CONTEXT_CASES.values():
            self.assertIn("func " + method + "(", text)

    def test_case_subset_and_cleanup_select_only_authorized_methods(self):
        plan = runner.execution_plan("quality", ["d3-selected-old", "d3-selected-old"], 1, 1, 24576)
        self.assertEqual(plan["cases"], ["d3-selected-old"])
        self.args.xctestrun = self.root / "compiled.xctestrun"
        command = runner.test_command(self.args, self.root, self.root, self.root, plan["cases"])
        self.assertIn("-xctestrun", command)
        self.assertNotIn("-project", command)
        self.assertIn("-only-testing:" + runner.QUALITY_TEST + "/testSelectedOld", command)
        cleanup = runner.test_command(self.args, self.root, self.root, self.root, plan["cases"], cleanup=True)
        self.assertEqual([v for v in cleanup if v.startswith("-only-testing:")],
                         ["-only-testing:" + runner.QUALITY_TEST + "/testCleanupCredentials"])
        self.assertNotIn(KEY, " ".join(command + cleanup))

    def test_quality_selector_names_exist_in_xctest_source(self):
        source = Path(__file__).resolve().parents[1] / "iPhoneIntegrationTests/LiveAgentQualityTests.swift"
        text = source.read_text()
        for method in list(runner.QUALITY_CASES.values()) + ["testCleanupCredentials"]:
            self.assertIn("func " + method + "(", text)

    def test_read_key_rejects_duplicates_shell_expressions_and_unclosed_quotes(self):
        path = self.root / "chosen.env"
        for content in ("OPENROUTER_API_KEY=", "OPENROUTER_API_KEY=a b", "OPENROUTER_API_KEY=$(whoami)",
                        'OPENROUTER_API_KEY="open', "OPENROUTER_API_KEY=a\nOPENROUTER_API_KEY=b"):
            path.write_text(content)
            with self.assertRaises(ValueError):
                runner.read_key(path)
        path.write_text("IGNORED=value\nexport OPENROUTER_API_KEY='" + KEY + "'\n")
        self.assertEqual(runner.read_key(path), KEY)

    def test_credential_is_exclusive_private_and_cleanup_checks_ownership(self):
        path = self.container / "tmp" / runner.CREDENTIAL_NAME
        identity = runner.write_credentials(path, dict(runID=RUN_ID, apiKey=KEY))
        self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o600)
        with self.assertRaises(FileExistsError):
            runner.write_credentials(path, {})
        with self.assertRaisesRegex(RuntimeError, "wrong_run"):
            runner.remove_credential(path, "other")
        path.write_text("interrupted JSON write")
        runner.remove_credential(path, RUN_ID, identity)
        self.assertFalse(path.exists())

    def test_partial_write_cleans_owned_file(self):
        path = self.container / "tmp" / runner.CREDENTIAL_NAME
        with patch.object(runner.os, "fsync", side_effect=OSError("synthetic failure")):
            with self.assertRaises(OSError):
                runner.write_credentials(path, dict(runID=RUN_ID, apiKey=KEY))
        self.assertFalse(path.exists())

    def test_scope_and_secret_checks_reject_wrong_repetition_and_key(self):
        valid = report("d3-missing-context")
        runner.validate_report(json.dumps(valid), KEY, "d3-missing-context", RUN_ID, MODEL, "direct", "quality", 1)
        for altered in (dict(valid, runID="other"), dict(valid, extra=KEY),
                        dict(valid, quality=dict(valid["quality"], repetition=2))):
            with self.assertRaises(RuntimeError):
                runner.validate_report(json.dumps(altered), KEY, "d3-missing-context", RUN_ID, MODEL, "direct", "quality", 1)

    def mock_run(self, command, **kwargs):
        if command[0] == "xcodebuild":
            is_cleanup = any("testCleanupCredentials" in value for value in command)
            if not is_cleanup:
                credential = json.loads((self.container / "tmp" / runner.CREDENTIAL_NAME).read_text())
                evidence = self.container / "tmp/live-agent-evidence" / credential["runID"]
                evidence.mkdir(parents=True)
                (evidence / "d3-missing-context.json").write_text(json.dumps(
                    report("d3-missing-context", credential["runID"], credential["repetition"])))
        return subprocess.CompletedProcess(command, 0)

    def mock_test(self, command, root, log, deadline):
        self.assertGreater(deadline, 0)
        return self.mock_run(command)

    def run_mocked(self, directory, repetition):
        with patch.object(runner, "app_container", return_value=self.container), \
             patch.object(runner, "stop_test_host"), \
             patch.object(runner.subprocess, "run", side_effect=self.mock_run), \
             patch.object(runner, "run_test", side_effect=self.mock_test), \
             patch.object(runner, "capture", return_value=json.dumps(dict(passedTests=1, skippedTests=0, failedTests=0))):
            return runner.run_once(self.args, self.root, self.root, self.root / "app", directory,
                                   ["d3-missing-context"], repetition, KEY)

    def test_repetitions_have_unique_runs_and_do_not_overwrite_results(self):
        first = self.run_mocked(self.root / "repetition-01", 1)
        second = self.run_mocked(self.root / "repetition-02", 2)
        self.assertNotEqual(first["runID"], second["runID"])
        self.assertTrue(first["automatedChecksPassed"] and second["automatedChecksPassed"])
        self.assertFalse(first["accepted"] or second["accepted"])
        self.assertTrue(first["credentialFileRemoved"] and first["keychainCleanupPassed"])
        with self.assertRaises(FileExistsError):
            self.run_mocked(self.root / "repetition-01", 1)
        review = json.loads((self.root / "repetition-01/semantic-review.json").read_text())
        self.assertEqual(review["cases"][0]["answerVerdict"], "unreviewed")
        self.assertEqual(review["cases"][0]["styleVerdict"], "unreviewed")
        self.assertFalse(review["semanticAccepted"])
        self.assertFalse((self.container / "tmp" / runner.CREDENTIAL_NAME).exists())
        self.assertNotIn(KEY, (self.root / "repetition-01/run.json").read_text())

    def test_context_automatic_success_still_requires_fact_review(self):
        self.args.suite = "context"

        def context_test(command, root, log, deadline):
            credential = json.loads((self.container / "tmp" / runner.CREDENTIAL_NAME).read_text())
            evidence = self.container / "tmp/live-agent-evidence" / credential["runID"]
            evidence.mkdir(parents=True)
            payload = dict(scenario="same-session-new-context", runID=credential["runID"],
                           modelID=MODEL, networkRoute="direct", answer="synthetic automatic success")
            (evidence / "same-session-new-context.json").write_text(json.dumps(payload))
            return subprocess.CompletedProcess(command, 0)

        with patch.object(runner, "app_container", return_value=self.container), \
             patch.object(runner, "stop_test_host"), \
             patch.object(runner.subprocess, "run", return_value=subprocess.CompletedProcess([], 0)), \
             patch.object(runner, "run_test", side_effect=context_test), \
             patch.object(runner, "capture", return_value=json.dumps(dict(passedTests=1, skippedTests=0, failedTests=0))):
            result = runner.run_once(self.args, self.root, self.root, self.root / "app", self.root / "context",
                                     ["same-session-new-context"], 1, KEY)
        self.assertTrue(result["automatedChecksPassed"])
        self.assertTrue(result["credentialFileRemoved"] and result["hostStopped"])
        self.assertFalse(result["accepted"])
        self.assertEqual(result["semanticReviewStatus"], "pending")

    def test_cleanup_failure_is_not_success_and_temporary_key_is_removed(self):
        def fail_cleanup(command, root, log, deadline):
            if any("testCleanupCredentials" in value for value in command):
                raise subprocess.TimeoutExpired("synthetic-cleanup", 1)
            return self.mock_run(command)
        with patch.object(runner, "app_container", return_value=self.container), \
             patch.object(runner, "stop_test_host"), \
             patch.object(runner.subprocess, "run", side_effect=self.mock_run), \
             patch.object(runner, "run_test", side_effect=fail_cleanup):
            result = runner.run_once(self.args, self.root, self.root, self.root / "app", self.root / "failed",
                                     ["d3-missing-context"], 1, KEY)
        self.assertFalse(result["automatedChecksPassed"])
        self.assertFalse(result["keychainCleanupPassed"])
        self.assertTrue(result["credentialFileRemoved"])
        self.assertEqual(result["failureCode"], "TimeoutExpired")

    def test_report_failure_still_cleans_credentials_and_preserves_raw_evidence(self):
        with patch.object(runner, "app_container", return_value=self.container), \
             patch.object(runner, "stop_test_host"), \
             patch.object(runner.subprocess, "run", side_effect=self.mock_run), \
             patch.object(runner, "run_test", side_effect=self.mock_test), \
             patch.object(runner, "capture", return_value=json.dumps(dict(passedTests=1, skippedTests=0, failedTests=0))), \
             patch.object(runner, "validate_report", side_effect=RuntimeError("bad_report")):
            result = runner.run_once(self.args, self.root, self.root, self.root / "app", self.root / "bad-report",
                                     ["d3-missing-context"], 1, KEY)
        self.assertFalse(result["automatedChecksPassed"])
        self.assertTrue(result["credentialFileRemoved"])
        self.assertTrue((self.container / "tmp/live-agent-evidence" / result["runID"]).is_dir())

    def test_timeout_and_interrupt_reap_test_before_cleanup_and_remove_key(self):
        for failure in (KeyboardInterrupt, subprocess.TimeoutExpired, runner.RunnerInterrupted):
            with self.subTest(failure=failure.__name__):
                events = []
                primary = Mock(pid=987654321)
                primary.poll.return_value = None

                def primary_wait(timeout):
                    events.append("primary_wait")
                    if events.count("primary_wait") == 1:
                        if failure is subprocess.TimeoutExpired:
                            raise failure("synthetic", timeout)
                        if failure is runner.RunnerInterrupted:
                            # Exercise the real runner signal handler, without terminating the test process.
                            os.kill(os.getpid(), signal.SIGTERM)
                        raise failure
                    primary.poll.return_value = 0
                    events.append("primary_reaped")
                    return 0

                primary.wait.side_effect = primary_wait
                cleanup = Mock(pid=987654322)
                cleanup.wait.return_value = 0
                cleanup.poll.return_value = 0

                def popen(command, **kwargs):
                    self.assertTrue(kwargs["start_new_session"])
                    if any("testCleanupCredentials" in value for value in command):
                        self.assertIn("primary_reaped", events)
                        self.assertEqual(events[-1], "host_stopped")
                        events.append("cleanup_started")
                        return cleanup
                    events.append("primary_started")
                    return primary

                with patch.object(runner, "app_container", return_value=self.container), \
                     patch.object(runner, "stop_test_host", side_effect=lambda _: events.append("host_stopped")), \
                     patch.object(runner.subprocess, "run", side_effect=self.mock_run), \
                     patch.object(runner.subprocess, "Popen", side_effect=popen), \
                     patch.object(runner.os, "killpg", side_effect=lambda pid, sig: events.append("terminate")), \
                     patch.object(runner, "capture", return_value=json.dumps(dict(passedTests=1, skippedTests=0, failedTests=0))):
                    result = runner.run_once(self.args, self.root, self.root, self.root / "app",
                        self.root / failure.__name__, ["d3-missing-context"], 1, KEY)
                self.assertEqual(result["failureCode"], failure.__name__)
                self.assertFalse(result["automatedChecksPassed"])
                self.assertTrue(result["keychainCleanupPassed"] and result["credentialFileRemoved"] and result["hostStopped"])
                self.assertLess(events.index("terminate"), events.index("primary_reaped"))
                self.assertLess(events.index("primary_reaped"), events.index("cleanup_started"))
                self.assertEqual(events[-1], "host_stopped")

    def test_unresponsive_test_is_killed_and_unconfirmed_exit_prevents_cleanup(self):
        process = Mock(pid=987654321)
        process.poll.return_value = None
        process.wait.side_effect = subprocess.TimeoutExpired("synthetic", 1)
        with patch.object(runner, "app_container", return_value=self.container), \
             patch.object(runner, "stop_test_host"), \
             patch.object(runner.subprocess, "run", side_effect=self.mock_run), \
             patch.object(runner.subprocess, "Popen", return_value=process) as popen, \
             patch.object(runner.os, "killpg") as kill:
            result = runner.run_once(self.args, self.root, self.root, self.root / "app", self.root / "unresponsive",
                                     ["d3-missing-context"], 1, KEY)
        self.assertEqual(result["failureCode"], "TestProcessCleanupFailed")
        self.assertFalse(result["keychainCleanupPassed"] or result["automatedChecksPassed"])
        self.assertTrue(result["credentialFileRemoved"] and result["hostStopped"])
        self.assertEqual(popen.call_count, 1)
        self.assertEqual([call.args[1] for call in kill.call_args_list], [signal.SIGTERM, signal.SIGKILL])
        self.assertEqual([call.kwargs["timeout"] for call in process.wait.call_args_list], [420, 10, 10])


if __name__ == "__main__":
    unittest.main()
