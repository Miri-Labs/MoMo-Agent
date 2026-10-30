"""Run opt-in hosted iOS Agent tests; all results require separate human fact review."""

import argparse
from contextlib import contextmanager
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import signal
import subprocess
import uuid

CONTEXT_CASES = {
    "personal-assistant-memory": "testNaturalConversationAndExplicitMemoryLifecycle",
    "recent-recording": "testRecentRecordingAnswersWithoutRetelling",
    "older-recording": "testOlderRecordingRequiresSearchAndRead",
    "same-session-new-context": "testSameSessionRefreshesNewRecording",
    "untrusted-transcript": "testTranscriptInstructionsCannotAuthorizePlayback",
    "real-asr-context": "testRealASRTranscriptSuppliesAnswer",
}
SCENARIOS = set(CONTEXT_CASES)
QUALITY_CASES = {
    "d3-complete-context": "testCompleteContext",
    "d3-missing-context": "testMissingContext",
    "d3-ambiguous-owner": "testAmbiguousOwner",
    "d3-same-name": "testSameName",
    "d3-negation-correction": "testNegationCorrection",
    "d3-untrusted-instruction": "testUntrustedInstruction",
    "d3-cross-midnight": "testCrossMidnight",
    "d3-selected-old": "testSelectedOld",
}
CREDENTIAL_NAME = "live-agent-credentials.json"
QUALITY_TEST = "MoMoAgentIntegrationTests/LiveAgentQualityTests"
TEST_ALLOWANCE_SECONDS = 240
CLEANUP_DEADLINE_SECONDS = 180


class RunnerInterrupted(BaseException):
    pass


class TestProcessCleanupFailed(RuntimeError):
    pass


def interrupt(_number, _frame):
    raise RunnerInterrupted


@contextmanager
def signal_handlers(handler):
    previous = {number: signal.getsignal(number) for number in (signal.SIGINT, signal.SIGTERM)}
    try:
        for number in previous:
            signal.signal(number, handler)
        yield
    finally:
        for number, old_handler in previous.items():
            signal.signal(number, old_handler)


def run_test(command: list[str], root: Path, log: Path, deadline: int) -> subprocess.CompletedProcess:
    """A killed or timed-out xcodebuild must be reaped before another test host can start."""
    with log.open("w") as stream:
        process = subprocess.Popen(command, cwd=root, stdout=stream, stderr=subprocess.STDOUT,
                                   start_new_session=True)
        try:
            return subprocess.CompletedProcess(command, process.wait(timeout=deadline))
        finally:
            # A second Ctrl-C/TERM must not interrupt the bounded termination and leave a paid run alive.
            with signal_handlers(signal.SIG_IGN):
                if process.poll() is None:
                    try:
                        os.killpg(process.pid, signal.SIGTERM)
                    except ProcessLookupError:
                        pass
                    except OSError as error:
                        raise TestProcessCleanupFailed from error
                    try:
                        process.wait(timeout=10)
                    except subprocess.TimeoutExpired:
                        try:
                            os.killpg(process.pid, signal.SIGKILL)
                        except ProcessLookupError:
                            pass
                        except OSError as error:
                            raise TestProcessCleanupFailed from error
                        try:
                            process.wait(timeout=10)
                        except subprocess.TimeoutExpired as error:
                            raise TestProcessCleanupFailed from error


def capture(*args: str) -> str:
    return subprocess.check_output(args, text=True, timeout=60).strip()


def app_container(simulator: str) -> Path:
    return Path(capture("xcrun", "simctl", "get_app_container", simulator, "com.momoagent.ios", "data"))


def stop_test_host(simulator: str) -> None:
    bundle = Path(capture("xcrun", "simctl", "get_app_container", simulator, "com.momoagent.ios", "app"))
    with (bundle / "Info.plist").open("rb") as stream:
        executable = bundle / plistlib.load(stream)["CFBundleExecutable"]

    def running() -> bool:
        return str(executable) in {line.strip() for line in capture("ps", "-axww", "-o", "comm=").splitlines()}

    if running():
        subprocess.run(["xcrun", "simctl", "terminate", simulator, "com.momoagent.ios"], check=True, timeout=30)
    if running():
        raise RuntimeError("test_host_still_running")


