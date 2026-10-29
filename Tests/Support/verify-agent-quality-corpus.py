"""Offline D3 input/fact-table validation. Never calls a model or changes freeze hashes."""

import argparse
from collections import Counter, defaultdict
from datetime import datetime
import hashlib
import json
from pathlib import Path
import re
import sys
from zoneinfo import ZoneInfo

STRATA = {"complete", "ambiguity_or_missing", "untrusted_or_version_boundary"}
CHUNK_STATES = {"ready", "pending", "failed", "noSpeech", "completedWithoutText"}
TOOLS = {"get_context_status", "list_recordings", "search_transcripts", "read_transcript", "play_audio", "write_plan"}
SHA256 = re.compile(r"[0-9a-f]{64}\Z")
IDENTIFIER = re.compile(r"[a-z][a-z0-9-]+\Z")
SPLIT_COUNTS = {
    "development": {"complete": 12, "ambiguity_or_missing": 6, "untrusted_or_version_boundary": 6},
    "holdout": {"complete": 8, "ambiguity_or_missing": 4, "untrusted_or_version_boundary": 4},
}
LEGACY_IDS = {
    "d3-complete-context", "d3-missing-context", "d3-ambiguous-owner", "d3-same-name",
    "d3-negation-correction", "d3-untrusted-instruction", "d3-cross-midnight", "d3-selected-old",
}
ROOT = Path(__file__).resolve().parents[2]


class InvalidCorpus(ValueError):
    pass


def require(condition, message):
    if not condition:
        raise InvalidCorpus(message)


def exact_keys(value, required, optional=()):
    require(isinstance(value, dict), "expected object")
    require(set(required) <= value.keys() <= set(required) | set(optional),
            f"unexpected or missing fields: {sorted(value)}")


def text(value, label):
    require(isinstance(value, str) and bool(value.strip()), f"missing {label}")
    require(not re.search(r"\b(?:TODO|TBD|FIXME)\b|待补样本|占位文本", value), f"placeholder in {label}")


def strings(value, label, *, unique=True):
    require(isinstance(value, list), f"{label} must be a list")
    for item in value:
        text(item, label)
    require(not unique or len(set(value)) == len(value), f"duplicate {label}")


def canonical(value):
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode()


def digest(value):
    return hashlib.sha256(canonical(value)).hexdigest()


def timestamp(value):
    text(value, "timestamp")
    require(value.endswith("Z"), "fixture timestamps must use explicit UTC Z")
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError as error:
        raise InvalidCorpus("invalid fixture timestamp") from error
    return parsed


def derive_state(recordings):
    """Check the declared setup only; this does not claim that Archive APIs were executed."""
    states, readable, pending = {}, [], 0
    for recording in recordings:
        if recording.get("mutation", {}).get("type") == "delete":
            states[recording["key"]] = "deleted"
            continue
        kinds = [chunk["state"] for chunk in recording["chunks"]]
        pending += kinds.count("pending")
        readable.extend(chunk["key"] for chunk in recording["chunks"] if chunk["state"] == "ready")
        if "failed" in kinds:
            state = "failed"
        elif "pending" in kinds:
            state = "pending"
        elif "ready" in kinds:
            state = "transcribed"
        elif all(kind == "noSpeech" for kind in kinds):
            state = "noSpeech"
        else:
            state = "completedWithoutText"
        states[recording["key"]] = state
    return {"createdSessionCount": len(recordings),
            "visibleSessionCount": sum(state != "deleted" for state in states.values()),
            "pendingChunkCount": pending, "readableChunkKeys": readable, "statesByRecording": states}


def prepared_texts(case):
    """The future adapter's injection allowlist, excluding facts and unavailable old text."""
    result = []
    for recording in case["recordings"]:
        mutation = recording.get("mutation", {})
        if mutation.get("type") == "delete":
            continue
        for chunk in recording["chunks"]:
            if chunk["state"] == "ready":
                result.append(mutation.get("replacementTexts", {}).get(chunk["key"], chunk["text"]))
    return result


