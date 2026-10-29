"""Bounded offline SpeechEngine stress runner; never writes application/archive state.

The Swift producer and engine are separate from this PCM/evidence checker. All
source audio is the pinned public 5.592-second fixture, not quality ground truth.
"""
from __future__ import annotations

import argparse
import collections
import hashlib
import json
import math
import os
from pathlib import Path
import signal
import struct
import subprocess
import time
import wave

FIXTURE_SHA = "b77f1794fe374a0ba1ee1dc458bfaf9349496cbbfc32780c50ba3c5a7ad8e373"


def digest(path):
    value = hashlib.sha256()
    with Path(path).open("rb") as stream:
        for block in iter(lambda: stream.read(65536), b""):
            value.update(block)
    return value.hexdigest()


def save(path, value):
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")


def verify_inputs(root, fixture, seconds, duty):
    """Read actual WAV frames; independently rebuild the bounded expected cycle."""
    assert digest(fixture) == FIXTURE_SHA, "official fixture checksum"
    with wave.open(str(fixture), "rb") as source:
        assert source.getparams()[:4] == (1, 2, 16000, 89472)
        source.setpos(8000)
        original = struct.unpack("<70000h", source.readframes(70000))
    # AVAudioFile float conversion in the original diagnostic uses Int16 scale
    # 32767, so reproduce that documented quantization from integer source PCM.
    def quantize(value):
        # Match the documented Float32 multiplication before integer rounding;
        # Python's Float64 multiplication differs at six fixture sample ties.
        scaled = struct.unpack("<f", struct.pack("<f", value * 32767 / 32768))[0]
        return math.floor(scaled + 0.5) if scaled >= 0 else math.ceil(scaled - 0.5)
    voice = struct.pack("<70000h", *(quantize(value) for value in original))
    metadata = json.loads((root / "run.json").read_text())
    speech_frames = int(math.floor(duty * 480000 + 0.5))
    assert metadata["seconds"] == seconds
    assert metadata["speechOnFramesPerCycle"] == speech_frames
    assert metadata["cycleFrames"] == 480000
    manifests = json.loads((root / "inputs/inputs.json").read_text())
    assert len(manifests) == seconds // 60
    position, total_bytes, files = 0, 0, []
    for index, item in enumerate(manifests):
        path = root / "inputs" / f"{index}.wav"
        assert item["sequence"] == index
        assert item["frames"] == {"start": position, "count": 960000}
        assert item["decodedFrameCount"] == 960000
        assert item["sampleRate"] == 16000 and item["channels"] == 1
        assert item["codec"] == "pcmInt16" and item["sourceKind"] == "fixture"
        with wave.open(str(path), "rb") as audio:
            assert audio.getparams()[:4] == (1, 2, 16000, 960000)
            actual = audio.readframes(960000)
        expected = bytearray()
        for cycle_start in (position, position + 480000):
            offset = cycle_start % 70000
            repetitions = math.ceil((offset + speech_frames) / 70000)
            repeated = voice * repetitions
            expected.extend(repeated[offset * 2:(offset + speech_frames) * 2])
            expected.extend(bytes((480000 - speech_frames) * 2))
        assert actual == expected, f"actual PCM differs from duty schedule in chunk {index}"
        sha = digest(path)
        assert sha == item["audioSHA256"] and path.stat().st_size == item["byteCount"]
        files.append({"name": path.name, "sha256": sha, "frames": 960000})
        total_bytes += path.stat().st_size
        position += 960000
    assert position == seconds * 16000
    return {"scope": "independent actual PCM/hash/duration check before inference",
            "verifiedFrames": position, "verifiedBytes": total_bytes,
            "injectedFixtureDutyRatio": speech_frames / 480000,
            "manifestSHA256": digest(root / "inputs/inputs.json"), "files": files}


def records(path):
    with path.open() as stream:
        for line in stream:
            yield json.loads(line)


def union(ranges):
    result = []
    for start, end in sorted(ranges):
        assert end > start
        if result and start <= result[-1][1]:
            result[-1] = (result[-1][0], max(result[-1][1], end))
        else:
            result.append((start, end))
    return result


def intervals(items):
    return [(item["start"], item["start"] + item["count"]) for item in items]