def read_key(path: Path) -> str:
    values = []
    for line in path.read_text().splitlines():
        match = re.match(r"^\s*(?:export\s+)?OPENROUTER_API_KEY\s*=\s*(.*?)\s*$", line)
        if match:
            value = match[1]
            if value[:1] in ("'", '"'):
                if len(value) < 2 or value[-1] != value[0]:
                    raise ValueError("credentials_invalid")
                value = value[1:-1]
            values.append(value)
    if (len(values) != 1 or not values[0] or len(values[0]) > 512
            or re.search(r"\s|[$`\\]", values[0])):
        raise ValueError("credentials_invalid")
    return values[0]


def execution_plan(suite: str, cases: list[str] | None, repetitions: int | None,
                   maximum_case_runs: int, maximum_output_tokens: int) -> dict:
    if suite not in {"context", "quality"}:
        raise ValueError("invalid_suite_or_case_selection")
    allowed = QUALITY_CASES if suite == "quality" else CONTEXT_CASES
    selected = sorted(set(cases or allowed))
    if any(case not in allowed for case in selected):
        raise ValueError("unknown_suite_case")
    repeat = repetitions if repetitions is not None else (3 if suite == "quality" else 1)
    if not 1 <= repeat <= 3 or not 1 <= maximum_case_runs <= 120 or maximum_output_tokens <= 0:
        raise ValueError("invalid_run_budget")
    case_runs = len(selected) * repeat
    if case_runs > maximum_case_runs:
        raise ValueError("case_run_budget_exceeded")
    output_ceiling = case_runs * 12 * 2048 if suite == "quality" else None
    if output_ceiling is not None and output_ceiling > maximum_output_tokens:
        raise ValueError("output_token_budget_exceeded")
    return dict(suite=suite, cases=selected, repetitions=repeat, caseRuns=case_runs,
                maximumCaseRuns=maximum_case_runs, maximumOutputTokens=maximum_output_tokens,
                conservativeOutputTokenCeiling=output_ceiling,
                qualityPerCase=dict(modelRequestAdmissions=12, outputTokensPerModelRequest=2048,
                                    deadlineSeconds=120) if suite == "quality" else None,
                billingNote="Provider input/cache/retry charges are additional; missing cost is unknown, never zero.")


def write_credentials(path: Path, payload: dict) -> tuple[int, int]:
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    identity = None
    try:
        identity = (os.fstat(descriptor).st_dev, os.fstat(descriptor).st_ino)
        with os.fdopen(descriptor, "w") as stream:
            json.dump(payload, stream)
            stream.flush()
            os.fsync(stream.fileno())
    except BaseException:
        if path.exists() and identity == (path.stat().st_dev, path.stat().st_ino):
            path.unlink()
        raise
    return identity


def remove_credential(path: Path, run_id: str, identity: tuple[int, int] | None = None) -> None:
    if not path.exists():
        return
    if path.is_symlink():
        raise RuntimeError("credential_cleanup_symlink")
    owned = identity == (path.stat().st_dev, path.stat().st_ino)
    if not owned and json.loads(path.read_text()).get("runID") != run_id:
        raise RuntimeError("credential_cleanup_wrong_run")
    path.unlink()


