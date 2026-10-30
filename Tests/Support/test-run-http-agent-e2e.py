"""Runner-only checks: no simulator, build, fixture service, or model API is started."""

from contextlib import redirect_stdout
import importlib.util
import io
import json
from pathlib import Path
import plistlib
import signal
import subprocess
import tempfile
import unittest
from unittest.mock import Mock, patch
import uuid

SPEC = importlib.util.spec_from_file_location("http_runner", Path(__file__).with_name("run-http-agent-e2e.py"))
runner = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(runner)
SIMULATOR = "11111111-1111-4111-8111-111111111111"
RUN = "22222222-2222-4222-8222-222222222222"
ENDPOINT = "https://127.0.0.1:54433"


def hosted_target():
    return dict(BlueprintName=runner.TARGET, IsUITestBundle=False,
                TestHostBundleIdentifier=runner.BUNDLE_ID,
                TestHostPath="__TESTROOT__/Debug-iphonesimulator/MoMoAgent.app",
                TestBundlePath="__TESTHOST__/PlugIns/MoMoAgentIntegrationTests.xctest",
                EnvironmentVariables=dict(EXISTING="retained", MOMO_OLD="remove"),
                TestingEnvironmentVariables=dict(DYLD_FRAMEWORK_PATH="__TESTROOT__/Debug-iphonesimulator",
                                                 MOMO_OTHER_RUN="remove"),
                SkipTestIdentifiers=["old"], ParallelizationEnabled=True)


def write_ready(path, **changes):
    value = dict(kind="momoagent-j17-loopback-https", host="127.0.0.1", port=54433)
    value.update(changes)
    path.write_text(json.dumps(value))


class RunnerTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="http-runner-selftest-")
        self.root = Path(self.temporary.name).resolve()

    def tearDown(self):
        self.temporary.cleanup()

    def test_xctestrun_v1_v2_relocates_and_injects_host_environment(self):
        other = dict(BlueprintName="OtherTests", EnvironmentVariables=dict(MOMO_OTHER="untouched"))
        fixtures = [dict(MoMoAgentIntegrationTests=hosted_target(), OtherTests=other),
                    dict(TestConfigurations=[dict(TestTargets=[hosted_target(), other])])]
        products = self.root / "Build Products"
        for value in fixtures:
            with self.subTest(version=2 if "TestConfigurations" in value else 1):
                source, destination = self.root / "source.plist", self.root / "copy.plist"
                original = plistlib.dumps(value)
                source.write_bytes(original)
                runner.prepare_xctestrun(source, products, destination, ENDPOINT, RUN)
                self.assertEqual(source.read_bytes(), original)
                output = plistlib.loads(destination.read_bytes())
                if "TestConfigurations" in output:
                    target, untouched = output["TestConfigurations"][0]["TestTargets"]
                else:
                    target, untouched = output[runner.TARGET], output["OtherTests"]
                self.assertEqual(untouched, other)
                self.assertEqual(target["TestHostPath"], str(products / "Debug-iphonesimulator/MoMoAgent.app"))
                self.assertEqual(target["TestBundlePath"], "__TESTHOST__/PlugIns/MoMoAgentIntegrationTests.xctest")
                for field in ("EnvironmentVariables", "TestingEnvironmentVariables"):
                    environment = target[field]
                    self.assertEqual(environment["MOMO_HTTP_FIXTURE_PORT"], "54433")
                    self.assertEqual(environment["MOMO_UI_TEST_RUN_ID"], RUN)
                    self.assertEqual({key for key in environment if key.startswith("MoMo_")},
                                     {"MOMO_HTTP_FIXTURE_PORT", "MOMO_UI_TEST_RUN_ID"})
                self.assertEqual(target["OnlyTestIdentifiers"], [runner.TEST_CLASS])
                self.assertEqual(target["SkipTestIdentifiers"], [])
                self.assertFalse(target["ParallelizationEnabled"])
                self.assertNotIn(b"__TESTROOT__", destination.read_bytes())
        bad_inputs = [dict(TestConfigurations=["invalid"]),
                      dict(TestConfigurations=[dict(TestTargets=[hosted_target(), hosted_target()])]),
                      {runner.TARGET: dict(hosted_target(), TestHostBundleIdentifier="other.app")}]
        for value in bad_inputs:
            source.write_bytes(plistlib.dumps(value))
            with self.subTest(invalid=value), self.assertRaises(runner.Failure):
                runner.prepare_xctestrun(source, products, destination, ENDPOINT, RUN)

    def test_ready_accepts_only_loopback_and_does_not_use_arbitrary_urls(self):
        ready = self.root / "ready.json"
        write_ready(ready, baseURL="https://external.invalid", caCertificate="must-not-read")
        self.assertEqual(runner.fixture_endpoint(ready), ENDPOINT)
        for changes in (dict(host="localhost"), dict(host="external.invalid"), dict(kind="other"),
                        dict(port=True), dict(port="54433"), dict(port=0), dict(port=65536)):
            with self.subTest(changes=changes):
                write_ready(ready, **changes)
                with self.assertRaisesRegex(runner.Failure, "endpoint_invalid"):
                    runner.fixture_endpoint(ready)
        linked = self.root / "linked.json"
        linked.symlink_to(ready)
        with self.assertRaisesRegex(runner.Failure, "ready_invalid"):
            runner.fixture_endpoint(linked)
        with patch.dict(runner.os.environ, {"MOMO_E2E_API_KEY": "synthetic", "OPENROUTER_API_KEY": "synthetic"}):
            self.assertNotIn("MOMO_E2E_API_KEY", runner.environment())
            self.assertNotIn("OPENROUTER_API_KEY", runner.environment())

    def test_controlled_classes_are_selected_without_enabling_other_or_paid_tests(self):
        source, destination = self.root / "source.plist", self.root / "j25.xctestrun"
        source.write_bytes(plistlib.dumps({runner.TARGET: hosted_target()}))
        for test_class in ("AgentOutboundPrivacyIntegrationTests", "ConcurrentWorkloadIntegrationTests"):
            with self.subTest(test_class=test_class):
                runner.prepare_xctestrun(source, self.root / "products", destination, ENDPOINT, RUN, test_class)
                target = plistlib.loads(destination.read_bytes())[runner.TARGET]
                self.assertEqual(target["OnlyTestIdentifiers"], [test_class])
        with self.assertRaisesRegex(runner.Failure, "test_class_invalid"):
            runner.prepare_xctestrun(source, self.root / "products", destination, ENDPOINT, RUN,
                                    "LiveAgentContextTests")

    def test_cleanup_requires_stopped_host_and_preserves_unknown_or_symlink_entries(self):
        container = self.root / "container"
        workspaces = container / runner.WORKSPACES
        workspaces.mkdir(parents=True)
        previous = str(uuid.uuid4())
        (workspaces / previous).mkdir()
        safe = workspaces / str(uuid.uuid4())
        safe.mkdir()
        (safe / "state.sqlite").write_bytes(b"synthetic-test-file")
        outside = self.root / "outside"
        outside.mkdir()
        (outside / "keep").write_text("unchanged")
        symlink = workspaces / str(uuid.uuid4())
        symlink.symlink_to(outside, target_is_directory=True)
        linked_child = workspaces / str(uuid.uuid4())
        linked_child.mkdir()
        (linked_child / "state.sqlite").symlink_to(outside / "keep")
        invalid = workspaces / "not-a-run-id"
        invalid.mkdir()
        regular_file = workspaces / str(uuid.uuid4())
        regular_file.write_text("not-a-directory")
        with self.assertRaisesRegex(runner.Failure, "workspace_host_not_stopped"):
            runner.remove_new_workspaces(container, {previous}, False)
        self.assertTrue(safe.exists())
        removed, preserved = runner.remove_new_workspaces(container, {previous}, True)
        self.assertEqual(removed, [safe.name])
        self.assertEqual(set(preserved), {symlink.name, linked_child.name, invalid.name, regular_file.name})
        self.assertTrue((workspaces / previous).is_dir())
        self.assertEqual((outside / "keep").read_text(), "unchanged")
        with self.assertRaisesRegex(runner.Failure, "workspace_ownership_unknown"):
            runner.remove_new_workspaces(container, None, True)

    def test_failure_and_interruption_stop_host_before_cleaning_only_new_workspaces(self):
        for case in ("failed", "interrupted", "stop_failed", "no_preinstall_baseline"):
            with self.subTest(case=case):
                root = self.root / case
                root.mkdir()
                products, container = root / "products", root / "container"
                products.mkdir()
                workspaces = container / runner.WORKSPACES
                workspaces.mkdir(parents=True)
                old = workspaces / str(uuid.uuid4())
                old.mkdir()
                new = workspaces / str(uuid.uuid4())
                ready, plan = root / "ready.json", root / "source.xctestrun"
                write_ready(ready)
                plan.write_bytes(plistlib.dumps({runner.TARGET: hosted_target()}))
                events = []

                def run_test(command, log):
                    self.assertIn("-only-testing:" + runner.TARGET + "/" + runner.TEST_CLASS, command)
                    self.assertEqual(command[command.index("-parallel-testing-enabled") + 1], "NO")
                    new.mkdir()
                    (new / "state.sqlite").write_bytes(b"synthetic-test-file")
                    log.write_text("synthetic xcodebuild failure\n")
                    events.append("run")
                    if case == "interrupted":
                        raise KeyboardInterrupt
                    return 65

                def stop_host(_simulator):
                    events.append("stop")
                    self.assertTrue(new.exists())
                    if case == "stop_failed":
                        raise runner.Failure("host_still_running")

                def cleanup(*args):
                    self.assertEqual(events[-1], "stop")
                    events.append("cleanup")
                    return original_cleanup(*args)

                original_cleanup = runner.remove_new_workspaces
                container_result = ([runner.Failure("container_unavailable"), container]
                                    if case == "no_preinstall_baseline" else None)
                with patch.object(runner, "app_container", return_value=container, side_effect=container_result), \
                     patch.object(runner, "run_test", side_effect=run_test), \
                     patch.object(runner, "stop_host", side_effect=stop_host), \
                     patch.object(runner, "remove_new_workspaces", side_effect=cleanup), \
                     patch.object(runner, "command_output", return_value=json.dumps(dict(
                         totalTestCount=1, passedTests=0, failedTests=1, skippedTests=0))), \
                     redirect_stdout(io.StringIO()):
                    code = runner.main(["--xctestrun", str(plan), "--products", str(products),
                                        "--ready", str(ready), "--simulator", SIMULATOR,
                                        "--output", str(root / "evidence")])
                report = json.loads((root / "evidence/run.json").read_text())
                self.assertEqual(code, 1)
                self.assertFalse(report["accepted"])
                self.assertTrue(report["executed"])
                self.assertTrue((root / "evidence/xcodebuild.log").exists())
                self.assertTrue(old.exists())
                self.assertIn("stop", events)
                if case in ("failed", "interrupted"):
                    self.assertEqual(events, ["run", "stop", "cleanup"])
                    self.assertFalse(new.exists())
                    self.assertTrue(report["hostStopped"])
                else:
                    self.assertEqual(events, ["run", "stop"])
                    self.assertTrue(new.exists())
                if case == "interrupted":
                    self.assertIn("interrupted", report["errorCodes"])
                elif case == "stop_failed":
                    self.assertIn("host_still_running", report["errorCodes"])
                    self.assertFalse(report["hostStopped"])
                elif case == "no_preinstall_baseline":
                    self.assertEqual(report["workspaceCleanup"], "retained_no_preinstall_baseline")

        process = Mock(pid=54321)
        process.poll.return_value = None
        process.wait.side_effect = [subprocess.TimeoutExpired("synthetic-xcodebuild", 900), -15]
        with patch.object(runner.subprocess, "Popen", return_value=process) as launch, \
             patch.object(runner.os, "killpg") as terminate:
            with self.assertRaises(subprocess.TimeoutExpired):
                runner.run_test(["synthetic-xcodebuild"], self.root / "timeout.log")
        self.assertTrue(launch.call_args.kwargs["start_new_session"])
        terminate.assert_called_once_with(process.pid, signal.SIGTERM)
        self.assertEqual(process.wait.call_count, 2)


if __name__ == "__main__":
    unittest.main()
