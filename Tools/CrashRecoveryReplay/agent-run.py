"""Real process interruption of Pi history cleanup; J20 plan cases are retired."""
from __future__ import annotations

import argparse
import json
from pathlib import Path
import sys
import time
import uuid

from run import kill_at_boundary, read_database, require, run_phase, save, sha256


CASES = ("J21-invalidated", "J21-closed", "J21-removed",
         "J23-invalidated", "J23-closed", "J23-removed")
OLD = "OLD_AGENT_CRASH_SOURCE_7A2"
NEW = "NEW_AGENT_CRASH_SOURCE_9B4"


def source_hashes(repo: Path) -> dict[str, str]:
    paths = [repo / "Tools/CrashRecoveryReplay/Package.swift"]
    for folder in ("Tools/CrashRecoveryReplay/Sources/AgentCrashRecoveryReplay",
                   "Packages/MoMoAgentKit/Sources/MoMoAgent", "Packages/MoMoAgentKit/Sources/MoMoArchive"):
        paths.extend((repo / folder).rglob("*.swift"))
    paths.extend(repo / name for name in ("Tools/CrashRecoveryReplay/agent-run.py", "Tools/CrashRecoveryReplay/run.py",
                 "Vendor/PiDurableKit/Sources/PiDurableKit/Resources/pi-durable.js"))
    return {str(path.relative_to(repo)): sha256(path) for path in sorted(paths)}


def payloads(value: object):
    if isinstance(value, dict):
        yield value
        for child in value.values():
            yield from payloads(child)
    elif isinstance(value, list):
        for child in value:
            yield from payloads(child)


def files_under(directory: Path) -> dict[str, str]:
    return {str(path.relative_to(directory)): sha256(path) for path in sorted(directory.rglob("*")) if path.is_file()}


def database_fingerprints(root: Path) -> dict[str, str]:
    # SQLite may maintain its shared-memory coordination file even for readers; only database/WAL data is compared.
    return {str(path.relative_to(root)): sha256(path) for path in sorted(root.rglob("*"))
            if path.is_file() and (path.name.endswith(".sqlite") or path.name.endswith(".sqlite-wal"))}


def snapshot(root: Path, name: str) -> dict:
    before = database_fingerprints(root)
    archive = read_database(root / "phone/Library/Application Support/MoMoAgent/archive.sqlite", {
        "sessions": "SELECT id,generation,deleted,transcript_version,projection_version,projection_blocked FROM sessions ORDER BY id",
        "plans": "SELECT id,operation_id,state,CAST(document AS TEXT),projection_hash FROM plans ORDER BY rowid",
        "planSources": "SELECT plan_id,session_id FROM plan_sources ORDER BY plan_id,session_id",
        "cleanup": "SELECT agent_session_id,completed FROM agent_cleanup ORDER BY agent_session_id",
        "agentSources": "SELECT agent_session_id,session_id,version,generation FROM agent_sources ORDER BY agent_session_id",
        "transcripts": "SELECT session_id,version,CAST(document AS TEXT) FROM transcript_versions ORDER BY version",
        "search": "SELECT session_id,span_id,text,version FROM transcript_search ORDER BY session_id,span_id",
        "deletions": "SELECT session_id,files_cleaned,acknowledged_device FROM deletions ORDER BY session_id",
    })
    pi = {}
    for directory in sorted((root / "agent").iterdir()):
        if not directory.is_dir():
            continue
        record = {"files": files_under(directory),
                  "metadata": json.loads((directory / "session.json").read_text())}
        database = directory / "pi.sqlite"
        if database.exists():
            tables = read_database(database, {
                "entries": "SELECT record FROM entries ORDER BY commit_seq,id",
                "tasks": "SELECT record FROM tasks ORDER BY id",
                "submissions": "SELECT record FROM submissions ORDER BY id",
                "conversations": "SELECT record FROM conversations ORDER BY id",
                "documents": "SELECT record FROM documents ORDER BY id",
            })
            record["tables"] = {table: [json.loads(row[0]) for row in rows] for table, rows in tables.items()}
        pi[directory.name] = record
    result = {"archive": archive, "pi": pi, "documents": files_under(root / "phone/Documents")}
    require(before == database_fingerprints(root), "Read-only checker altered database or WAL bytes")
    result["databaseFingerprints"] = before
    save(root / f"{name}.snapshot.json", result)
    return result


def plans(snapshot_value: dict) -> list[dict]:
    return [{"id": row[0], "operationID": row[1], "state": row[2],
             "document": json.loads(row[3]) if row[3] else None, "projectionHash": row[4]}
            for row in snapshot_value["archive"]["plans"]]