def test_command(args, root: Path, derived: Path, output: Path, names: list[str], cleanup=False) -> list[str]:
    command = ["xcodebuild", "test-without-building"]
    if args.xctestrun:
        command += ["-xctestrun", str(args.xctestrun.resolve())]
    else:
        command += ["-project", "MoMoAgent.xcodeproj", "-scheme", "MoMoAgent", "-derivedDataPath", str(derived)]
    command += ["-destination", f"platform=iOS Simulator,id={args.simulator}"]
    if cleanup:
        tests = [QUALITY_TEST + "/testCleanupCredentials"]
    elif args.suite == "quality":
        tests = [QUALITY_TEST + "/" + QUALITY_CASES[name] for name in names]
    else:
        context_test = "MoMoAgentIntegrationTests/LiveAgentContextTests"
        tests = [context_test] if set(names) == SCENARIOS else [context_test + "/" + CONTEXT_CASES[name] for name in names]
    command += ["-only-testing:" + test for test in tests]
    command += ["-parallel-testing-enabled", "NO", "-collect-test-diagnostics", "never",
                "-test-timeouts-enabled", "YES", "-default-test-execution-time-allowance", "200",
                "-maximum-test-execution-time-allowance", "240", "-resultBundlePath",
                str(output / ("cleanup.xcresult" if cleanup else "tests.xcresult")),
                "CODE_SIGNING_ALLOWED=YES", "CODE_SIGN_IDENTITY=-"]
    return command


def validate_report(content: str, key: str, name: str, run_id: str, model: str,
                    route: str, suite: str, repetition: int) -> dict:
    report = json.loads(content)
    if (key in content or report.get("scenario") != name or report.get("runID") != run_id
            or report.get("modelID") != model or report.get("networkRoute") != route):
        raise RuntimeError("report_does_not_match_authorized_run")
    if suite == "quality":
        quality = report.get("quality", {})
        fixture = quality.get("fixture", {})
        if (fixture.get("id") != name or fixture.get("split") != "development"
                or quality.get("repetition") != repetition or not fixture.get("facts", {}).get("required")
                or not re.fullmatch(r"[0-9a-f]{64}", quality.get("fixtureSHA256", ""))):
            raise RuntimeError("quality_report_scope_mismatch")
    return report


def write_review(output: Path, reports: dict[str, dict]) -> None:
    review = dict(status="pending", semanticAccepted=False, reviewer=None, reviewedAt=None, cases=[])
    for name, report in sorted(reports.items()):
        quality = report["quality"]
        review["cases"].append(dict(caseID=name, repetition=quality["repetition"],
            fixtureSHA256=quality["fixtureSHA256"], facts=quality["fixture"]["facts"],
            answerVerdict="unreviewed", styleVerdict="unreviewed", sourceSupportVerdict="unreviewed",
            requiredFacts=[], forbiddenFacts=[], clarification=[], evidenceQuotes=[], notes=""))
    (output / "semantic-review.json").write_text(json.dumps(review, ensure_ascii=False, indent=2) + "\n")


def run_once(args, root: Path, derived: Path, app: Path, output: Path, names: list[str], repetition: int, key: str) -> dict:
    with signal_handlers(interrupt):
        return _run_once(args, root, derived, app, output, names, repetition, key)


