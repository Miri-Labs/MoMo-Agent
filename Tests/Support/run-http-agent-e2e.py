"""Run hosted Agent HTTP fault tests against an existing loopback HTTPS fixture."""

import argparse
import json
import os
from pathlib import Path
import plistlib
import shutil
import signal
import stat
import subprocess
import uuid
from urllib.parse import urlsplit

BUNDLE_ID = "com.momoagent.ios"
TARGET = "MoMoAgentIntegrationTests"
TEST_CLASS = "AgentHTTPFaultIntegrationTests"
TEST_CLASSES = (TEST_CLASS, "AgentOutboundPrivacyIntegrationTests", "ConcurrentWorkloadIntegrationTests", "TimelineConfiguredSummaryTests")
WORKSPACES = Path("tmp/http-fault-workspaces")


class Failure(Exception):
    """Reports use fixed codes rather than arbitrary subprocess or filesystem output."""


def require(condition, code):
    if not condition:
        raise Failure(code)


def fixture_endpoint(ready):
    require(ready.is_file() and not ready.is_symlink() and ready.stat().st_size <= 64 * 1024,
            "ready_invalid")
    value = json.loads(ready.read_text())
    require(isinstance(value, dict) and value.get("kind") == "momoagent-j17-loopback-https"
            and value.get("host") == "127.0.0.1" and type(value.get("port")) is int
            and 1 <= value["port"] <= 65535, "endpoint_invalid")
    return f'https://127.0.0.1:{value["port"]}'


def prepare_xctestrun(source, products, destination, endpoint, run_id, test_class=TEST_CLASS):
    require(test_class in TEST_CLASSES, "test_class_invalid")
    def relocate(value):
        if isinstance(value, str):
            return value.replace("__TESTROOT__", str(products.resolve()))
        if isinstance(value, list):
            return [relocate(item) for item in value]
        if isinstance(value, dict):
            return {key: relocate(item) for key, item in value.items()}
        return value

    value = relocate(plistlib.loads(source.read_bytes()))
    require(isinstance(value, dict), "xctestrun_invalid")
    if "TestConfigurations" in value:
        require(isinstance(value["TestConfigurations"], list), "xctestrun_invalid")
        targets = []
        for configuration in value["TestConfigurations"]:
            require(isinstance(configuration, dict)
                    and isinstance(configuration.get("TestTargets"), list), "xctestrun_invalid")
            for target in configuration["TestTargets"]:
                require(isinstance(target, dict), "xctestrun_invalid")
                targets.append((target.get("BlueprintName"), target))
    else:
        targets = list(value.items())
    matches = 0
    for name, target in targets:
        if name != TARGET:
            continue
        require(isinstance(target, dict) and target.get("IsUITestBundle") is not True,
                "hosted_target_invalid")
        require(target.get("TestHostBundleIdentifier") == BUNDLE_ID, "hosted_target_invalid")
        # Hosted XCTest reads this process environment, not the xcodebuild shell environment.
        for field in ("EnvironmentVariables", "TestingEnvironmentVariables"):
            environment = target.setdefault(field, {})
            require(isinstance(environment, dict), "xctestrun_environment_invalid")
            for key in list(environment):
                if key.startswith("MoMo_"):
                    del environment[key]
            environment.update(MOMO_HTTP_FIXTURE_PORT=str(urlsplit(endpoint).port), MOMO_UI_TEST_RUN_ID=run_id)
        target["OnlyTestIdentifiers"] = [test_class]
        target["SkipTestIdentifiers"] = []
        target["ParallelizationEnabled"] = False
        target["TestTimeoutsEnabled"] = True
        matches += 1
    require(matches == 1, "xctestrun_target_not_unique")
    destination.write_bytes(plistlib.dumps(value))


def environment():
    allowed = {"PATH", "HOME", "TMPDIR", "USER", "LOGNAME", "SHELL", "LANG", "LC_ALL",
               "DEVELOPER_DIR", "TOOLCHAINS", "SDKROOT"}
    return {name: value for name, value in os.environ.items() if name in allowed}