def inspect(root):
    metadata = json.loads((root / "run.json").read_text())
    completion = json.loads((root / "completion.json").read_text())
    total = metadata["seconds"] * 16000
    assert completion["status"] == "completed"
    assert completion["completedThroughFrames"] == completion["totalSourceFrames"] == total
    assert digest(root / "inputs/inputs.json") == json.loads((root / "input-verification.json").read_text())["manifestSHA256"]
    decoded, covered, core, batch = {}, [], [], None
    prepared_count = completed_batch_count = 0
    previous_completed = 0
    window_measurements = []
    for entry in records(root / "progress.jsonl"):
        through = entry["completedThroughFrames"]
        assert previous_completed <= through <= total
        assert entry["availableBacklogSeconds"] == (total - through) / 16000
        previous_completed = through
        if entry["kind"] == "prepared":
            assert batch is None
            prepared_count += 1
            batch = {"coverage": intervals(entry["analyzedCoverage"]),
                     "noSpeech": intervals(entry["noSpeechCoverage"]), "cores": [], "pending": entry["pendingWindows"]}
        elif entry["kind"] == "transcribed":
            assert batch is not None
            window = entry["window"]
            assert window["id"] not in decoded
            start, count = window["coreFrames"]["start"], window["coreFrames"]["count"]
            assert count > 0 and count <= 320000
            assert through == start + count
            decoded[window["id"]] = window
            core.append((start, start + count)); batch["cores"].append((start, start + count))
            window_measurements.append({"sourceEndSeconds": through / 16000,
                "elapsedSeconds": entry["elapsedSeconds"], "residentBytes": entry["residentBytes"]})
        elif entry["kind"] == "batch_completed":
            assert batch is not None
            completed_batch_count += 1
            assert len(batch["cores"]) == batch["pending"]
            # Coverage is reconstructed from actual engine windows and no-speech
            # ranges, not inferred from the writer's success/completion flag.
            parts = batch["cores"] + batch["noSpeech"]
            assert sum(end - start for start, end in parts) == sum(end - start for start, end in union(parts))
            assert union(parts) == union(batch["coverage"])
            covered.extend(batch["coverage"]); batch = None
    assert batch is None and previous_completed == total
    assert union(covered) == [(0, total)]
    assert sum(end - start for start, end in covered) == total
    unique_core = sum(end - start for start, end in union(core))
    assert unique_core == sum(end - start for start, end in core) == completion["uniqueCoreFrames"]
    assert len(decoded) == completion["completedWindows"] > 0
    assert prepared_count == completed_batch_count == completion["batches"]
    counts = collections.Counter()
    sums = collections.defaultdict(float)
    observed = set()
    probes = {}
    per_window = []
    for item in records(root / "operations.jsonl"):
        phase, value = item["phase"], item["diagnostic"]
        assert phase in {"workload", "native_cancel_probe", "reuse_probe"}
        assert value["operation"] in {"prepare", "transcribe"}
        counts[f"{phase}:{value['operation']}:{value['outcome']}"] += 1
        if phase != "workload":
            assert phase not in probes
            probes[phase] = value
            continue
        assert value["outcome"] == "completed"
        for key in ("elapsedSeconds", "nativeDecodeSeconds", "modelHashSeconds", "modelLoadSeconds", "vadLoadSeconds",
                    "audioHashSeconds", "audioReadSeconds", "audioHashedBytes", "sourceFramesRead", "convertedModelFrames"):
            sums[f"{value['operation']}.{key}"] += value[key]
        if value["operation"] == "transcribe":
            identity = value["windowID"]
            assert identity in decoded and identity not in observed
            observed.add(identity)
            assert value["coreModelFrames"] == decoded[identity]["modelCoreFrames"]["count"]
            assert value["nativeDecodeSeconds"] > 0
            sums["transcribe.discardedPrefixModelFrames"] += value["discardedPrefixModelFrames"]
            per_window.append({"sourceEndSeconds": (decoded[identity]["coreFrames"]["start"] + decoded[identity]["coreFrames"]["count"]) / 16000,
                "elapsedSeconds": value["elapsedSeconds"], "audioReadSeconds": value["audioReadSeconds"],
                "audioHashSeconds": value["audioHashSeconds"], "prefixFrames": value["discardedPrefixModelFrames"]})
    assert observed == set(decoded)
    assert counts["workload:prepare:completed"] == prepared_count
    assert set(probes) == {"native_cancel_probe", "reuse_probe"}
    cancel, reuse = probes["native_cancel_probe"], probes["reuse_probe"]
    assert cancel["operation"] == reuse["operation"] == "transcribe"
    assert cancel["outcome"] == "cancelled" and cancel["cancellationDuringNativeDecode"]
    assert cancel["cancellationToNativeReturnSeconds"] >= 0
    assert reuse["outcome"] == "completed" and cancel["windowID"] == reuse["windowID"]
    assert cancel["windowID"] in decoded
    memory = list(records(root / "rss.jsonl"))
    assert memory and all(item["residentBytes"] > 0 for item in memory)
    assert len(memory) == completion["rss"]["samples"]
    assert max(item["residentBytes"] for item in memory) == completion["rss"]["maximumSampledResidentBytes"]
    quarter = max(1, len(per_window) // 4)
    return {"scope": "independent observation consistency check; not product acceptance or CER",
            "sourceSeconds": metadata["seconds"], "injectedFixtureDutyRatio": metadata["injectedFixtureDutyRatio"],
            "workloadElapsedSeconds": completion["workloadElapsedSeconds"], "windowCount": len(decoded),
            "uniqueCoreSeconds": unique_core / 16000, "operationCounts": dict(counts), "operationSums": dict(sums),
            "prefixToUniqueCoreRatio": sums["transcribe.discardedPrefixModelFrames"] / unique_core,
            "firstQuartileMeanWindowSeconds": sum(x["elapsedSeconds"] for x in per_window[:quarter]) / quarter,
            "lastQuartileMeanWindowSeconds": sum(x["elapsedSeconds"] for x in per_window[-quarter:]) / quarter,
            "firstWindow": per_window[0], "lastWindow": per_window[-1],
            "rss": completion["rss"], "cancellationToNativeReturnSeconds": cancel["cancellationToNativeReturnSeconds"],
            "initialBacklogSeconds": metadata["seconds"], "finalBacklogSeconds": 0}


def run_process(command, log, timeout):
    # No model API credentials are inherited by this local-only tool.
    environment = {key: value for key, value in os.environ.items() if key in {
        "PATH", "HOME", "TMPDIR", "USER", "LOGNAME", "SHELL", "LANG", "LC_ALL", "DEVELOPER_DIR"}}
    with log.open("w") as stream:
        process = subprocess.Popen(command, stdout=stream, stderr=subprocess.STDOUT,
                                   env=environment, start_new_session=True)
        try:
            return process.wait(timeout=timeout)
        finally:
            if process.poll() is None:
                os.killpg(process.pid, signal.SIGTERM)
                try:
                    process.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    os.killpg(process.pid, signal.SIGKILL)
                    process.wait(timeout=10)


def main():
    def terminate(_number, _frame):
        raise SystemExit(143)
    signal.signal(signal.SIGTERM, terminate)
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, required=True)
    parser.add_argument("--model", type=Path, required=True)
    parser.add_argument("--fixture", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--source-version", required=True)
    parser.add_argument("--seconds", type=int, choices=range(60, 7201, 60), required=True)
    parser.add_argument("--speech-duty", type=float, required=True)
    parser.add_argument("--deadline-seconds", type=int, default=900)
    args = parser.parse_args()
    root = args.output.resolve()
    if root.exists():
        raise ValueError("evidence directory must be new")
    root.mkdir(parents=True)
    workload = root / "workload"
    command = [str(args.binary.resolve()), "--diagnostics", str(args.model.resolve()), str(args.fixture.resolve()),
               str(workload), args.source_version, "--seconds", str(args.seconds), "--speech-duty", str(args.speech_duty),
               "--deadline-seconds", str(args.deadline_seconds)]
    report = {"command": command, "scope": "Mac Release local-only offline drain; synthetic repeated public audio", "startedAtUnix": time.time(),
              "binarySHA256": digest(args.binary), "checkerSHA256": digest(Path(__file__))}
    try:
        model = json.loads((args.model / "manifest.json").read_text())
        report["modelHashes"] = {}
        for filename, key in (("model.int8.onnx", "asrSHA256"), ("tokens.txt", "tokensSHA256"), ("silero_vad.onnx", "vadSHA256")):
            actual = digest(args.model / filename)
            assert actual == model[key]
            report["modelHashes"][filename] = actual
        report["prepareExitCode"] = run_process(command + ["--prepare-only"], root / "prepare.log", 180)
        assert report["prepareExitCode"] == 0
        verification = verify_inputs(workload, args.fixture, args.seconds, args.speech_duty)
        save(workload / "input-verification.json", verification)
        report["inferenceStartedAtUnix"] = time.time()
        save(root / "execution-report.json", report)
        report["inferenceExitCode"] = run_process(command + ["--run-prepared"], root / "engine.log", args.deadline_seconds + 30)
        assert report["inferenceExitCode"] == 0
        inspection = inspect(workload)
        inspection["checkerSHA256"] = report["checkerSHA256"]
        save(root / "inspection.json", inspection)
        report["independentInspectionPassed"] = True
        print(json.dumps(inspection, indent=2))
    except BaseException as error:
        report["failure"] = {"type": type(error).__name__, "detail": str(error)}
        raise
    finally:
        report["finishedAtUnix"] = time.time()
        save(root / "execution-report.json", report)


if __name__ == "__main__":
    main()
