"""Negative controls for the J27 evidence checker, without running a model."""
import copy
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

MODULE = Path(__file__).resolve().parents[2] / "Tools/SpeechQuality/stress.py"
spec = importlib.util.spec_from_file_location("speech_stress", MODULE)
stress = importlib.util.module_from_spec(spec)
spec.loader.exec_module(stress)


class StressEvidenceTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        (self.root / "inputs").mkdir()
        stress.save(self.root / "inputs/inputs.json", {})
        stress.save(self.root / "input-verification.json", {"manifestSHA256": stress.digest(self.root / "inputs/inputs.json")})
        stress.save(self.root / "run.json", {"seconds": 60, "injectedFixtureDutyRatio": 1})
        stress.save(self.root / "completion.json", {"status": "completed", "completedThroughFrames": 960000,
            "totalSourceFrames": 960000, "uniqueCoreFrames": 320000, "completedWindows": 1,
            "workloadElapsedSeconds": 2, "batches": 1, "rss": {"samples": 1, "maximumSampledResidentBytes": 1000}})
        self.progress = [
            {"kind": "prepared", "completedThroughFrames": 0, "availableBacklogSeconds": 60,
             "pendingWindows": 1, "analyzedCoverage": [{"start": 0, "count": 960000}], "noSpeechCoverage": [{"start": 320000, "count": 640000}]},
            {"kind": "transcribed", "completedThroughFrames": 320000, "availableBacklogSeconds": 40,
             "elapsedSeconds": 1, "residentBytes": 1000,
             "window": {"id": "window", "coreFrames": {"start": 0, "count": 320000}, "modelCoreFrames": {"count": 320000}}},
            {"kind": "batch_completed", "completedThroughFrames": 960000, "availableBacklogSeconds": 0}]
        value = dict.fromkeys(("elapsedSeconds", "nativeDecodeSeconds", "modelHashSeconds", "modelLoadSeconds", "vadLoadSeconds",
            "audioHashSeconds", "audioReadSeconds", "audioHashedBytes", "sourceFramesRead", "convertedModelFrames",
            "discardedPrefixModelFrames"), 0)
        value.update(operation="transcribe", outcome="completed", windowID="window", coreModelFrames=320000, nativeDecodeSeconds=0.1)
        cancelled = dict(value, outcome="cancelled", cancellationDuringNativeDecode=True, cancellationToNativeReturnSeconds=0.01)
        self.operations = [{"phase": "workload", "diagnostic": value},
            {"phase": "native_cancel_probe", "diagnostic": cancelled}, {"phase": "reuse_probe", "diagnostic": copy.deepcopy(value)},
            {"phase": "workload", "diagnostic": dict(value, operation="prepare", nativeDecodeSeconds=0)}]
        self.write_lines("rss.jsonl", [{"residentBytes": 1000}])

    def write_lines(self, name, values):
        (self.root / name).write_text("".join(json.dumps(value) + "\n" for value in values))

    def inspect(self):
        self.write_lines("progress.jsonl", self.progress)
        self.write_lines("operations.jsonl", self.operations)
        return stress.inspect(self.root)

    def test_consistent_observations_are_accepted(self):
        self.assertEqual(self.inspect()["windowCount"], 1)

    def test_completed_flag_cannot_replace_native_observation(self):
        self.operations.pop(0)
        with self.assertRaises(AssertionError): self.inspect()

    def test_incomplete_source_coverage_is_rejected(self):
        self.progress[0]["noSpeechCoverage"][0]["count"] -= 1
        with self.assertRaises(AssertionError): self.inspect()

    def test_double_counted_window_is_rejected(self):
        self.progress.insert(2, copy.deepcopy(self.progress[1]))
        with self.assertRaises(AssertionError): self.inspect()

    def test_cancellation_without_native_overlap_is_rejected(self):
        self.operations[1]["diagnostic"]["cancellationDuringNativeDecode"] = False
        with self.assertRaises(AssertionError): self.inspect()

    def test_regressing_backlog_is_rejected(self):
        self.progress[2]["completedThroughFrames"] = 1
        with self.assertRaises(AssertionError): self.inspect()

    def test_input_manifest_change_is_rejected(self):
        stress.save(self.root / "inputs/inputs.json", {"changed": True})
        with self.assertRaises(AssertionError): self.inspect()

    def test_missing_prepare_diagnostic_is_rejected(self):
        self.operations.pop()
        with self.assertRaises(AssertionError): self.inspect()

    def test_unknown_phase_is_rejected(self):
        self.operations.append({"phase": "invented", "diagnostic": copy.deepcopy(self.operations[0]["diagnostic"])})
        with self.assertRaises(AssertionError): self.inspect()

    def test_outer_timeout_reaps_the_actual_worker(self):
        pid_file = self.root / "worker.pid"
        program = "import os,pathlib,time; pathlib.Path(__import__('sys').argv[1]).write_text(str(os.getpid())); time.sleep(30)"
        with self.assertRaises(subprocess.TimeoutExpired):
            stress.run_process([sys.executable, "-c", program, str(pid_file)], self.root / "worker.log", 0.5)
        with self.assertRaises(ProcessLookupError): os.kill(int(pid_file.read_text()), 0)


if __name__ == "__main__": unittest.main()