def validate_case(case, split):
    exact_keys(case, {"id", "coverageID", "stratum", "purpose", "clock", "recordings", "request",
                      "archiveExpectations", "facts", "reviewOnlyHiddenFacts", "split"}, {"pair"})
    require(isinstance(case["id"], str) and IDENTIFIER.fullmatch(case["id"]), "invalid case id")
    require(case["split"] == split, f"split mismatch: {case['id']}")
    require(case["stratum"] in STRATA, "invalid stratum")
    require(re.fullmatch(r"[DH]-[CMB]\d{2}", case["coverageID"]), "invalid coverage id")
    require(case["coverageID"].startswith("D-" if split == "development" else "H-"), "coverage split mismatch")
    expected_letter = {"complete": "C", "ambiguity_or_missing": "M", "untrusted_or_version_boundary": "B"}[case["stratum"]]
    require(case["coverageID"][2] == expected_letter, "coverage stratum mismatch")
    text(case["purpose"], "purpose")
    exact_keys(case["clock"], {"now", "timezone"})
    now = timestamp(case["clock"]["now"])
    try:
        ZoneInfo(case["clock"]["timezone"])
    except (KeyError, TypeError, ValueError) as error:
        raise InvalidCorpus("invalid request timezone") from error
    require(isinstance(case["recordings"], list) and case["recordings"], "new cases need explicit recording states")
    recording_keys, chunk_keys = set(), set()
    for recording in case["recordings"]:
        exact_keys(recording, {"key", "recordedAt", "timezoneOffsetSeconds", "chunks"}, {"mutation"})
        require(recording["key"] not in recording_keys, "duplicate recording key")
        require(IDENTIFIER.fullmatch(recording["key"]), "invalid recording key")
        recording_keys.add(recording["key"])
        require(timestamp(recording["recordedAt"]) <= now, "future recordedAt")
        offset = recording["timezoneOffsetSeconds"]
        require(type(offset) is int and -50_400 <= offset <= 50_400, "manifest requires a real timezone offset")
        chunks = recording["chunks"]
        require(isinstance(chunks, list) and chunks, "recording has no real chunks")
        local_keys = set()
        seen_pending = False
        for chunk in chunks:
            exact_keys(chunk, {"key", "state"}, {"text"})
            require(IDENTIFIER.fullmatch(chunk["key"]) and chunk["key"] not in chunk_keys, "duplicate/invalid source key")
            local_keys.add(chunk["key"])
            chunk_keys.add(chunk["key"])
            require(chunk["state"] in CHUNK_STATES, "invalid chunk state")
            if chunk["state"] == "ready":
                text(chunk.get("text"), "ready transcript")
                require(len(chunk["text"].encode()) + 128 <= 65_536, "transcript exceeds production span limit")
                require(not seen_pending, "ready chunk follows unprocessed predecessor")
            else:
                require("text" not in chunk, "unavailable audio must not contain injectable transcript text")
            seen_pending |= chunk["state"] == "pending"
        if any(chunk["state"] == "noSpeech" for chunk in chunks):
            require(all(chunk["state"] == "noSpeech" for chunk in chunks), "noSpeech needs full homogeneous coverage")
        mutation = recording.get("mutation")
        if mutation:
            require(all(chunk["state"] == "ready" for chunk in chunks), "mutations require an existing transcript")
            if mutation.get("type") == "delete":
                exact_keys(mutation, {"type"})
            elif mutation.get("type") == "revise":
                exact_keys(mutation, {"type", "replacementTexts"})
                require(set(mutation["replacementTexts"]) == local_keys, "revision must preserve actual source frames")
                for value in mutation["replacementTexts"].values():
                    text(value, "revision")
                    require(len(value.encode()) + 128 <= 65_536, "revision exceeds production limit")
            else:
                raise InvalidCorpus("unsupported mutation")
    require(case["archiveExpectations"] == derive_state(case["recordings"]), "declared Archive state mismatch")
    readable = set(case["archiveExpectations"]["readableChunkKeys"])
    request = case["request"]
    exact_keys(request, {"prompt", "expectedPlans", "allowedSourceKeys", "requiredPlanSourceKeys", "allowedTools",
                         "requiredSuccessfulTools"}, {"selectedRecordingKey"})
    text(request["prompt"], "prompt")
    require(type(request["expectedPlans"]) is int and request["expectedPlans"] in (0, 1), "plan budget must be zero or one")
    for field in ["allowedSourceKeys", "requiredPlanSourceKeys", "allowedTools", "requiredSuccessfulTools"]:
        strings(request[field], field)
    require(set(request["allowedSourceKeys"]) <= readable, "citation to unavailable source")
    require(set(request["requiredPlanSourceKeys"]) <= set(request["allowedSourceKeys"]), "required source outside scope")
    require(set(request["allowedTools"]) <= TOOLS, "unsupported tool")
    require(set(request["requiredSuccessfulTools"]) <= set(request["allowedTools"]), "required tool is forbidden")
    require("play_audio" not in request["allowedTools"], "new corpus never authorizes playback")
    require(("write_plan" in request["allowedTools"]) == bool(request["expectedPlans"]), "write authorization mismatch")
    require(bool(request["requiredPlanSourceKeys"]) == bool(request["expectedPlans"]), "saved plan must have grounded sources")
    if "selectedRecordingKey" in request:
        key = request["selectedRecordingKey"]
        require(key in recording_keys, "selected recording missing")
        recording = next(item for item in case["recordings"] if item["key"] == key)
        require(any(chunk["key"] in readable for chunk in recording["chunks"]), "selected source not readable")
    exact_keys(case["facts"], {"required", "forbidden", "clarify"})
    for group in ["required", "forbidden", "clarify"]:
        facts = case["facts"][group]
        require(isinstance(facts, list), "facts must be lists")
        require(group == "clarify" or facts, "required and forbidden facts must be nonempty")
        for number, entry in enumerate(facts, 1):
            require(entry.get("id") == f"{case['id']}:{group}:{number:02d}", "unstable fact id")
            if group == "required":
                exact_keys(entry, {"id", "statement", "evidenceKeys", "kind"})
                text(entry["statement"], "required fact")
                strings(entry["evidenceKeys"], "fact sources")
                require(set(entry["evidenceKeys"]) <= readable, "fact assumes unavailable text")
                require(entry["kind"] in {"confirmed", "unconfirmed", "calculated", "process"}, "invalid certainty")
                require(entry["kind"] == "process" or entry["evidenceKeys"], "factual claim needs evidence")
            elif group == "forbidden":
                exact_keys(entry, {"id", "statement", "literals"})
                text(entry["statement"], "forbidden fact")
                strings(entry["literals"], "forbidden literals")
            else:
                exact_keys(entry, {"id", "question", "reason"})
                text(entry["question"], "clarification")
                text(entry["reason"], "clarification reason")
    strings(case["reviewOnlyHiddenFacts"], "review-only facts")
    model_text = "\n".join([request["prompt"], *prepared_texts(case)])
    for hidden in case["reviewOnlyHiddenFacts"]:
        require(hidden not in model_text, "hidden fact table leaked into request")
    if case["reviewOnlyHiddenFacts"]:
        for entry in case["facts"]["forbidden"]:
            for literal in entry["literals"]:
                require(literal not in model_text, "withheld literal leaked into paired request")
    if "read_transcript" in request["requiredSuccessfulTools"]:
        # These cases must exceed the search excerpt. Mirror the text estimate for the smallest
        # 2048-token page, reserving 1024 tokens for metadata; this is not a runtime promise.
        required_texts = [text for text in prepared_texts(case) if len(text.encode()) > 1_200]
        require(required_texts, "read-required case must actually exceed a search excerpt")
        token_estimates = [(sum(1 if ord(char) < 128 else 8 for char in value) + 3) // 4 for value in required_texts]
        pages = sum((tokens + 64 + 1_023) // 1_024 for tokens in token_estimates)
        require(pages + 3 <= 12, "pagination fixture cannot fit production admission budget")
    if "pair" in case:
        exact_keys(case["pair"], {"id", "role"})
        require(IDENTIFIER.fullmatch(case["pair"]["id"]), "invalid pair id")
        require(case["pair"]["role"] in {"available", "unavailable", "partial"}, "invalid pair role")


def validate(directory):
    manifest = json.loads((directory / "manifest.json").read_text())
    require(manifest["schemaVersion"] == 1 and manifest["corpusVersion"] == "d3-40-v1", "unsupported manifest")
    require(manifest["status"] == "inputs-frozen-unwired-unexecuted", "update validator explicitly when wiring corpus")
    require(manifest["expectedCounts"] == SPLIT_COUNTS, "incorrect count contract")
    require(set(manifest["files"]) == {"development.json", "holdout.json"}, "unexpected corpus file paths")
    legacy = manifest["legacyCases"]
    require(len(legacy) == 8 and {case["id"] for case in legacy} == LEGACY_IDS, "legacy eight changed")
    for case in legacy:
        exact_keys(case, {"id", "stratum", "split", "fixtureSHA256"})
        require(case["split"] == "development" and case["stratum"] in STRATA, "invalid legacy catalog")
        require(SHA256.fullmatch(case["fixtureSHA256"]), "invalid legacy fixture hash")
    all_cases, ids, coverage = [], set(LEGACY_IDS), set()
    counts = {split: Counter() for split in SPLIT_COUNTS}
    counts["development"].update(case["stratum"] for case in legacy)
    for split in SPLIT_COUNTS:
        path = directory / f"{split}.json"
        raw = path.read_bytes()
        payload = json.loads(raw)
        exact_keys(payload, {"schemaVersion", "corpusVersion", "authorization", "sourceKind", "language", "privacy",
                             "annotationVersion", "factTableVisibility", "split", "cases"})
        require(payload["schemaVersion"] == 1 and payload["corpusVersion"] == manifest["corpusVersion"], "schema/version mismatch")
        require(payload["split"] == split and payload["sourceKind"] == "fixture" and payload["privacy"] == "synthetic-public", "invalid provenance")
        require(payload["language"] == "zh-Hans", "unexpected language")
        for field in ["authorization", "annotationVersion", "factTableVisibility"]:
            text(payload[field], field)
        record = manifest["files"][path.name]
        require(hashlib.sha256(raw).hexdigest() == record["sha256"], f"frozen file changed: {path.name}")
        require(digest(payload) == record["canonicalSHA256"], "canonical file hash mismatch")
        require(len(payload["cases"]) == record["caseCount"] == 16, "new split requires sixteen cases")
        for case in payload["cases"]:
            validate_case(case, split)
            require(case["id"] not in ids and case["coverageID"] not in coverage, "duplicate case/coverage id")
            ids.add(case["id"])
            coverage.add(case["coverageID"])
            require(digest(case) == manifest["caseHashes"].get(case["id"]), f"frozen case changed: {case['id']}")
            counts[split].update([case["stratum"]])
            all_cases.append(case)
    require(set(manifest["caseHashes"]) == {case["id"] for case in all_cases}, "hash catalog not exact")
    require(counts == SPLIT_COUNTS, "wrong stratified split")
    pairs = defaultdict(list)
    for case in all_cases:
        if "pair" in case:
            pairs[case["pair"]["id"]].append(case)
    require(len(pairs) == 3, "three new context pairs required (legacy pair is separate)")
    for pair in pairs.values():
        require(len(pair) == 2 and len({case["split"] for case in pair}) == 1, "pair leaks across split or is incomplete")
        require(len({case["request"]["prompt"] for case in pair}) == 1, "paired tasks differ")
        require(sum(case["pair"]["role"] == "available" for case in pair) == 1, "pair needs positive and negative")
        positive = next(case for case in pair if case["pair"]["role"] == "available")
        negative = next(case for case in pair if case["pair"]["role"] != "available")
        require(positive["request"]["expectedPlans"] == 1 and negative["request"]["expectedPlans"] == 0, "pair plan gate wrong")
        require({recording["key"] for recording in positive["recordings"]} == {recording["key"] for recording in negative["recordings"]}, "pair source identities differ")
        require(negative["reviewOnlyHiddenFacts"], "paired negative lacks review-only withheld facts")
    corpus_digest = digest({key: manifest[key] for key in ["files", "legacyCases", "caseHashes"]})
    require(corpus_digest == manifest["corpusSHA256"], "corpus hash mismatch")
    execution = manifest["execution"]
    require(execution == {"implementedLegacyCases": 8, "newJSONCases": 32, "newHostedCases": 0, "newAPIRuns": 0,
                          "independentRepetitionsRequired": 3, "defaultSelection": "legacy-eight-only",
                          "maximumModelAdmissionsPerCase": 12, "maximumOutputTokensPerAdmission": 2048,
                          "productionRequestDeadlineSeconds": 120}, "execution claim or budget changed")
    return {"offlineValidation": "passed", "newJSONCases": 32, "catalogTotalIncludingLegacy": 40,
            "counts": counts, "newPairCount": len(pairs), "legacyPairCountCatalogedElsewhere": 1,
            "corpusSHA256": corpus_digest, "holdoutFileSHA256": manifest["files"]["holdout.json"]["sha256"],
            "legacyRuntimeHashesRechecked": False, "archiveAPIsExecuted": False,
            "newHostedCases": 0, "newAPIRuns": 0,
            "limitation": "Checks frozen data/schema/state declarations only; no Swift preparation or model-quality result."}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--corpus", type=Path, default=ROOT / "Tests/Fixtures/AgentQuality")
    args = parser.parse_args()
    try:
        result = validate(args.corpus)
    except (InvalidCorpus, OSError, ValueError, KeyError, TypeError) as error:
        print(json.dumps({"offlineValidation": "failed", "reason": str(error)}, ensure_ascii=False))
        return 1
    print(json.dumps(result, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
