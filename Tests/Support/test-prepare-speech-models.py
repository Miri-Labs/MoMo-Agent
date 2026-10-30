# /// script
# requires-python = ">=3.12"
# ///
"""Offline checks for unchanged published speech model artifacts."""
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import tarfile
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("prepare_models", ROOT / "Native/SpeechVendor/prepare-models.py")
prepare = importlib.util.module_from_spec(spec)
spec.loader.exec_module(prepare)


class SpeechPreparationTests(unittest.TestCase):
    @staticmethod
    def _seed_speakers(vendor: Path, models: Path):
        speakers_dir = models / "Speakers"
        speakers_dir.mkdir(parents=True, exist_ok=True)
        files = {}
        sources = {}
        for name in ("eres2netv2.onnx", "diarizen-wavlm-base-s80-md.onnx", "segmentation-community-1.onnx"):
            payload = ("speaker " + name).encode()
            (speakers_dir / name).write_bytes(payload)
            files[name] = hashlib.sha256(payload).hexdigest()
            sources[name] = {"url": "https://example.invalid/" + name}
        (vendor / "speaker-manifest.json").write_text(json.dumps({"schemaVersion": 2, "files": files, "sources": sources}))

    def test_vad_upgrade_replaces_symlink_only_after_verification(self):
        for corrupt in (False, True):
            with self.subTest(corrupt=corrupt), tempfile.TemporaryDirectory() as temp:
                root = Path(temp)
                vendor, models, scratch = (root / name for name in ("vendor", "models", "scratch"))
                vendor.mkdir(); models.mkdir(); (vendor / "Licenses").mkdir()
                self._seed_speakers(vendor, models)
                pins = {"schemaVersion": 1}
                for name, key in (("model.int8.onnx", "asrSHA256"), ("tokens.txt", "tokensSHA256")):
                    payload = name.encode()
                    (models / name).write_bytes(payload)
                    pins[key] = hashlib.sha256(payload).hexdigest()
                published = b"published v6 bytes"
                pins["vadSHA256"] = hashlib.sha256(published).hexdigest()
                (vendor / "manifest.json").write_text(json.dumps(pins))
                (models / "manifest.json").write_text("old manifest")
                old = root / "shared-v4.onnx"
                old.write_bytes(b"shared v4 bytes")
                (models / "silero_vad.onnx").symlink_to(old)
                def curl(command, **_kwargs):
                    self.assertEqual(command[-1], prepare.VAD_URL)
                    destination = Path(command[command.index("--output") + 1])
                    destination.write_bytes(b"corrupt" if corrupt else published)
                with patch.object(prepare, "ROOT", vendor), patch.object(prepare.subprocess, "run", side_effect=curl):
                    if corrupt:
                        with self.assertRaisesRegex(ValueError, "Checksum mismatch"):
                            prepare.prepare(models, scratch)
                    else:
                        prepare.prepare(models, scratch)
                self.assertEqual(old.read_bytes(), b"shared v4 bytes")
                if corrupt:
                    self.assertTrue((models / "silero_vad.onnx").is_symlink())
                    self.assertEqual((models / "manifest.json").read_text(), "old manifest")
                else:
                    self.assertFalse((models / "silero_vad.onnx").is_symlink())
                    self.assertEqual((models / "silero_vad.onnx").read_bytes(), published)
                    self.assertEqual(json.loads((models / "manifest.json").read_text()), pins)

    def test_verified_files_are_reused_without_downloading(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            vendor, models, scratch = (root / name for name in ("vendor", "models", "scratch"))
            vendor.mkdir(); models.mkdir(); (vendor / "Licenses").mkdir()
            self._seed_speakers(vendor, models)
            pins = {"schemaVersion": 1}
            for name, key in (("model.int8.onnx", "asrSHA256"), ("tokens.txt", "tokensSHA256"), ("silero_vad.onnx", "vadSHA256")):
                data = ("unchanged " + name).encode()
                (models / name).write_bytes(data)
                pins[key] = hashlib.sha256(data).hexdigest()
            (vendor / "manifest.json").write_text(json.dumps(pins))
            with patch.object(prepare, "ROOT", vendor), patch.object(prepare, "download", side_effect=AssertionError("Unexpected download")):
                prepare.prepare(models, scratch)
            self.assertEqual(json.loads((models / "manifest.json").read_text()), pins)
            self.assertFalse(any(models.rglob("*.mlmodelc")))

    def test_corrupt_archive_member_does_not_replace_verified_model(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            vendor, models, scratch = (root / name for name in ("vendor", "models", "scratch"))
            vendor.mkdir(); models.mkdir()
            self._seed_speakers(vendor, models)
            pins = dict(asrSHA256="a" * 64, tokensSHA256="b" * 64, vadSHA256="c" * 64)
            (vendor / "manifest.json").write_text(json.dumps(pins))
            def corrupt_download(_url, destination, _expected):
                with tarfile.open(destination, "w:bz2") as archive:
                    payload = b"corrupt model"
                    member = tarfile.TarInfo(prepare.MODEL + "/model.int8.onnx")
                    member.size = len(payload)
                    archive.addfile(member, io.BytesIO(payload))
            with patch.object(prepare, "ROOT", vendor), patch.object(prepare, "download", side_effect=corrupt_download):
                with self.assertRaisesRegex(ValueError, "Checksum mismatch"):
                    prepare.prepare(models, scratch)
            self.assertFalse((models / "model.int8.onnx").exists())
            self.assertFalse((models / "manifest.json").exists())

    def test_missing_speaker_model_downloads_and_verifies_checksum(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            vendor, models, scratch = (root / name for name in ("vendor", "models", "scratch"))
            vendor.mkdir(); models.mkdir(); (vendor / "Licenses").mkdir()
            self._seed_speakers(vendor, models)
            missing = models / "Speakers" / "eres2netv2.onnx"
            expected_bytes = missing.read_bytes()
            missing.unlink()
            pins = {"schemaVersion": 1}
            for name, key in (("model.int8.onnx", "asrSHA256"), ("tokens.txt", "tokensSHA256"), ("silero_vad.onnx", "vadSHA256")):
                data = ("unchanged " + name).encode()
                (models / name).write_bytes(data)
                pins[key] = hashlib.sha256(data).hexdigest()
            (vendor / "manifest.json").write_text(json.dumps(pins))
            def curl(command, **_kwargs):
                self.assertEqual(command[-1], "https://example.invalid/eres2netv2.onnx")
                destination = Path(command[command.index("--output") + 1])
                destination.write_bytes(expected_bytes)
            with patch.object(prepare, "ROOT", vendor), patch.object(prepare.subprocess, "run", side_effect=curl):
                prepare.prepare(models, scratch)
            self.assertEqual(missing.read_bytes(), expected_bytes)


if __name__ == "__main__":
    unittest.main()
