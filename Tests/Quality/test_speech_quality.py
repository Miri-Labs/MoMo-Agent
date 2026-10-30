"""Small local checks for corpus integrity and scoring, independent of ASR output."""

import hashlib
import io
from pathlib import Path
import sys
import tarfile
import tempfile
import unittest
from unittest.mock import patch
import wave

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "Tools" / "SpeechQuality"))
import corpus
import score


def item(index, gender="MALE", frames=16_000):
    return dict(id=str(index), sentenceID=str(index), filename=f"{index}.wav", gender=gender,
                frames=frames, reference=f"第{index}句", rawReference=f"第{index}句。", sha256="a" * 64)


def wav(frames):
    data = io.BytesIO()
    with wave.open(data, "wb") as output:
        output.setnchannels(1)
        output.setsampwidth(2)
        output.setframerate(16_000)
        output.writeframes(b"\x00\x00" * frames)
    return data.getvalue()


def archive_bytes(entries):
    output = io.BytesIO()
    with tarfile.open(fileobj=output, mode="w:gz") as archive:
        for name, data, is_link in entries:
            member = tarfile.TarInfo(name)
            if is_link:
                member.type = tarfile.SYMTYPE
                member.linkname = "/outside.wav"
                archive.addfile(member)
            else:
                member.size = len(data)
                archive.addfile(member, io.BytesIO(data))
    return output.getvalue()


