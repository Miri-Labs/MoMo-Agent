"""Score filewise VAD + ASR output against the frozen FLEURS references."""

import argparse
from collections import defaultdict
import hashlib
import json
from pathlib import Path
import statistics
import unicodedata

from corpus import METADATA, REVISION, parse_tsv, select, validate_manifest

NORMALIZATION_VERSION = "nfkc-casefold-remove-punctuation-whitespace-v1"


def normalize(text):
    """Keep digits, Chinese numerals, accents, symbols and simplified/traditional distinctions."""
    return "".join(char for char in unicodedata.normalize("NFKC", text).casefold()
                   if not char.isspace() and not unicodedata.category(char).startswith("P"))


def edits(reference, hypothesis):
    # Equal-cost paths prefer substitution, then deletion, then insertion.
    row = [(index, 0, 0, index) for index in range(len(hypothesis) + 1)]
    for i, ref in enumerate(reference, 1):
        new = [(i, 0, i, 0)]
        for j, hyp in enumerate(hypothesis, 1):
            if ref == hyp:
                new.append(row[j - 1])
                continue
            cost, sub, delete, insert = row[j - 1]
            substitution = (cost + 1, sub + 1, delete, insert)
            cost, sub, delete, insert = row[j]
            deletion = (cost + 1, sub, delete + 1, insert)
            cost, sub, delete, insert = new[j - 1]
            insertion = (cost + 1, sub, delete, insert + 1)
            new.append(min([substitution, deletion, insertion], key=lambda value: value[0]))
        row = new
    count, substitutions, deletions, insertions = row[-1]
    return dict(referenceCharacters=len(reference), hypothesisCharacters=len(hypothesis),
                edits=count, substitutions=substitutions, deletions=deletions, insertions=insertions,
                cer=count / len(reference) if reference else None)


def aggregate(rows):
    keys = ["referenceCharacters", "hypothesisCharacters", "edits", "substitutions", "deletions", "insertions"]
    result = {key: sum(row[key] for row in rows) for key in keys}
    result["cer"] = result["edits"] / result["referenceCharacters"] if result["referenceCharacters"] else None
    result["utteranceCount"] = len(rows)
    return result


