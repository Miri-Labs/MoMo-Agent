"""TDD Robustness Tests for Mac-side Audio Chunk Ingestion & Transfer Seams.

Covers:
  - Slice 1: Out-of-order Watch/iPhone chunk arrival with duplicate chunk_seq MUST NOT overwrite
    a different chunk_id, and window assembly + listing MUST order by (recorded_at, chunk_id).
    Also tests automatic schema migration of an existing DB created with UNIQUE(source_id, chunk_seq).
  - Slice 3: Matching retransmission MUST repair a missing or corrupted audio file on disk before
    returning an accepted receipt (never blindly deduplicating when bytes are gone/corrupted).
"""
from __future__ import annotations

import hashlib
import sqlite3
import sys
import tempfile
import unittest
import uuid
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO_ROOT / "Apps/MacApp/Context"))

from context_store import ContextStore
from mac_audio_pipeline import MacAudioPipeline


def _fake_wav(seed: bytes, length: int = 4096) -> bytes:
    return b"RIFF" + (seed * (length // len(seed) + 1))[:length]


class FakeSpeechBridge:
    def __init__(self):
        self.transcribed_paths: list[list[str]] = []

    def vad(self, audio_path: str, threshold: float = 0.45) -> dict:
        return {"has_speech": True, "speech_seconds": 10.0, "duration_sec": 30.0, "intervals": [[0.0, 10.0]]}

    def transcribe_window(self, audio_paths: list[str], **kwargs) -> dict:
        self.transcribed_paths.append(list(audio_paths))
        return {
            "segments": [
                {"speaker_tag": "S01", "start_sec": 0.5, "end_sec": 5.0, "text": "第一分钟内容"},
                {"speaker_tag": "S01", "start_sec": 31.0, "end_sec": 35.0, "text": "第二分钟内容"},
            ],
            "speaker_embeddings": [],
        }


class MacAudioTransferRobustnessTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="momo-transfer-tdd-")
        self.data_dir = Path(self.tmp.name) / "agent-data"
        self.ctx_dir = self.data_dir / "context"
        self.ctx_dir.mkdir(parents=True)
        self.store = ContextStore(self.ctx_dir)
        self.pipeline = MacAudioPipeline(self.store, data_dir=self.data_dir)

    def tearDown(self):
        self.store.close()
        self.tmp.cleanup()

    def test_slice1_out_of_order_chunks_with_same_chunk_seq_never_overwrite_each_other(self):
        """Watch delivers minute 2 before minute 1; even if both arrive with chunk_seq=0,
        Mac MUST preserve both distinct chunk_ids and assemble them chronologically by recorded_at."""
        lib_id = str(uuid.uuid4())
        sess_id = str(uuid.uuid4())
        dev_id = str(uuid.uuid4())
        t0 = 1_750_000_000.0

        minute2_id = str(uuid.uuid4())
        minute2_bytes = _fake_wav(b"MINUTE_TWO_")
        minute1_id = str(uuid.uuid4())
        minute1_bytes = _fake_wav(b"MINUTE_ONE_")

        # Minute 2 arrives FIRST with chunk_seq=0 (simulating partial local view on iPhone)
        r2 = self.pipeline.ingest_audio_chunk(
            meta={
                "chunk_id": minute2_id,
                "library_id": lib_id,
                "session_id": sess_id,
                "device_id": dev_id,
                "chunk_seq": 0,
                "recorded_at": t0 + 30.0,
                "duration_sec": 30.0,
                "codec": "wav",
                "sha256": hashlib.sha256(minute2_bytes).hexdigest(),
            },
            audio_bytes=minute2_bytes,
        )
        self.assertTrue(r2["accepted"])

        # Minute 1 arrives LATER, also claiming chunk_seq=0
        r1 = self.pipeline.ingest_audio_chunk(
            meta={
                "chunk_id": minute1_id,
                "library_id": lib_id,
                "session_id": sess_id,
                "device_id": dev_id,
                "chunk_seq": 0,
                "recorded_at": t0,
                "duration_sec": 30.0,
                "codec": "wav",
                "sha256": hashlib.sha256(minute1_bytes).hexdigest(),
            },
            audio_bytes=minute1_bytes,
        )
        self.assertTrue(r1["accepted"])
        self.assertFalse(r1["deduplicated"])

        source_id = f"{lib_id}/{sess_id}"
        listed = self.pipeline.list_source_audio_chunks(source_id)
        self.assertEqual(
            [c["chunk_id"] for c in listed],
            [minute1_id, minute2_id],
            "Both out-of-order chunks must survive and be listed in chronological recorded_at order",
        )
        self.assertTrue(all(c["exists"] for c in listed))

        # Window transcription MUST feed minute 1 BEFORE minute 2
        bridge = FakeSpeechBridge()
        self.pipeline.process_next_batch(bridge, flush_immediately=True)
        self.assertEqual(len(bridge.transcribed_paths), 1)
        ordered_files = bridge.transcribed_paths[0]
        self.assertEqual(len(ordered_files), 2)
        self.assertEqual(Path(ordered_files[0]).read_bytes(), minute1_bytes)
        self.assertEqual(Path(ordered_files[1]).read_bytes(), minute2_bytes)

    def test_slice1_legacy_db_with_unique_source_seq_migrates_cleanly(self):
        """An existing Mac database created before this fix (with UNIQUE(source_id, chunk_seq))
        must automatically migrate without losing existing chunks so out-of-order arrivals succeed."""
        legacy_dir = Path(self.tmp.name) / "legacy-agent"
        legacy_ctx = legacy_dir / "context"
        legacy_ctx.mkdir(parents=True)
        legacy_store = ContextStore(legacy_ctx)
        # Replace audio_chunks with the legacy schema explicitly WITH UNIQUE(source_id, chunk_seq)
        legacy_store.db.executescript(
            """
            DROP TABLE IF EXISTS audio_chunks;
            CREATE TABLE audio_chunks (
                chunk_id TEXT PRIMARY KEY,
                library_id TEXT NOT NULL,
                session_id TEXT NOT NULL,
                source_id TEXT NOT NULL,
                device_id TEXT NOT NULL,
                chunk_seq INTEGER NOT NULL,
                recorded_at REAL NOT NULL,
                duration_sec REAL NOT NULL,
                timezone_offset INTEGER,
                source_kind TEXT NOT NULL DEFAULT 'watch',
                codec TEXT NOT NULL DEFAULT 'aac',
                sample_rate INTEGER NOT NULL DEFAULT 16000,
                sha256 TEXT NOT NULL,
                byte_size INTEGER NOT NULL,
                relative_path TEXT NOT NULL,
                vad_status TEXT NOT NULL DEFAULT 'pending',
                speech_seconds REAL NOT NULL DEFAULT 0.0,
                vad_intervals TEXT NOT NULL DEFAULT '[]',
                transcription_status TEXT NOT NULL DEFAULT 'pending',
                window_id TEXT,
                error TEXT,
                created_at REAL NOT NULL,
                updated_at REAL NOT NULL,
                UNIQUE(source_id, chunk_seq)
            );
            """
        )
        legacy_store._audio_pipeline_schema_ready = False
        try:
            pipe = MacAudioPipeline(legacy_store, data_dir=legacy_dir)
            lib_id, sess_id, dev_id = str(uuid.uuid4()), str(uuid.uuid4()), str(uuid.uuid4())
            b1, b2 = _fake_wav(b"LEGACY_B_"), _fake_wav(b"LEGACY_A_")
            c2_id, c1_id = str(uuid.uuid4()), str(uuid.uuid4())
            pipe.ingest_audio_chunk(
                meta={
                    "chunk_id": c2_id, "library_id": lib_id, "session_id": sess_id, "device_id": dev_id,
                    "chunk_seq": 0, "recorded_at": 1_750_000_030.0, "duration_sec": 30.0, "codec": "wav",
                    "sha256": hashlib.sha256(b1).hexdigest(),
                },
                audio_bytes=b1,
            )
            pipe.ingest_audio_chunk(
                meta={
                    "chunk_id": c1_id, "library_id": lib_id, "session_id": sess_id, "device_id": dev_id,
                    "chunk_seq": 0, "recorded_at": 1_750_000_000.0, "duration_sec": 30.0, "codec": "wav",
                    "sha256": hashlib.sha256(b2).hexdigest(),
                },
                audio_bytes=b2,
            )
            listed = pipe.list_source_audio_chunks(f"{lib_id}/{sess_id}")
            self.assertEqual([c["chunk_id"] for c in listed], [c1_id, c2_id])
        finally:
            legacy_store.close()

    def test_slice3_retransmission_repairs_missing_or_corrupted_disk_audio_before_acknowledging(self):
        """If Mac's stored audio file was deleted or corrupted on disk, a matching SHA-256 retransmission
        MUST rewrite and fsync the file before returning accepted=True."""
        lib_id = str(uuid.uuid4())
        sess_id = str(uuid.uuid4())
        dev_id = str(uuid.uuid4())
        chunk_id = str(uuid.uuid4())
        wav_bytes = _fake_wav(b"REPAIR_ME_")
        sha = hashlib.sha256(wav_bytes).hexdigest()
        meta = {
            "chunk_id": chunk_id,
            "library_id": lib_id,
            "session_id": sess_id,
            "device_id": dev_id,
            "chunk_seq": 0,
            "recorded_at": 1_750_000_000.0,
            "duration_sec": 15.0,
            "codec": "wav",
            "sha256": sha,
        }
        first = self.pipeline.ingest_audio_chunk(meta=meta, audio_bytes=wav_bytes)
        self.assertTrue(first["accepted"] and not first["deduplicated"])

        row = self.store.db.execute("SELECT relative_path FROM audio_chunks WHERE chunk_id=?", (chunk_id,)).fetchone()
        stored_file = self.store.directory / row["relative_path"]
        self.assertTrue(stored_file.is_file())

        # Case A: File vanishes on disk -> retransmission must restore it!
        stored_file.unlink()
        self.assertFalse(stored_file.is_file())
        second = self.pipeline.ingest_audio_chunk(meta=meta, audio_bytes=wav_bytes)
        self.assertTrue(second["accepted"])
        self.assertTrue(stored_file.is_file(), "Retransmission must restore missing audio file on disk")
        self.assertEqual(stored_file.read_bytes(), wav_bytes)

        # Case B: File is truncated/corrupted on disk AND VAD already marked failed -> retransmission must repair AND re-queue!
        stored_file.write_bytes(b"CORRUPT")
        with self.store.write():
            self.store.db.execute(
                "UPDATE audio_chunks SET vad_status='error', transcription_status='failed', error='Missing audio file' WHERE chunk_id=?",
                (chunk_id,),
            )
        third = self.pipeline.ingest_audio_chunk(meta=meta, audio_bytes=wav_bytes)
        self.assertTrue(third["accepted"])
        self.assertTrue(third["repaired"])
        self.assertEqual(third["transcription_status"], "pending", "Repaired failed chunk must reset to pending for VAD/transcription")
        self.assertEqual(stored_file.read_bytes(), wav_bytes, "Retransmission must repair corrupted audio file on disk")


if __name__ == "__main__":
    unittest.main()