class SelectionTests(unittest.TestCase):
    def test_selection_balances_duration_and_never_reuses_a_sentence(self):
        rows = []
        for index in range(30):
            for gender in ["MALE", "FEMALE"]:
                entry = item(index, gender)
                entry["filename"] = f"{index}-{gender}.wav"
                rows.append(entry)
        selected = corpus.select(rows, seconds_per_gender=10)
        self.assertEqual(len({row["sentenceID"] for row in selected}), 20)
        self.assertEqual(corpus.statistics(selected)["genderFrames"], {"MALE": 160_000, "FEMALE": 160_000})
        self.assertEqual(selected, corpus.select(list(reversed(rows)), seconds_per_gender=10))

    def test_exact_selection_rejects_impossible_duration(self):
        with self.assertRaises(ValueError):
            corpus.exact_duration([item(1, frames=640), item(2, frames=640)], 960)

    def test_prepared_reference_cannot_replace_the_frozen_reference(self):
        selection = dict(revision="fixed", items=[item(1)])
        manifest = {**selection, "status": "prepared", "items": [{**item(1), "reference": "替换的文字"}]}
        with self.assertRaisesRegex(ValueError, "frozen selection"):
            corpus.validate_manifest(manifest, selection)

    def test_source_frame_count_is_not_inferred_from_file_size(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "one.wav"
            path.write_bytes(wav(512))
            self.assertEqual(corpus.wav_info(path), {"frames": 512, "codec": "pcmInt16"})
            path.write_bytes(path.read_bytes()[:-1])
            with self.assertRaises(ValueError):
                corpus.wav_info(path)

    def test_stream_extracts_only_whitelist_and_checks_complete_archive(self):
        selected = [item(1, frames=512)]
        data = archive_bytes([("test/2.wav", wav(320), False), ("test/1.wav", wav(512), False)])
        identity = dict(byteCount=len(data), sha256=hashlib.sha256(data).hexdigest())
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            result = corpus.extract_selected(io.BytesIO(data), identity, selected, root)
            self.assertEqual([row["id"] for row in result], ["1"])
            self.assertFalse((root / "audio/2.wav").exists())
            self.assertEqual(result[0]["sha256"], hashlib.sha256(wav(512)).hexdigest())
            with self.assertRaisesRegex(ValueError, "archive checksum"):
                corpus.extract_selected(io.BytesIO(data), {**identity, "sha256": "0" * 64}, selected, root)

    def test_symlinks_and_frame_mismatch_fail_before_publication(self):
        for entry in [("test/1.wav", b"", True), ("../1.wav", wav(512), False), ("test/1.wav", wav(320), False)]:
            with self.subTest(entry=entry[0]), tempfile.TemporaryDirectory() as directory:
                data = archive_bytes([entry])
                identity = dict(byteCount=len(data), sha256=hashlib.sha256(data).hexdigest())
                with self.assertRaises(ValueError):
                    corpus.extract_selected(io.BytesIO(data), identity, [item(1, frames=512)], Path(directory))
                self.assertFalse((Path(directory) / "manifest.json").exists())

    def test_low_disk_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            usage = type("Usage", (), {"free": 10})()
            with patch("corpus.shutil.disk_usage", return_value=usage), self.assertRaises(ValueError):
                corpus.check_space(Path(directory), 20)


class ScoringTests(unittest.TestCase):
    def test_normalization_keeps_numeric_and_language_errors(self):
        self.assertEqual(score.normalize("ＡＢＣ， ９点！"), "abc9点")
        self.assertNotEqual(score.normalize("九点"), score.normalize("9点"))
        self.assertNotEqual(score.normalize("發現"), score.normalize("发现"))
        self.assertNotEqual(score.normalize("café"), score.normalize("cafe"))
        self.assertEqual(score.normalize("￥9 + 5"), "¥9+5")

    def test_edit_counts_cover_substitution_insertion_deletion_and_empty(self):
        self.assertEqual(score.edits("甲乙", "甲丙")["substitutions"], 1)
        self.assertEqual(score.edits("甲", "甲乙")["insertions"], 1)
        self.assertEqual(score.edits("甲乙", "乙")["deletions"], 1)
        self.assertEqual(score.edits("甲乙", "")["cer"], 1.0)
        self.assertEqual(score.edits("", "甲")["cer"], None)

    def test_failed_or_missing_items_remain_in_denominator(self):
        manifest = dict(sampleRate=16_000, items=[item(1), item(2), item(3)])
        outputs = [dict(id="1", sentenceID="1", audioSHA256="a" * 64,
                        text="第1句", status="completed", elapsedSeconds=0.1),
                   dict(id="2", sentenceID="2", audioSHA256="a" * 64,
                        text="第2句", status="error", elapsedSeconds=0.1, error="decode failed")]
        report, rows = score.evaluate(manifest, outputs, None)
        self.assertEqual(report["status"], "incomplete")
        self.assertEqual(report["normalizedCER"]["referenceCharacters"], 9)
        self.assertAlmostEqual(report["normalizedCER"]["cer"], 2 / 3)
        self.assertEqual(rows[1]["hypothesis"], "第2句")
        self.assertEqual(rows[1]["scoredHypothesis"], "")
        self.assertIsNone(report["vadMissRate"])
        self.assertIsNone(report["rtf"])

    def test_duplicate_unknown_and_changed_audio_cannot_be_scored(self):
        manifest = dict(sampleRate=16_000, items=[item(1)])
        row = dict(id="1", sentenceID="1", audioSHA256="a" * 64,
                   text="第1句", status="completed", elapsedSeconds=0.1)
        for outputs in [[row, row], [{**row, "id": "2"}], [{**row, "audioSHA256": "b" * 64}]]:
            with self.subTest(outputs=outputs), self.assertRaises(ValueError):
                score.evaluate(manifest, outputs, None)

    def test_complete_result_is_measurement_without_invented_pass_threshold(self):
        manifest = dict(sampleRate=16_000, items=[item(1)])
        output = dict(id="1", sentenceID="1", audioSHA256="a" * 64,
                      text="第1句", status="completed", elapsedSeconds=0.1)
        report, _ = score.evaluate(manifest, [output], dict(completedCount=1, errorCount=0, elapsedSeconds=0.2))
        self.assertEqual(report["status"], "complete")
        self.assertEqual(report["normalizedCER"]["cer"], 0)
        self.assertEqual(report["acceptance"], "not_evaluated")


if __name__ == "__main__":
    unittest.main()