def sha256(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def evaluate(manifest, outputs, completion):
    expected = {item["id"]: item for item in manifest["items"]}
    if len(expected) != len(manifest["items"]) or not expected:
        raise ValueError("The corpus must have unique nonempty IDs")
    actual = {}
    for output in outputs:
        if output["id"] not in expected or output["id"] in actual:
            raise ValueError("Unknown or duplicate output ID")
        item = expected[output["id"]]
        if output["audioSHA256"] != item["sha256"] or output["sentenceID"] != item["sentenceID"]:
            raise ValueError("Output identity differs from the corpus")
        if output["status"] not in {"completed", "error"}:
            raise ValueError("Unknown output status")
        actual[output["id"]] = output
    comparisons = []
    groups = defaultdict(list)
    for item in manifest["items"]:
        output = actual.get(item["id"])
        status = output["status"] if output else "missing"
        # Failed/absent items remain in the denominator, with an empty scored hypothesis.
        hypothesis = output["text"] if status == "completed" else ""
        reference = normalize(item["reference"])
        if not reference:
            raise ValueError("A speech reference becomes empty after normalization")
        normalized = edits(reference, normalize(hypothesis))
        raw = edits(item["rawReference"], hypothesis)
        result = dict(id=item["id"], sentenceID=item["sentenceID"], filename=item["filename"],
                      gender=item["gender"], sourceSeconds=item["frames"] / manifest["sampleRate"],
                      status=status, reference=item["reference"], rawReference=item["rawReference"],
                      hypothesis=output["text"] if output else "", scoredHypothesis=hypothesis,
                      normalizedReference=reference, normalizedHypothesis=normalize(hypothesis),
                      normalized=normalized, raw=raw, error=output.get("error") if output else "No output")
        comparisons.append(result)
        groups["gender:" + item["gender"]].append(normalized)
        seconds = result["sourceSeconds"]
        groups["duration:" + ("under_8s" if seconds < 8 else "8_to_15s" if seconds < 15 else "at_least_15s")].append(normalized)
    errors = sum(result["status"] == "error" for result in comparisons)
    missing = sum(result["status"] == "missing" for result in comparisons)
    completed = len(comparisons) - errors - missing
    if completion is not None and (completion["completedCount"] != completed or completion["errorCount"] != errors or missing):
        raise ValueError("Completion counts differ from utterance output")
    valid = completion is not None and errors == 0 and missing == 0
    total_seconds = sum(item["frames"] for item in manifest["items"]) / manifest["sampleRate"]
    elapsed = completion["elapsedSeconds"] if completion else sum(output["elapsedSeconds"] for output in outputs)
    result = dict(schemaVersion=1, status="complete" if valid else "incomplete", acceptance="not_evaluated",
                  normalizationVersion=NORMALIZATION_VERSION, completedCount=completed, errorCount=errors,
                  missingCount=missing, normalizedCER=aggregate([row["normalized"] for row in comparisons]),
                  rawCER=aggregate([row["raw"] for row in comparisons]),
                  macroUtteranceCER=statistics.mean(row["normalized"]["cer"] for row in comparisons),
                  groups={group: aggregate(rows) for group, rows in sorted(groups.items())},
                  sourceSeconds=total_seconds, elapsedSeconds=elapsed,
                  rtf=elapsed / total_seconds if valid else None,
                  vadMissRate=None, humanSpeechIntervals="pending", entityAccuracy=None,
                  scope="Filewise public read speech; failed items count as deletions; no quality threshold is asserted")
    return result, comparisons


def score(corpus, run):
    manifest_path = corpus / "manifest.json"
    manifest = json.loads(manifest_path.read_text())
    selection_path = corpus / "selection.json"
    selection = json.loads(selection_path.read_text())
    if selection["revision"] != REVISION or sha256(selection_path) != manifest["selectionSHA256"]:
        raise ValueError("Frozen selection checksum or revision differs")
    tsv = corpus / "metadata" / "test.tsv"
    if sha256(tsv) != METADATA["data/cmn_hans_cn/test.tsv"]:
        raise ValueError("Reference TSV checksum mismatch")
    if selection["items"] != select(parse_tsv(tsv.read_bytes())):
        raise ValueError("Frozen references differ from the pinned deterministic selection")
    validate_manifest(manifest, selection)
    metadata = json.loads((run / "run.json").read_text())
    if metadata["corpusSHA256"] != sha256(manifest_path):
        raise ValueError("The run used a different corpus manifest")
    outputs = [json.loads(line) for line in (run / "utterances.jsonl").read_text().splitlines() if line.strip()]
    complete_path = run / "completion.json"
    completion = json.loads(complete_path.read_text()) if complete_path.exists() else None
    report, comparisons = evaluate(manifest, outputs, completion)
    report["provenance"] = dict(corpusSHA256=metadata["corpusSHA256"],
                                 configurationFingerprint=metadata["configurationFingerprint"],
                                 runSHA256=sha256(run / "run.json"), outputSHA256=sha256(run / "utterances.jsonl"))
    for name, value in [("cer.json", report), ("comparisons.json", comparisons)]:
        path = run / name
        data = json.dumps(value, ensure_ascii=False, sort_keys=True, indent=2) + "\n"
        if path.exists() and path.read_text() != data:
            raise ValueError(f"Existing report differs: {path}")
        path.write_text(data)
    print(json.dumps({key: report[key] for key in ["status", "completedCount", "errorCount", "missingCount", "normalizedCER", "rtf"]}, indent=2))
    return report["status"] == "complete"


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("corpus", type=Path)
    parser.add_argument("run", type=Path)
    args = parser.parse_args()
    raise SystemExit(0 if score(args.corpus.resolve(), args.run.resolve()) else 2)
