"""Corruption/negative controls for the offline D3 corpus validator; no model or Archive calls."""

import copy
import importlib.util
import json
from pathlib import Path
import shutil
import tempfile
import unittest

SOURCE = Path(__file__).with_name("verify-agent-quality-corpus.py")
SPEC = importlib.util.spec_from_file_location("quality_corpus", SOURCE)
VERIFY = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(VERIFY)
CORPUS = SOURCE.parents[2] / "Tests/Fixtures/AgentQuality"


class CorpusValidationTests(unittest.TestCase):
    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory(prefix="momo-corpus-check-")
        self.addCleanup(self.scratch.cleanup)
        self.directory = Path(self.scratch.name)
        for name in ("manifest.json", "development.json", "holdout.json"):
            shutil.copyfile(CORPUS / name, self.directory / name)

    def load(self, split="development"):
        return json.loads((self.directory / f"{split}.json").read_text())

    def write(self, payload, *, refreeze=True):
        """Only rehash the scratch copy so malformed data reaches semantic schema checks."""
        path = self.directory / f"{payload['split']}.json"
        path.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n")
        if refreeze:
            manifest_path = self.directory / "manifest.json"
            manifest = json.loads(manifest_path.read_text())
            manifest["files"][path.name] = {
                "sha256": VERIFY.hashlib.sha256(path.read_bytes()).hexdigest(),
                "canonicalSHA256": VERIFY.digest(payload), "caseCount": len(payload["cases"]),
            }
            for case in payload["cases"]:
                manifest["caseHashes"][case["id"]] = VERIFY.digest(case)
            manifest["corpusSHA256"] = VERIFY.digest({key: manifest[key] for key in ("files", "legacyCases", "caseHashes")})
            manifest_path.write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n")

    def change_case(self, id, change, split="development"):
        payload = self.load(split)
        case = next(case for case in payload["cases"] if case["id"] == id)
        change(case)
        self.write(payload)

    def rejected(self, reason):
        with self.assertRaisesRegex(VERIFY.InvalidCorpus, reason):
            VERIFY.validate(self.directory)

    def test_frozen_32_and_legacy_catalog_without_execution_claim(self):
        result = VERIFY.validate(self.directory)
        self.assertEqual(result["newJSONCases"], 32)
        self.assertEqual(result["catalogTotalIncludingLegacy"], 40)
        self.assertEqual(result["newHostedCases"], 0)
        self.assertFalse(result["archiveAPIsExecuted"])
        self.assertFalse(result["legacyRuntimeHashesRechecked"])

    def test_one_byte_holdout_change_rejected_without_refreeze(self):
        path = self.directory / "holdout.json"
        path.write_bytes(path.read_bytes() + b" ")
        self.rejected("frozen file changed")

    def test_pending_source_must_not_have_hidden_transcript(self):
        self.change_case("d3-delivery-pending", lambda c: c["recordings"][0]["chunks"][0].update(text="不得注入的事实"))
        self.rejected("unavailable audio")

    def test_partial_cannot_complete_successor_before_predecessor(self):
        self.change_case("d3-same-recording-partial", lambda c: c["recordings"][0]["chunks"].reverse())
        self.rejected("unprocessed predecessor")

    def test_pending_chunk_cannot_be_a_plan_source(self):
        self.change_case("d3-same-recording-partial", lambda c: c["request"]["allowedSourceKeys"].append("venue-last"))
        self.rejected("unavailable source")

    def test_fact_cannot_claim_support_from_unavailable_chunk(self):
        self.change_case("d3-delivery-pending", lambda c: c["facts"]["required"][0]["evidenceKeys"].append("delivery-window"))
        self.rejected("unavailable text")

    def test_real_manifest_offset_cannot_be_null(self):
        self.change_case("d3-holdout-unknown-zone-subject", lambda c: c["recordings"][0].update(timezoneOffsetSeconds=None), "holdout")
        self.rejected("real timezone offset")

    def test_empty_text_is_not_no_speech(self):
        self.change_case("d3-holdout-empty-transcript", lambda c: c["archiveExpectations"]["statesByRecording"].update(inventory="noSpeech"), "holdout")
        self.rejected("Archive state mismatch")

    def test_deleted_source_cannot_remain_readable(self):
        self.change_case("d3-holdout-deleted-source", lambda c: c["request"]["allowedSourceKeys"].append("deleted"), "holdout")
        self.rejected("unavailable source")

    def test_revision_must_preserve_real_source_keys(self):
        self.change_case("d3-revised-before-send", lambda c: c["recordings"][0]["mutation"]["replacementTexts"].update(fabricated="新内容"))
        self.rejected("preserve actual source frames")

    def test_pair_negative_hidden_literal_not_in_prompt(self):
        self.change_case("d3-delivery-pending", lambda c: c["request"].update(prompt=c["request"]["prompt"] + "地点是南汀服务站。"))
        self.rejected("withheld literal leaked")

    def test_pair_tasks_must_remain_identical(self):
        self.change_case("d3-delivery-ready", lambda c: c["request"].update(prompt=c["request"]["prompt"] + "另外写首诗。"))
        self.rejected("paired tasks differ")

    def test_readonly_case_cannot_allow_write(self):
        self.change_case("d3-draft-only-boundary", lambda c: c["request"]["allowedTools"].append("write_plan"))
        self.rejected("write authorization mismatch")

    def test_page_count_must_fit_existing_admission_limit(self):
        self.change_case("d3-old-paged-record", lambda c: c["recordings"][0]["chunks"][0].update(text="目录检查记录。" * 1000))
        self.rejected("production admission budget")

    def test_production_limits_cannot_be_relaxed(self):
        path = self.directory / "manifest.json"
        manifest = json.loads(path.read_text())
        manifest["execution"]["maximumModelAdmissionsPerCase"] = 13
        path.write_text(json.dumps(manifest, ensure_ascii=False))
        self.rejected("budget changed")

    def test_extra_manifest_file_paths_rejected(self):
        path = self.directory / "manifest.json"
        manifest = json.loads(path.read_text())
        manifest["files"]["../../unrelated.json"] = copy.deepcopy(manifest["files"]["development.json"])
        path.write_text(json.dumps(manifest, ensure_ascii=False))
        self.rejected("unexpected corpus file paths")

    def test_runtime_state_is_not_claimed_from_offline_data(self):
        path = self.directory / "manifest.json"
        manifest = json.loads(path.read_text())
        manifest["execution"]["newHostedCases"] = 32
        path.write_text(json.dumps(manifest, ensure_ascii=False))
        self.rejected("execution claim")


if __name__ == "__main__":
    unittest.main()