def command_output(command, code):
    result = subprocess.run(command, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                            env=environment(), timeout=30)
    require(result.returncode == 0, code)
    return result.stdout.decode().strip()


def app_container(simulator, kind="data"):
    return Path(command_output(["xcrun", "simctl", "get_app_container", simulator, BUNDLE_ID, kind],
                               "container_unavailable"))


def stop_host(simulator):
    bundle = app_container(simulator, "app")
    executable = plistlib.loads((bundle / "Info.plist").read_bytes())["CFBundleExecutable"]
    require(isinstance(executable, str) and executable and "/" not in executable, "host_path_invalid")
    roots = [path for path in bundle.parents if path.name == "data" and path.parent.name.upper() == simulator.upper()]
    require(len(roots) == 1, "host_path_invalid")
    prefix = str(roots[0]) + "/Containers/Bundle/Application/"

    def running():
        processes = command_output(["ps", "-axww", "-o", "comm="], "host_status_failed").splitlines()
        return any(line.strip().startswith(prefix) and line.strip().endswith("/MoMoAgent.app/" + executable)
                   for line in processes)

    if running():
        command_output(["xcrun", "simctl", "terminate", simulator, BUNDLE_ID], "host_stop_failed")
    require(not running(), "host_still_running")


def workspace_root(container):
    require(container.is_dir() and not container.is_symlink(), "workspace_path_invalid")
    path = container
    for part in WORKSPACES.parts:
        path /= part
        if not os.path.lexists(path):
            return None
        require(stat.S_ISDIR(path.lstat().st_mode), "workspace_path_invalid")
    return path


def workspace_names(container):
    root = workspace_root(container)
    return {child.name for child in root.iterdir()} if root else set()


def remove_new_workspaces(container, previous, host_stopped):
    require(host_stopped, "workspace_host_not_stopped")
    require(previous is not None, "workspace_ownership_unknown")
    root = workspace_root(container)
    removed, preserved = [], []
    if root is None:
        return removed, preserved
    for child in sorted(root.iterdir()):
        if child.name in previous:
            continue
        try:
            valid_name = str(uuid.UUID(child.name)) == child.name.lower()
        except ValueError:
            valid_name = False
        if not valid_name or not stat.S_ISDIR(child.lstat().st_mode):
            preserved.append(child.name)
            continue
        safe = True
        for directory, directories, files in os.walk(child, followlinks=False):
            for name in directories + files:
                mode = (Path(directory) / name).lstat().st_mode
                if not (stat.S_ISDIR(mode) or stat.S_ISREG(mode)):
                    safe = False
        if safe:
            shutil.rmtree(child)
            removed.append(child.name)
        else:
            preserved.append(child.name)
    return removed, preserved


def run_test(command, log):
    with log.open("w") as stream:
        process = subprocess.Popen(command, stdout=stream, stderr=subprocess.STDOUT,
                                   env=environment(), start_new_session=True)
        try:
            return process.wait(timeout=900)
        finally:
            if process.poll() is None:
                try:
                    os.killpg(process.pid, signal.SIGTERM)
                except ProcessLookupError:
                    pass  # The child exited between poll and kill; wait still reaps it.
                try:
                    process.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    os.killpg(process.pid, signal.SIGKILL)
                    process.wait(timeout=10)