def tool_results(pi: dict) -> list[dict]:
    return [item for item in payloads(pi.get("tables", {}).get("entries", []))
            if item.get("role") == "toolResult" and item.get("toolName") == "write_plan" and not item.get("isError")]


def assert_settled(value: dict) -> None:
    for pi in value["pi"].values():
        require(pi["metadata"]["state"] == "finished", "Application request remains active or failed")
        tables = pi.get("tables", {})
        require(all(task["state"]["status"] == "terminal" for task in tables.get("tasks", [])), "Pi has unfinished task ownership")
        require(all(submission["status"] == "done" for submission in tables.get("submissions", [])), "Pi submission did not settle")


def assert_plan_files(root: Path, value: dict, count: int) -> None:
    current = plans(value)
    require(len(current) == count, "Unexpected operation count")
    actual = sorted((root / "phone/Documents/workspace/plans").glob("*.md"))
    require(len(actual) == count, "Plan projection count differs from durable operations")
    for plan in current:
        document = plan["document"]
        require(document is not None and plan["state"] == "ready", "Plan is not durably ready")
        path = root / f"phone/Documents/workspace/plans/{plan['id']}.md"
        require(path.exists() and sha256(path) == plan["projectionHash"], "Plan projection hash mismatch")
        text = path.read_text()
        require(document["body"] in text and plan["id"] in text and plan["operationID"] in text,
                "Plan file differs from committed content/identity")


def check_plan_kill(case: str, root: Path, fixture: dict, value: dict) -> None:
    current = plans(value)
    expected = 0 if case == "J20-transaction" else 1
    require(len(current) == expected, "Crash boundary did not expose the expected committed plan count")
    projections = list((root / "phone/Documents/workspace/plans").glob("*.md"))
    require(len(projections) == int(case in ("J20-projection", "J20-tool-result")), "Wrong projection boundary")
    if current:
        require(current[0]["operationID"] == fixture["requestID"], "Plan operation differs from original request")
        require(current[0]["state"] == ("ready" if case == "J20-tool-result" else "pending"), "Wrong plan commit state")
    pi = value["pi"][fixture["agentSessionID"]]
    require(not tool_results(pi), "Pi had already committed the interrupted tool result")
    require(pi["metadata"]["operationID"] == fixture["requestID"], "Application request identity missing")
    require(OLD in json.dumps(pi, ensure_ascii=False), "Actual old source was never persisted in Pi")


def check_cleanup(case: str, fixture: dict, value: dict, finished: bool) -> None:
    archive = value["archive"]
    old_session = fixture["agentSessionID"]
    require(archive["cleanup"] == [(old_session, int(finished))], "Cleanup queue/completion mismatch")
    expected_directory = not finished and not case.endswith("removed")
    require((old_session in value["pi"]) == expected_directory, "Old Pi directory state does not match boundary")
    if expected_directory:
        require(OLD in json.dumps(value["pi"][old_session], ensure_ascii=False), "Old history missing before its actual removal")
    current = plans(value)
    require(len(current) == 1 and current[0]["state"] == "invalidated" and current[0]["document"] is None,
            "Invalidated plan was retained or resurrected")
    require(archive["sessions"][0][1] == 1, "Deletion/revision generation barrier not committed")
    if case.startswith("J21-"):
        require(archive["sessions"][0][2] == 1 and archive["transcripts"] == [] and archive["search"] == [],
                "Deleted transcript/index survived")
        require(len(archive["deletions"]) == 1 and archive["deletions"][0][2] is None,
                "Deletion tombstone missing or unpaired sender falsely acknowledged")
    else:
        require(archive["sessions"][0][2] == 0 and archive["sessions"][0][3] == 2, "Revision not current")
        require(NEW in json.dumps(archive["search"], ensure_ascii=False) and OLD not in json.dumps(archive["search"], ensure_ascii=False),
                "Search exposes old revision")
    if finished:
        require(all(row[0] != old_session for row in archive["agentSources"]), "Old Agent source registrations survived cleanup")
        require(not any(path.startswith("workspace/plans/") for path in value["documents"]), "Invalidated plan file survived")
        require(OLD not in json.dumps(value["pi"], ensure_ascii=False), "Old text remains in a live Pi history")