def _run_once(args, root: Path, derived: Path, app: Path, output: Path, names: list[str], repetition: int, key: str) -> dict:
    output.mkdir(parents=True, exist_ok=False)
    run_id = str(uuid.uuid4()).upper()
    manifest = dict(runID=run_id, suite=args.suite, repetition=repetition, selectedCases=names, model=args.model,
                    provider="https://openrouter.ai/api/v1", networkRoute=args.network_route,
                    simulator=args.simulator, accepted=False, semanticReviewStatus="pending", automatedChecksPassed=False,
                    credentialFileRemoved=False, keychainCleanupPassed=args.suite != "quality", hostStopped=False,
                    testProcessDeadlineSeconds=len(names) * TEST_ALLOWANCE_SECONDS + 180,
                    cleanupProcessDeadlineSeconds=CLEANUP_DEADLINE_SECONDS)
    result = None
    cleanup_result = None
    initial_credential = None
    identity = None
    reports = {}
    try:
        subprocess.run(["xcrun", "simctl", "install", args.simulator, str(app)], check=True, timeout=120)
        stop_test_host(args.simulator)
        temporary = app_container(args.simulator) / "tmp"
        temporary.mkdir(exist_ok=True)
        initial_credential = temporary / CREDENTIAL_NAME
        payload = dict(enabled=True, apiKey=key, modelID=args.model, runID=run_id, networkRoute=args.network_route)
        if args.suite == "quality":
            payload.update(suite="quality", repetition=repetition)
        identity = write_credentials(initial_credential, payload)
        may_start_cleanup = True
        try:
            result = run_test(test_command(args, root, derived, output, names), root,
                              output / "xcodebuild.log", manifest["testProcessDeadlineSeconds"])
        except TestProcessCleanupFailed:
            # Never launch another xcodebuild while termination of the first is unconfirmed.
            may_start_cleanup = False
            raise
        finally:
            with signal_handlers(signal.SIG_IGN):
                if args.suite == "quality" and may_start_cleanup:
                    stop_test_host(args.simulator)
                    try:
                        cleanup_result = run_test(test_command(args, root, derived, output, names, cleanup=True),
                            root, output / "credential-cleanup.log", CLEANUP_DEADLINE_SECONDS)
                    finally:
                        stop_test_host(args.simulator)
                    cleanup_summary = json.loads(capture("xcrun", "xcresulttool", "get", "test-results", "summary",
                                                         "--path", str(output / "cleanup.xcresult")))
                    manifest["keychainCleanupPassed"] = (cleanup_result.returncode == 0
                        and cleanup_summary.get("passedTests") == 1 and cleanup_summary.get("skippedTests") == 0
                        and cleanup_summary.get("failedTests") == 0)
                    (output / "credential-cleanup-summary.json").write_text(json.dumps(cleanup_summary, indent=2) + "\n")
        stop_test_host(args.simulator)
        evidence = app_container(args.simulator) / "tmp/live-agent-evidence" / run_id
        if evidence.is_dir():
            (output / "scenarios").mkdir()
            for name in names:
                source = evidence / f"{name}.json"
                if not source.is_file() or source.is_symlink():
                    continue
                content = source.read_text()
                reports[name] = validate_report(content, key, name, run_id, args.model,
                                                args.network_route, args.suite, repetition)
                (output / "scenarios" / source.name).write_text(content)
            # Only the authorized, stopped run's workspace; never export raw database or provider files.
            shutil.rmtree(evidence)
        summary = json.loads(capture("xcrun", "xcresulttool", "get", "test-results", "summary",
                                     "--path", str(output / "tests.xcresult")))
        (output / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
        manifest.update(exitCode=result.returncode, scenarioCount=len(reports),
            automatedChecksPassed=(result.returncode == 0 and set(reports) == set(names)
                and summary.get("passedTests") == len(names) and summary.get("skippedTests") == 0
                and summary.get("failedTests") == 0))
        if args.suite == "quality":
            write_review(output, reports)
            manifest.update(semanticReviewStatus="pending", totalTokens=sum(r.get("totalTokens", 0) for r in reports.values()),
                modelRequestAdmissions=sum(r["quality"].get("modelRequestAdmissions", 0) for r in reports.values()),
                outputTokens=sum(r["quality"].get("outputTokens", 0) for r in reports.values()))
    except BaseException as error:
        # Avoid printing credential-bearing provider errors, chosen env contents or exception arguments.
        manifest["failureCode"] = type(error).__name__
    finally:
        with signal_handlers(signal.SIG_IGN):
            if initial_credential is not None:
                try:
                    stop_test_host(args.simulator)
                    manifest["hostStopped"] = True
                except BaseException:
                    manifest["failureCode"] = "host_stop_failed"
            if initial_credential is not None and identity is not None:
                try:
                    remove_credential(initial_credential, run_id, identity)
                    current = app_container(args.simulator) / "tmp" / CREDENTIAL_NAME
                    remove_credential(current, run_id)
                    manifest["credentialFileRemoved"] = not initial_credential.exists() and not current.exists()
                except BaseException:
                    manifest["failureCode"] = "credential_cleanup_failed"
        manifest["automatedChecksPassed"] = (manifest["automatedChecksPassed"] and manifest["credentialFileRemoved"]
                                               and manifest["keychainCleanupPassed"] and manifest["hostStopped"])
        # Successful transport and automatic assertions cannot establish that the answer is faithful or conversational.
        manifest["accepted"] = False
        (output / "run.json").write_text(json.dumps(manifest, indent=2) + "\n")
    return manifest


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--credential-env-file", type=Path, required=True)
    parser.add_argument("--model", required=True)
    parser.add_argument("--simulator", required=True)
    parser.add_argument("--network-route", choices=["system", "direct"], default="system")
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--derived-data", type=Path, default=Path("DerivedData"))
    parser.add_argument("--xctestrun", type=Path)
    parser.add_argument("--suite", choices=["context", "quality"], default="context")
    parser.add_argument("--case", dest="cases", action="append", choices=sorted(set(QUALITY_CASES) | SCENARIOS))
    parser.add_argument("--repetitions", type=int)
    parser.add_argument("--max-case-runs", type=int, default=24)
    parser.add_argument("--max-output-tokens", type=int, default=24 * 12 * 2048)
    args = parser.parse_args()
    try:
        plan = execution_plan(args.suite, args.cases, args.repetitions, args.max_case_runs, args.max_output_tokens)
        key = read_key(args.credential_env_file)
    except (ValueError, OSError):
        parser.error("Invalid credentials, case selection or budget; no simulator or API work was started.")
    root = Path(__file__).resolve().parents[2]
    derived = (root / args.derived_data).resolve()
    app = derived / "Build/Products/Debug-iphonesimulator/MoMoAgent.app"
    if not app.is_dir() or (args.xctestrun and not args.xctestrun.is_file()):
        parser.error("Build the Debug app and hosted tests, and choose the matching xctestrun before running.")
    output = args.output.resolve()
    # Keep the default five-scenario runner's output layout unchanged.
    if args.suite == "context" and plan["repetitions"] == 1:
        result = run_once(args, root, derived, app, output, plan["cases"], 1, key)
        print(json.dumps(result))
        return 0 if result["automatedChecksPassed"] else 1
    output.mkdir(parents=True, exist_ok=False)
    if args.suite == "quality":
        plan.update(plannedD3Tasks=40, plannedDevelopmentTasks=24, plannedHoldoutTasks=16,
                    availableDevelopmentTasks=len(QUALITY_CASES), availableHoldoutTasks=0,
                    fixtureSourceSHA256=hashlib.sha256((root / "Tests/iPhoneIntegrationTests/LiveAgentQualityFixtures.swift").read_bytes()).hexdigest())
    (output / "execution-plan.json").write_text(json.dumps(plan, indent=2) + "\n")
    results = []
    for repetition in range(1, plan["repetitions"] + 1):
        result = run_once(args, root, derived, app, output / f"repetition-{repetition:02d}", plan["cases"], repetition, key)
        results.append(result)
        if not result["credentialFileRemoved"] or not result["keychainCleanupPassed"] or "failureCode" in result:
            break
    manifest = dict(suite=args.suite, repetitions=results, cases=plan["cases"],
        independentRepetitionsComplete=len(results) == 3 and len({r["runID"] for r in results}) == 3,
        automatedChecksPassed=len(results) == plan["repetitions"] and all(r["automatedChecksPassed"] for r in results),
        semanticReviewStatus="pending", accepted=False)
    if args.suite == "quality":
        manifest.update(fullD3Complete=False,
            fullD3Note="Development subset only. Forty tasks, stratified holdout and all applicable cases still required.")
    (output / "run.json").write_text(json.dumps(manifest, indent=2) + "\n")
    print(json.dumps(manifest))
    return 0 if manifest["automatedChecksPassed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