def interrupt(_number, _frame):
    raise KeyboardInterrupt


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ("xctestrun", "products", "ready", "output"):
        parser.add_argument("--" + name, type=Path, required=True)
    parser.add_argument("--simulator", required=True)
    parser.add_argument("--test-class", choices=TEST_CLASSES, default=TEST_CLASS)
    args = parser.parse_args(argv)
    output = args.output.resolve()
    try:
        output.mkdir(mode=0o700, parents=True, exist_ok=False)
    except OSError:
        print(json.dumps(dict(status="not_executed", accepted=False, errorCodes=["output_unavailable"])))
        return 1
    run_id = str(uuid.uuid4()).upper()
    report = dict(runID=run_id, simulator=args.simulator, test=f"{TARGET}/{args.test_class}",
                  executed=False, accepted=False, hostStopped=False, errorCodes=[],
                  workspaceCleanup="not_started")
    previous = None
    started = False
    prior_signals = {number: signal.getsignal(number) for number in (signal.SIGINT, signal.SIGTERM)}
    for number in prior_signals:
        signal.signal(number, interrupt)
    try:
        require(str(uuid.UUID(args.simulator)).upper() == args.simulator.upper(), "simulator_invalid")
        require(args.products.is_dir(), "products_missing")
        endpoint = fixture_endpoint(args.ready)
        report["fixtureBaseURL"] = endpoint
        plan = output / "http-faults.xctestrun"
        prepare_xctestrun(args.xctestrun, args.products, plan, endpoint, run_id, args.test_class)
        try:
            previous = workspace_names(app_container(args.simulator))
        except Failure as error:
            if str(error) != "container_unavailable":
                raise
            report["workspaceCleanup"] = "retained_no_preinstall_baseline"
        command = ["xcodebuild", "test-without-building", "-xctestrun", str(plan),
                   "-destination", f"platform=iOS Simulator,id={args.simulator}",
                   f"-only-testing:{TARGET}/{args.test_class}", "-parallel-testing-enabled", "NO",
                   "-collect-test-diagnostics", "never", "-test-timeouts-enabled", "YES",
                   "-default-test-execution-time-allowance", "240" if args.test_class == "ConcurrentWorkloadIntegrationTests" else "60",
                   "-maximum-test-execution-time-allowance", "240" if args.test_class == "ConcurrentWorkloadIntegrationTests" else "90",
                   "-resultBundlePath", str(output / "tests.xcresult")]
        started = report["executed"] = True
        report["exitCode"] = run_test(command, output / "xcodebuild.log")
        summary = json.loads(command_output(["xcrun", "xcresulttool", "get", "test-results", "summary",
                                             "--path", str(output / "tests.xcresult")], "summary_unavailable"))
        (output / "summary.json").write_text(json.dumps(summary, ensure_ascii=False, indent=2) + "\n")
        report["summary"] = {key: summary.get(key) for key in
                             ("totalTestCount", "passedTests", "failedTests", "skippedTests")}
        require(report["exitCode"] == 0, "xcodebuild_failed")
        require(type(summary.get("totalTestCount")) is int and summary["totalTestCount"] > 0
                and summary.get("passedTests") == summary["totalTestCount"]
                and summary.get("failedTests") == 0 and summary.get("skippedTests") == 0, "tests_not_all_passed")
        report["accepted"] = True
    except Failure as error:
        report["errorCodes"].append(str(error))
    except KeyboardInterrupt:
        report["errorCodes"].append("interrupted")
    except subprocess.TimeoutExpired:
        report["errorCodes"].append("command_timeout")
    except (OSError, ValueError, KeyError, TypeError, plistlib.InvalidFileException):
        report["errorCodes"].append("runner_input_or_output_invalid")
    finally:
        for number in prior_signals:
            signal.signal(number, signal.SIG_IGN)
        if started:
            try:
                stop_host(args.simulator)
                report["hostStopped"] = True
                if previous is not None:
                    removed, preserved = remove_new_workspaces(app_container(args.simulator), previous, True)
                    report["workspaceCleanup"] = "removed_new" if not preserved else "retained_unsafe_entries"
                    report["removedWorkspaceCount"] = len(removed)
                    report["preservedWorkspaceCount"] = len(preserved)
            except (Failure, OSError, ValueError, KeyError, subprocess.TimeoutExpired) as error:
                report["errorCodes"].append(str(error) if isinstance(error, Failure) else "cleanup_failed")
                report["workspaceCleanup"] = "retained_cleanup_unconfirmed"
        for number, handler in prior_signals.items():
            signal.signal(number, handler)
    report["accepted"] = report["accepted"] and not report["errorCodes"] and report["hostStopped"]
    report["status"] = "passed" if report["accepted"] else ("failed" if started else "not_executed")
    (output / "run.json").write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
    print(json.dumps(report, ensure_ascii=False))
    return 0 if report["accepted"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