def run_case(executable: Path, case: str, root: Path) -> dict:
    root.mkdir()
    prepared = run_phase(executable, case, root, "prepare")
    fixture = json.loads((root / "fixture.json").read_text())
    killed = kill_at_boundary(executable, case, root)
    before = snapshot(root, "after-kill")
    if case.startswith("J20-"):
        check_plan_kill(case, root, fixture, before)
    else:
        check_cleanup(case, fixture, before, False)
    recovered = run_phase(executable, case, root, "recover")
    after = snapshot(root, "after-recovery")
    if case.startswith("J20-"):
        assert_plan_files(root, after, 2)
        original = next(item for item in plans(after) if item["operationID"] == fixture["requestID"])
        if plans(before):
            require(original["id"] == plans(before)[0]["id"], "Retry changed the original committed plan identity")
        require(original["document"]["sources"] == [fixture["source"]], "Source identity changed during retry")
        require(len(tool_results(after["pi"][fixture["agentSessionID"]])) >= 2, "Actual Pi tool results missing")
        old_tasks = before["pi"][fixture["agentSessionID"]]["tables"]["tasks"]
        resumed_tasks = {task["id"]: task for task in after["pi"][fixture["agentSessionID"]]["tables"]["tasks"]}
        interrupted_tools = [task for task in old_tasks if task["kind"] == "pi.tool" and task["state"]["status"] != "terminal"]
        require(len(interrupted_tools) == 1, "Boundary did not interrupt one real persisted Pi tool")
        original_tool = interrupted_tools[0]
        resumed_tool = resumed_tasks.get(original_tool["id"])
        require(resumed_tool is not None and resumed_tool["input"] == original_tool["input"]
                and resumed_tool["state"]["status"] == "terminal", "Recovery replaced rather than resumed the durable Pi tool")
        require(recovered["originalUserMessages"] == 2, "Original request was duplicated in UI history")
    else:
        check_cleanup(case, fixture, after, True)
        require(recovered["oldSessionRejected"] and recovered["oldWriteRejected"], "Old request was not rejected")
        require(recovered["oldSessionError"] == "sessionInvalidated"
                and recovered["oldWriteError"] == ("sessionDeleted" if case.startswith("J21-") else "staleSource"),
                "Old calls did not fail at their exact invalidation barriers")
        sent = [json.loads(line) for line in (root / "recover.provider.jsonl").read_text().splitlines()]
        require(len(sent) == 1 and OLD not in json.dumps(sent, ensure_ascii=False), "Old history was sent after restart")
        require((NEW in json.dumps(sent, ensure_ascii=False)) == case.startswith("J23-"), "Provider saw wrong current version")
    assert_settled(after)
    verified = run_phase(executable, case, root, "verify")
    final = snapshot(root, "after-second-restart")
    if case.startswith("J20-"):
        assert_plan_files(root, final, 2)
        require(plans(after) == plans(final), "Second restart changed plan data")
    else:
        check_cleanup(case, fixture, final, True)
        require(verified["oldSessionError"] == "historyMissingAfterCleanup"
                and verified["oldWriteError"] == ("sessionDeleted" if case.startswith("J21-") else "staleSource"),
                "Second restart did not observe removed history and the exact source barrier")
    assert_settled(final)
    require(verified["providerCalls"] == 0, "Second restart emitted a provider request")
    process_ids = [item["processID"] for item in (prepared, killed, recovered, verified)]
    require(len(set(process_ids)) == 4, "Recovery did not use separate processes")
    result = {"case": case, "passed": True, "processIDs": process_ids,
              "stopSignal": killed["observedStopSignal"], "killSignal": killed["sentSignal"],
              "killReturnCode": killed["returncode"], "providerCallsOnRecovery": recovered["providerCalls"],
              "providerCallsOnSecondRestart": verified["providerCalls"],
              "databaseIntegrityAndForeignKeys": "passed", "checkerDatabaseWrites": False}
    save(root / "result.json", result)
    return result


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--executable", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--case", choices=CASES, action="append", dest="cases")
    arguments = parser.parse_args()
    executable, output = arguments.executable.resolve(), arguments.output.resolve()
    require(executable.is_file(), "Build the Debug macOS executable first")
    output.mkdir(parents=True, exist_ok=False)
    repo = Path(__file__).resolve().parents[2]
    report = {"runID": str(uuid.uuid4()), "scope": "macOS real Pi/Archive SIGKILL; scripted provider; synthetic transcript; no API, ASR, simulator or device",
              "executableSHA256": sha256(executable), "sourceHashes": source_hashes(repo),
              "passed": False, "cases": [], "failure": None}
    started = time.monotonic()
    try:
        for case in arguments.cases or CASES:
            report["cases"].append(run_case(executable, case, output / case))
            print(f"PASS {case}", flush=True)
        report["passed"] = True
    except Exception as error:
        report["failure"] = {"type": type(error).__name__, "message": str(error)}
    finally:
        report["elapsedSeconds"] = time.monotonic() - started
        report["sourceHashesAfterRun"] = source_hashes(repo)
        save(output / "summary.json", report)
    print(json.dumps({"passed": report["passed"], "failure": report["failure"], "output": str(output)}, ensure_ascii=False))
    return 0 if report["passed"] else 1


if __name__ == "__main__":
    sys.exit(main())
