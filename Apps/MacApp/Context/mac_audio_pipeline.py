"""Mac-as-Backend Audio Ingestion, Single-Pass CoreML Transcription, Range Streaming & Remote Settings.

Pipeline architecture:
  1. iPhone/Watch/Mac uploads 60s AAC chunks (~180 KB) idempotently to `POST /v1/audio/chunks`
     (SHA-256 verified, stored under `context/audio/<YYYY-MM-DD>/<session_id>/<chunk_seq>.m4a`).
  2. Single-pass Mac dispatch worker runs Silero VAD CoreML on each new chunk:
       - Pure silence chunks are immediately marked `silent` (no MOSS invocation).
       - Speech chunks are grouped into bounded natural conversation windows (<= 180s speech or
         closed when trailing silence / gap >= 12s or session ends).
       - Each window is sent ONCE to native `MoMoMacSpeech` loopback server (`127.0.0.1:<port+3>`)
         running MOSS-Transcribe-Diarize 0.9B CoreML (with dynamic hotwords) + ReDimNet2+ CoreML.
  3. Speaker embeddings are matched via `VoiceprintStore` (enrolled profiles + session continuity),
     and authoritative transcript spans (preserving exact `wall_clock_anchor`, `timezone_offset`,
     `span_id` UUIDs) are committed directly into `ContextStore.sources`, triggering MoMo's
     existing proactive/memory/summary/illustration pipeline!
"""
from __future__ import annotations

import datetime as _dt
import hashlib
import json
import logging
import mimetypes
import os
import re
import sqlite3
import tempfile
import time
import urllib.error
import urllib.request
import uuid
from pathlib import Path
from typing import Any

from voiceprint_store import VoiceprintStore

DEFAULT_SPEECH_SETTINGS: dict[str, Any] = {
    "enabled": True,
    "paused": False,
    "vad_threshold": 0.45,
    "speaker_lock_threshold": 0.56,
    "speaker_lock_margin": 0.08,
    "window_max_seconds": 180,
    "window_flush_silence_seconds": 12,
    "language_hint": "auto",
    "custom_hotwords": [],
    "audio_retention_days": 30,
    "audio_max_gb": 10.0,
    "auto_enroll_from_confirm": True,
}


def init_audio_pipeline_schema(db: sqlite3.Connection) -> None:
    db.executescript(
        """
        CREATE TABLE IF NOT EXISTS audio_chunks (
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
        CREATE INDEX IF NOT EXISTS idx_audio_chunks_status ON audio_chunks(transcription_status, recorded_at);
        CREATE INDEX IF NOT EXISTS idx_audio_chunks_source ON audio_chunks(source_id, chunk_seq);

        CREATE TABLE IF NOT EXISTS transcription_windows (
            window_id TEXT PRIMARY KEY,
            source_id TEXT NOT NULL,
            library_id TEXT NOT NULL,
            session_id TEXT NOT NULL,
            chunk_ids TEXT NOT NULL,
            start_at REAL NOT NULL,
            end_at REAL NOT NULL,
            timezone_offset INTEGER,
            status TEXT NOT NULL DEFAULT 'pending',
            raw_text TEXT,
            duration_sec REAL DEFAULT 0.0,
            elapsed_sec REAL DEFAULT 0.0,
            error TEXT,
            created_at REAL NOT NULL,
            finished_at REAL
        );
        CREATE INDEX IF NOT EXISTS idx_tx_windows_source ON transcription_windows(source_id, start_at);

        CREATE TABLE IF NOT EXISTS speech_settings (
            key TEXT PRIMARY KEY,
            value TEXT NOT NULL,
            updated_at REAL NOT NULL
        );
        """
    )


class MacSpeechBridgeClient:
    """Thin loopback HTTP client talking to native Swift `MoMoMacSpeech` (`127.0.0.1:<port+3>`)."""

    def __init__(self, speech_url: str, api_key: str):
        self.speech_url = speech_url.rstrip("/")
        self.api_key = api_key
        self._opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))

    def _call(self, method: str, path: str, body: dict | None = None, timeout: float = 180.0) -> dict[str, Any]:
        headers = {"Authorization": f"Bearer {self.api_key}"}
        data = None
        if body is not None:
            headers["Content-Type"] = "application/json"
            data = json.dumps(body, ensure_ascii=False).encode("utf-8")
        req = urllib.request.Request(self.speech_url + path, data=data, headers=headers, method=method)
        with self._opener.open(req, timeout=timeout) as resp:
            return json.loads(resp.read().decode("utf-8"))

    def health(self, timeout: float = 3.0) -> dict[str, Any]:
        return self._call("GET", "/internal/v1/health", timeout=timeout)

    def vad(self, audio_path: str, threshold: float = 0.45) -> dict[str, Any]:
        return self._call("POST", "/internal/v1/vad", {"audio_path": audio_path, "threshold": threshold}, timeout=30.0)

    def transcribe_window(
        self,
        audio_paths: list[str],
        *,
        hotwords: list[str] | None = None,
        language_hint: str | None = None,
        extract_speaker_embeddings: bool = True,
    ) -> dict[str, Any]:
        return self._call(
            "POST",
            "/internal/v1/transcribe-window",
            {
                "audio_paths": audio_paths,
                "hotwords": hotwords or [],
                "language_hint": language_hint,
                "extract_speaker_embeddings": extract_speaker_embeddings,
                "allow_bisect_retry": True,
            },
            timeout=300.0,
        )

    def embed(
        self,
        audio_path: str,
        *,
        start_sec: float | None = None,
        end_sec: float | None = None,
        apply_vad: bool = True,
        min_seconds: float = 1.6,
    ) -> dict[str, Any]:
        payload: dict[str, Any] = {
            "audio_path": audio_path,
            "apply_vad": apply_vad,
            "min_seconds": min_seconds,
        }
        if start_sec is not None and end_sec is not None and end_sec > start_sec:
            payload["start_sec"] = start_sec
            payload["end_sec"] = end_sec
        return self._call("POST", "/internal/v1/embed", payload, timeout=60.0)

    def dictate(self, audio_path: str, hotwords: list[str] | None = None) -> dict[str, Any]:
        return self._call(
            "POST",
            "/internal/v1/dictate",
            {"audio_path": audio_path, "hotwords": hotwords or []},
            timeout=120.0,
        )

    def unload(self) -> dict[str, Any]:
        return self._call("POST", "/internal/v1/unload", {}, timeout=10.0)


class MacAudioPipeline:
    def __init__(self, context_store, data_dir: Path | None = None):
        self.store = context_store
        self.db = context_store.db
        self.data_dir = Path(data_dir) if data_dir else context_store.directory.parent
        self.audio_root = context_store.directory / "audio"
        self.audio_root.mkdir(parents=True, exist_ok=True)
        if not getattr(context_store, "_audio_pipeline_schema_ready", False):
            init_audio_pipeline_schema(self.db)
            context_store._audio_pipeline_schema_ready = True
        self.voiceprints = VoiceprintStore(context_store, data_dir=self.data_dir)

    def recover_interrupted(self) -> int:
        """Resets any chunks/windows left in 'processing'/'running' after a crash or app quit."""
        now = time.time()
        with self.store.write():
            recovered = self.db.execute(
                "UPDATE audio_chunks SET transcription_status='pending', error=NULL, updated_at=? WHERE transcription_status='processing'",
                (now,),
            ).rowcount
            self.db.execute(
                "UPDATE transcription_windows SET status='failed', error='Recovered after restart', finished_at=? WHERE status='running'",
                (now,),
            )
        return recovered

    # ------------------------------------------------------------------
    # Remote Speech Settings (Editable from both Mac and iPhone)
    # ------------------------------------------------------------------

    def read_settings(self) -> dict[str, Any]:
        settings = dict(DEFAULT_SPEECH_SETTINGS)
        for row in self.db.execute("SELECT key, value FROM speech_settings"):
            try:
                settings[row["key"]] = json.loads(row["value"])
            except Exception:
                pass
        return settings

    def update_settings(self, patch: dict[str, Any]) -> dict[str, Any]:
        if not isinstance(patch, dict):
            raise ValueError("Speech settings patch must be a JSON object")
        current = self.read_settings()
        now = time.time()
        updates: dict[str, Any] = {}

        if "enabled" in patch:
            updates["enabled"] = bool(patch["enabled"])
        if "paused" in patch:
            updates["paused"] = bool(patch["paused"])
        if "vad_threshold" in patch:
            v = float(patch["vad_threshold"])
            if not 0.1 <= v <= 0.9:
                raise ValueError("vad_threshold must be between 0.1 and 0.9")
            updates["vad_threshold"] = round(v, 3)
        if "speaker_lock_threshold" in patch:
            v = float(patch["speaker_lock_threshold"])
            if not 0.35 <= v <= 0.85:
                raise ValueError("speaker_lock_threshold must be between 0.35 and 0.85")
            updates["speaker_lock_threshold"] = round(v, 3)
        if "speaker_lock_margin" in patch:
            v = float(patch["speaker_lock_margin"])
            if not 0.0 <= v <= 0.30:
                raise ValueError("speaker_lock_margin must be between 0.0 and 0.30")
            updates["speaker_lock_margin"] = round(v, 3)
        if "window_max_seconds" in patch:
            v = int(patch["window_max_seconds"])
            if not 30 <= v <= 300:
                raise ValueError("window_max_seconds must be between 30 and 300")
            updates["window_max_seconds"] = v
        if "window_flush_silence_seconds" in patch:
            v = int(patch["window_flush_silence_seconds"])
            if not 4 <= v <= 60:
                raise ValueError("window_flush_silence_seconds must be between 4 and 60")
            updates["window_flush_silence_seconds"] = v
        if "language_hint" in patch:
            v = str(patch["language_hint"] or "auto").strip()[:32] or "auto"
            updates["language_hint"] = v
        if "custom_hotwords" in patch:
            raw_hw = patch["custom_hotwords"]
            if not isinstance(raw_hw, list) or len(raw_hw) > 100:
                raise ValueError("custom_hotwords must be a list of at most 100 terms")
            clean = []
            seen = set()
            for item in raw_hw:
                t = str(item or "").strip()
                if t and len(t) <= 40 and t.casefold() not in seen:
                    seen.add(t.casefold())
                    clean.append(t)
            updates["custom_hotwords"] = clean
        if "audio_retention_days" in patch:
            v = int(patch["audio_retention_days"])
            if not 1 <= v <= 365:
                raise ValueError("audio_retention_days must be between 1 and 365")
            updates["audio_retention_days"] = v
        if "audio_max_gb" in patch:
            v = float(patch["audio_max_gb"])
            if not 0.5 <= v <= 200.0:
                raise ValueError("audio_max_gb must be between 0.5 and 200.0")
            updates["audio_max_gb"] = round(v, 2)
        if "auto_enroll_from_confirm" in patch:
            updates["auto_enroll_from_confirm"] = bool(patch["auto_enroll_from_confirm"])

        if updates:
            with self.store.write():
                for k, v in updates.items():
                    self.db.execute(
                        """
                        INSERT INTO speech_settings(key, value, updated_at)
                        VALUES(?,?,?)
                        ON CONFLICT(key) DO UPDATE SET value=excluded.value, updated_at=excluded.updated_at
                        """,
                        (k, json.dumps(v, ensure_ascii=False), now),
                    )
                self.store.advance()
            current.update(updates)
        return current

    # ------------------------------------------------------------------
    # Audio Chunk Ingestion & Status (Idempotent SHA-256)
    # ------------------------------------------------------------------

    def ingest_audio_chunk(
        self,
        *,
        meta: dict[str, Any],
        audio_bytes: bytes,
    ) -> dict[str, Any]:
        if not audio_bytes or len(audio_bytes) > 7_500_000:
            raise ValueError("Audio chunk size must be between 1 byte and 7.5 MB")
        library_id = str(uuid.UUID(str(meta["library_id"]))).lower()
        session_id = str(uuid.UUID(str(meta["session_id"]))).lower()
        device_id = str(uuid.UUID(str(meta.get("device_id") or meta["library_id"]))).lower()
        chunk_id = str(meta.get("chunk_id") or f"{session_id}:{int(meta['chunk_seq']):06d}").strip()
        chunk_seq = int(meta["chunk_seq"])
        if chunk_seq < 0:
            raise ValueError("chunk_seq must be >= 0")
        recorded_at = float(meta["recorded_at"])
        duration_sec = float(meta.get("duration_sec") or 60.0)
        if duration_sec <= 0 or duration_sec > 3600:
            raise ValueError("duration_sec out of range")
        tz_offset = meta.get("timezone_offset")
        if tz_offset is not None:
            tz_offset = int(tz_offset)
        source_kind = str(meta.get("source_kind") or "watch").strip()[:32]
        codec = str(meta.get("codec") or "aac").strip().lower()[:16]
        sample_rate = int(meta.get("sample_rate") or 16000)

        actual_sha = hashlib.sha256(audio_bytes).hexdigest()
        expected_sha = str(meta.get("sha256") or "").strip().lower()
        if expected_sha and expected_sha != actual_sha:
            raise ValueError(f"Audio chunk SHA-256 mismatch: expected {expected_sha[:12]}, got {actual_sha[:12]}")

        source_id = f"{library_id}/{session_id}"
        existing = self.db.execute(
            "SELECT chunk_id, sha256, transcription_status, relative_path FROM audio_chunks WHERE chunk_id=? OR (source_id=? AND chunk_seq=?)",
            (chunk_id, source_id, chunk_seq),
        ).fetchone()
        if existing and existing["sha256"] == actual_sha:
            return {
                "accepted": True,
                "deduplicated": True,
                "chunk_id": existing["chunk_id"],
                "source_id": source_id,
                "sha256": actual_sha,
                "transcription_status": existing["transcription_status"],
            }

        ext = "wav" if codec in ("wav", "pcm", "pcmint16", "pcmfloat32") else "m4a"
        day_str = _dt.datetime.fromtimestamp(recorded_at).strftime("%Y-%m-%d")
        dest_dir = self.audio_root / day_str / session_id
        dest_dir.mkdir(parents=True, exist_ok=True)
        dest_file = dest_dir / f"{chunk_seq:06d}_{actual_sha[:8]}.{ext}"
        tmp_file = dest_file.with_suffix(f".{ext}.tmp")
        tmp_file.write_bytes(audio_bytes)
        tmp_file.replace(dest_file)
        rel_path = str(dest_file.relative_to(self.store.directory))

        now = time.time()
        with self.store.write():
            self.db.execute(
                """
                INSERT INTO audio_chunks(
                    chunk_id, library_id, session_id, source_id, device_id, chunk_seq,
                    recorded_at, duration_sec, timezone_offset, source_kind, codec, sample_rate,
                    sha256, byte_size, relative_path, vad_status, speech_seconds, vad_intervals,
                    transcription_status, created_at, updated_at
                ) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,'pending',0.0,'[]','pending',?,?)
                ON CONFLICT(source_id, chunk_seq) DO UPDATE SET
                    chunk_id=excluded.chunk_id, sha256=excluded.sha256, byte_size=excluded.byte_size,
                    relative_path=excluded.relative_path, duration_sec=excluded.duration_sec,
                    vad_status='pending', transcription_status='pending', error=NULL, updated_at=excluded.updated_at
                """,
                (
                    chunk_id,
                    library_id,
                    session_id,
                    source_id,
                    device_id,
                    chunk_seq,
                    recorded_at,
                    duration_sec,
                    tz_offset,
                    source_kind,
                    codec,
                    sample_rate,
                    actual_sha,
                    len(audio_bytes),
                    rel_path,
                    now,
                    now,
                ),
            )
            # Ensure a source stub exists so Mac UI / iPhone immediately know this recording is being processed
            self._ensure_source_stub(
                source_id=source_id,
                library_id=library_id,
                session_id=session_id,
                device_id=device_id,
                recorded_at=recorded_at,
                end_at=recorded_at + duration_sec,
                timezone_offset=tz_offset,
            )
            self.store.advance()

        return {
            "accepted": True,
            "deduplicated": False,
            "chunk_id": chunk_id,
            "source_id": source_id,
            "sha256": actual_sha,
            "transcription_status": "pending",
        }

    def batch_chunk_status(self, chunk_ids: list[str]) -> dict[str, Any]:
        clean = [str(cid).strip() for cid in chunk_ids if str(cid).strip()][:200]
        if not clean:
            return {"statuses": {}}
        placeholders = ",".join("?" for _ in clean)
        rows = self.db.execute(
            f"SELECT chunk_id, sha256, vad_status, transcription_status, speech_seconds, error FROM audio_chunks WHERE chunk_id IN ({placeholders})",
            tuple(clean),
        ).fetchall()
        found = {
            r["chunk_id"]: {
                "uploaded": True,
                "sha256": r["sha256"],
                "vad_status": r["vad_status"],
                "transcription_status": r["transcription_status"],
                "speech_seconds": round(float(r["speech_seconds"] or 0.0), 2),
                "error": r["error"],
            }
            for r in rows
        }
        return {"statuses": {cid: found.get(cid, {"uploaded": False}) for cid in clean}}

    def transcription_status(self, speech_bridge: MacSpeechBridgeClient | None = None) -> dict[str, Any]:
        counts = dict(
            self.db.execute(
                "SELECT transcription_status, COUNT(*) FROM audio_chunks GROUP BY transcription_status"
            ).fetchall()
        )
        total_chunks, total_bytes = self.db.execute(
            "SELECT COUNT(*), COALESCE(SUM(byte_size), 0) FROM audio_chunks"
        ).fetchone()
        latest_win = self.db.execute(
            "SELECT window_id, source_id, status, duration_sec, elapsed_sec, finished_at, error FROM transcription_windows ORDER BY created_at DESC LIMIT 1"
        ).fetchone()

        engine_health = None
        if speech_bridge is not None:
            try:
                engine_health = speech_bridge.health(timeout=2.0)
            except Exception as exc:
                engine_health = {"reachable": False, "error": str(exc)}
            else:
                engine_health["reachable"] = True

        return {
            "settings": self.read_settings(),
            "queue": {
                "pending": int(counts.get("pending", 0)),
                "processing": int(counts.get("processing", 0)),
                "done": int(counts.get("done", 0)),
                "silent": int(counts.get("silent", 0)),
                "failed": int(counts.get("failed", 0)),
            },
            "storage": {
                "chunk_count": int(total_chunks or 0),
                "total_bytes": int(total_bytes or 0),
                "total_mb": round(float(total_bytes or 0) / (1024 * 1024), 2),
            },
            "latest_window": dict(latest_win) if latest_win else None,
            "engine": engine_health,
            "voiceprint_count": int(self.db.execute("SELECT COUNT(*) FROM voice_profiles").fetchone()[0]),
        }

    def request_retranscribe(self, source_id: str) -> dict[str, Any]:
        clean = str(source_id or "").strip().lower()
        with self.store.write():
            updated = self.db.execute(
                """
                UPDATE audio_chunks
                SET vad_status='pending', transcription_status='pending', window_id=NULL, error=NULL, updated_at=?
                WHERE source_id=?
                """,
                (time.time(), clean),
            ).rowcount
            self.db.execute("DELETE FROM session_speaker_clusters WHERE source_id=? AND locked_by_user=0", (clean,))
            if updated:
                self.store.advance()
        return {"requeued_chunks": updated, "source_id": clean}

    # ------------------------------------------------------------------
    # Single-Pass VAD + Window Assembly + MOSS CoreML + ReDimNet2+ CoreML
    # ------------------------------------------------------------------

    def process_next_batch(
        self,
        speech_bridge: MacSpeechBridgeClient,
        *,
        flush_immediately: bool = False,
        on_source_committed=None,
    ) -> dict[str, Any] | None:
        settings = self.read_settings()
        if not settings.get("enabled", True) or settings.get("paused", False):
            return None

        # Step 1: Run fast Silero VAD on any chunk whose vad_status == 'pending'
        vad_pending = self.db.execute(
            "SELECT * FROM audio_chunks WHERE vad_status='pending' ORDER BY recorded_at ASC, chunk_seq ASC LIMIT 12"
        ).fetchall()
        for row in vad_pending:
            fpath = self.store.directory / row["relative_path"]
            if not fpath.is_file():
                with self.store.write():
                    self.db.execute(
                        "UPDATE audio_chunks SET vad_status='error', transcription_status='failed', error='Missing audio file', updated_at=? WHERE chunk_id=?",
                        (time.time(), row["chunk_id"]),
                    )
                continue
            try:
                vad_res = speech_bridge.vad(str(fpath), threshold=float(settings.get("vad_threshold", 0.45)))
            except urllib.error.HTTPError as exc:
                if 400 <= int(exc.code) < 500:
                    err_msg = f"VAD HTTP {exc.code}: {exc}"[:400]
                    logging.warning("MacSpeech VAD permanent error for %s: %s", row["chunk_id"], err_msg)
                    with self.store.write():
                        self.db.execute(
                            "UPDATE audio_chunks SET vad_status='error', transcription_status='failed', error=?, updated_at=? WHERE chunk_id=?",
                            (err_msg, time.time(), row["chunk_id"]),
                        )
                    continue
                logging.warning("MacSpeech VAD transient HTTP %s for %s: %s", exc.code, row["chunk_id"], exc)
                return None
            except Exception as exc:
                logging.warning("MacSpeech VAD transient failure for %s: %s", row["chunk_id"], exc)
                return None  # Speech engine might still be booting; retry later

            has_speech = bool(vad_res.get("has_speech"))
            speech_sec = float(vad_res.get("speech_seconds") or 0.0)
            intervals = vad_res.get("intervals") or []
            actual_dur = float(vad_res.get("duration_sec") or row["duration_sec"])
            now = time.time()
            with self.store.write():
                self.db.execute(
                    """
                    UPDATE audio_chunks
                    SET vad_status=?, speech_seconds=?, vad_intervals=?, duration_sec=?,
                        transcription_status=?, updated_at=?
                    WHERE chunk_id=?
                    """,
                    (
                        "speech" if has_speech else "silent",
                        speech_sec,
                        json.dumps(intervals),
                        actual_dur,
                        "pending" if has_speech else "silent",
                        now,
                        row["chunk_id"],
                    ),
                )

        # Step 2: Assemble the oldest ready natural conversation window (newest-session-first or oldest ready)
        ready_rows = self.db.execute(
            """
            SELECT * FROM audio_chunks
            WHERE vad_status='speech' AND transcription_status='pending'
            ORDER BY source_id ASC, chunk_seq ASC
            """
        ).fetchall()
        if not ready_rows:
            return None

        # Group by source_id and pick a window ready to transcribe
        by_source: dict[str, list[sqlite3.Row]] = {}
        for r in ready_rows:
            by_source.setdefault(r["source_id"], []).append(r)

        max_win_sec = float(settings.get("window_max_seconds", 180))
        flush_age_sec = float(settings.get("window_flush_silence_seconds", 12))
        now = time.time()

        chosen_source = None
        chosen_chunks: list[sqlite3.Row] = []

        # Prioritize most recent active source so user sees fresh conversations quickly
        ordered_sources = sorted(by_source.keys(), key=lambda sid: by_source[sid][-1]["recorded_at"], reverse=True)
        for sid in ordered_sources:
            rows = by_source[sid]
            group: list[sqlite3.Row] = []
            acc_dur = 0.0
            for r in rows:
                if group:
                    prev = group[-1]
                    gap = float(r["recorded_at"]) - (float(prev["recorded_at"]) + float(prev["duration_sec"]))
                    if gap > 20.0 or (acc_dur + float(r["duration_sec"]) > max_win_sec):
                        break
                group.append(r)
                acc_dur += float(r["duration_sec"])

            if not group:
                continue
            last_updated = float(group[-1]["updated_at"])
            # Check if a silent chunk immediately follows this group (meaning speaker stopped talking)
            next_chunk = self.db.execute(
                "SELECT vad_status FROM audio_chunks WHERE source_id=? AND chunk_seq=?",
                (sid, int(group[-1]["chunk_seq"]) + 1),
            ).fetchone()
            followed_by_silence = next_chunk is not None and next_chunk["vad_status"] == "silent"
            is_full = acc_dur >= max_win_sec * 0.85
            is_settled = flush_immediately or followed_by_silence or is_full or (now - last_updated >= flush_age_sec) or len(group) < len(rows)
            if is_settled:
                chosen_source = sid
                chosen_chunks = group
                break

        if not chosen_source or not chosen_chunks:
            return None

        return self._transcribe_window_group(
            speech_bridge=speech_bridge,
            source_id=chosen_source,
            chunks=chosen_chunks,
            settings=settings,
            on_source_committed=on_source_committed,
        )

    def _transcribe_window_group(
        self,
        *,
        speech_bridge: MacSpeechBridgeClient,
        source_id: str,
        chunks: list[sqlite3.Row],
        settings: dict[str, Any],
        on_source_committed=None,
    ) -> dict[str, Any]:
        window_id = str(uuid.uuid4())
        chunk_ids = [r["chunk_id"] for r in chunks]
        audio_paths = [str(self.store.directory / r["relative_path"]) for r in chunks]
        start_at = float(chunks[0]["recorded_at"])
        end_at = float(chunks[-1]["recorded_at"]) + float(chunks[-1]["duration_sec"])
        tz_offset = chunks[0]["timezone_offset"]
        library_id = chunks[0]["library_id"]
        session_id = chunks[0]["session_id"]
        device_id = chunks[0]["device_id"]
        now = time.time()

        with self.store.write():
            self.db.execute(
                """
                INSERT INTO transcription_windows(
                    window_id, source_id, library_id, session_id, chunk_ids, start_at, end_at,
                    timezone_offset, status, created_at
                ) VALUES(?,?,?,?,?,?,?,?,'running',?)
                """,
                (window_id, source_id, library_id, session_id, json.dumps(chunk_ids), start_at, end_at, tz_offset, now),
            )
            placeholders = ",".join("?" for _ in chunk_ids)
            self.db.execute(
                f"UPDATE audio_chunks SET transcription_status='processing', window_id=?, updated_at=? WHERE chunk_id IN ({placeholders})",
                (window_id, now, *chunk_ids),
            )

        hotwords = self.voiceprints.build_hotwords(settings.get("custom_hotwords") or [])
        t0 = time.perf_counter()

        def _mark_window_failure(exc: Exception, *, retryable: bool) -> dict[str, Any]:
            prev_err = str(chunks[0]["error"] or "")
            attempts = 1
            if prev_err.startswith("[retry ") and "]" in prev_err:
                try:
                    attempts = int(prev_err[7:prev_err.index("]")]) + 1
                except ValueError:
                    attempts = 1
            should_retry = retryable and attempts < 3
            next_status = "pending" if should_retry else "failed"
            err_msg = (f"[retry {attempts}] {exc}" if should_retry else str(exc))[:400]
            with self.store.write():
                self.db.execute(
                    "UPDATE transcription_windows SET status='failed', error=?, finished_at=? WHERE window_id=?",
                    (err_msg, time.time(), window_id),
                )
                placeholders = ",".join("?" for _ in chunk_ids)
                self.db.execute(
                    f"UPDATE audio_chunks SET transcription_status=?, error=?, updated_at=? WHERE chunk_id IN ({placeholders})",
                    (next_status, err_msg, time.time(), *chunk_ids),
                )
            return {"window_id": window_id, "source_id": source_id, "status": next_status, "error": err_msg}

        try:
            resp = speech_bridge.transcribe_window(
                audio_paths,
                hotwords=hotwords,
                language_hint=settings.get("language_hint"),
                extract_speaker_embeddings=True,
            )
        except urllib.error.HTTPError as exc:
            return _mark_window_failure(exc, retryable=(int(exc.code) >= 500))
        except (urllib.error.URLError, TimeoutError, ConnectionError, OSError) as exc:
            return _mark_window_failure(exc, retryable=True)
        except Exception as exc:
            return _mark_window_failure(exc, retryable=False)

        elapsed = time.perf_counter() - t0
        segments = resp.get("segments") or []
        speaker_embeddings = resp.get("speaker_embeddings") or []

        # Map each concatenated window offset back to exact wall-clock timestamps per chunk
        chunk_offsets: list[tuple[float, float, float]] = []
        cursor = 0.0
        for r in chunks:
            d = float(r["duration_sec"])
            chunk_offsets.append((cursor, cursor + d, float(r["recorded_at"])))
            cursor += d

        def _window_sec_to_wall(sec: float) -> float:
            for c_start, c_end, wall_start in chunk_offsets:
                if sec <= c_end or c_end == chunk_offsets[-1][1]:
                    return wall_start + max(0.0, sec - c_start)
            return start_at + sec

        # Resolve speakers via VoiceprintStore (enrolled profiles + session continuity)
        # Ensure every speaker tag present in segments has an entry even if clip < 1.2s
        emb_tags = {str(e["speaker_tag"]) for e in speaker_embeddings}
        for seg in segments:
            tag = str(seg.get("speaker_tag") or "S01")
            if tag not in emb_tags:
                speaker_embeddings.append({"speaker_tag": tag, "embedding": None, "clean_seconds": 0.0, "snr_db": 0.0})
                emb_tags.add(tag)

        resolved_speakers = self.voiceprints.resolve_window_speakers(
            source_id=source_id,
            window_id=window_id,
            speaker_embeddings=speaker_embeddings,
            threshold=float(settings.get("speaker_lock_threshold", 0.56)),
            margin=float(settings.get("speaker_lock_margin", 0.08)),
        )

        # Build authoritative transcript spans
        new_spans: list[dict[str, Any]] = []
        tag_span_ids: dict[str, list[str]] = {}
        for seg in segments:
            text_body = str(seg.get("text") or "").strip()
            if not text_body:
                continue
            tag = str(seg.get("speaker_tag") or "S01")
            spk_info = resolved_speakers.get(tag) or {
                "label": "说话人 1",
                "is_owner": False,
                "cluster_key": f"{window_id}:{tag}",
                "profile_id": None,
            }
            span_id = str(uuid.uuid4())
            s_wall = _window_sec_to_wall(float(seg.get("start_sec") or 0.0))
            e_wall = max(s_wall + 0.1, _window_sec_to_wall(float(seg.get("end_sec") or 0.0)))
            label = spk_info["label"]
            span_obj: dict[str, Any] = {
                "id": span_id,
                "recorded_at": round(s_wall, 3),
                "end_at": round(e_wall, 3),
                "text": f"[{label}] {text_body}",
                "speaker": label,
                "is_owner": bool(spk_info["is_owner"]),
                "cluster_key": spk_info["cluster_key"],
            }
            if spk_info.get("profile_id"):
                span_obj["voice_profile_id"] = spk_info["profile_id"]
            if tz_offset is not None:
                span_obj["timezone_offset"] = int(tz_offset)
            new_spans.append(span_obj)
            tag_span_ids.setdefault(tag, []).append(span_id)

        # Commit spans into ContextStore.sources + record clusters + mark chunks done atomically
        try:
            sync_result = self._commit_window_to_source(
                source_id=source_id,
                library_id=library_id,
                session_id=session_id,
                device_id=device_id,
                window_id=window_id,
                window_start=start_at,
                window_end=end_at,
                new_spans=new_spans,
                resolved_speakers=resolved_speakers,
                tag_span_ids=tag_span_ids,
                chunk_ids=chunk_ids,
                raw_text=str(resp.get("raw_text") or ""),
                duration_sec=float(resp.get("duration_sec") or 0.0),
                elapsed_sec=elapsed,
            )
        except Exception as exc:
            logging.error("Failed committing transcribed window %s for %s: %s", window_id, source_id, exc)
            return _mark_window_failure(exc, retryable=True)

        if on_source_committed and new_spans:
            try:
                on_source_committed(source_id, sync_result)
            except Exception:
                pass

        return {
            "window_id": window_id,
            "source_id": source_id,
            "status": "done",
            "span_count": len(new_spans),
            "duration_sec": round(float(resp.get("duration_sec") or 0.0), 2),
            "elapsed_sec": round(elapsed, 2),
            "revision": sync_result.get("source_revision"),
        }

    def _ensure_source_stub(
        self,
        *,
        source_id: str,
        library_id: str,
        session_id: str,
        device_id: str,
        recorded_at: float,
        end_at: float,
        timezone_offset: int | None,
    ) -> None:
        row = self.db.execute("SELECT id FROM sources WHERE id=?", (source_id,)).fetchone()
        if row:
            return
        payload = {
            "library_id": library_id,
            "session_id": session_id,
            "device_id": device_id,
            "generation": 1,
            "version": 1,
            "deleted": False,
            "recorded_at": recorded_at,
            "end_at": end_at,
            "spans": [],
            "pending_transcription_ranges": [{"start": recorded_at, "end": end_at}],
            "transcribed_on_mac": True,
        }
        if timezone_offset is not None:
            payload["timezone_offset"] = int(timezone_offset)
        canonical_payload = json.dumps(payload, ensure_ascii=False, sort_keys=True, separators=(",", ":"))
        h = hashlib.sha256(canonical_payload.encode("utf-8")).hexdigest()
        self.db.execute(
            """
            INSERT INTO sources(id, owner, generation, version, revision, hash, deleted, text, payload, updated)
            VALUES(?,?,?,?,?,?,?,?,?,?)
            """,
            (source_id, device_id, 1, 1, "1:1", h, 0, "", canonical_payload, time.time()),
        )

    def _commit_window_to_source(
        self,
        *,
        source_id: str,
        library_id: str,
        session_id: str,
        device_id: str,
        window_id: str,
        window_start: float,
        window_end: float,
        new_spans: list[dict[str, Any]],
        resolved_speakers: dict[str, dict[str, Any]],
        tag_span_ids: dict[str, list[str]],
        chunk_ids: list[str],
        raw_text: str,
        duration_sec: float,
        elapsed_sec: float,
    ) -> dict[str, Any]:
        # Load existing source payload and merge new spans in chronological order
        row = self.db.execute("SELECT * FROM sources WHERE id=?", (source_id,)).fetchone()
        if row:
            payload = json.loads(row["payload"])
            generation = int(row["generation"])
            version = int(row["version"]) + 1
            existing_spans = list(payload.get("spans") or [])
            effective_device_id = str(row["owner"] or device_id)
        else:
            generation = 1
            version = 1
            existing_spans = []
            effective_device_id = device_id
            payload = {
                "library_id": library_id,
                "session_id": session_id,
                "device_id": effective_device_id,
                "recorded_at": window_start,
                "end_at": window_end,
            }

        # Replace any previously generated spans within [window_start - 0.1, window_end + 0.1] (idempotent re-transcribe)
        kept_spans = [
            sp for sp in existing_spans
            if not (window_start - 0.05 <= float(sp.get("recorded_at") or 0.0) <= window_end + 0.05)
        ]
        merged_spans = sorted(kept_spans + new_spans, key=lambda s: float(s.get("recorded_at") or 0.0))

        # Recompute pending ranges from remaining non-done chunks in this source
        rem_rows = self.db.execute(
            """
            SELECT recorded_at, duration_sec FROM audio_chunks
            WHERE source_id=? AND transcription_status IN ('pending', 'processing')
              AND chunk_id NOT IN ({})
            ORDER BY recorded_at ASC
            """.format(",".join("?" for _ in chunk_ids)),
            (source_id, *chunk_ids),
        ).fetchall()
        pending_ranges = [
            {"start": float(r["recorded_at"]), "end": float(r["recorded_at"]) + float(r["duration_sec"])}
            for r in rem_rows
        ]

        payload["library_id"] = library_id
        payload["session_id"] = session_id
        payload["device_id"] = effective_device_id
        payload["generation"] = generation
        payload["version"] = version
        payload["deleted"] = False
        payload["transcribed_on_mac"] = True
        payload["recorded_at"] = min(
            [float(payload.get("recorded_at") or window_start), window_start]
            + [float(s["recorded_at"]) for s in merged_spans]
        )
        payload["end_at"] = max(
            [float(payload.get("end_at") or window_end), window_end]
            + [float(s.get("end_at") or s["recorded_at"]) for s in merged_spans]
        )
        payload["spans"] = merged_spans
        payload["text_sha256"] = hashlib.sha256(
            "\n".join(str(s["text"]) for s in merged_spans).encode("utf-8")
        ).hexdigest()
        payload["pending_transcription_ranges"] = pending_ranges

        sync_res = self.store.sync_source(payload)

        now = time.time()
        with self.store.write():
            self.voiceprints.record_window_clusters(source_id, window_id, resolved_speakers, tag_span_ids)
            self.db.execute(
                """
                UPDATE transcription_windows
                SET status='done', raw_text=?, duration_sec=?, elapsed_sec=?, finished_at=?
                WHERE window_id=?
                """,
                (raw_text, duration_sec, elapsed_sec, now, window_id),
            )
            placeholders = ",".join("?" for _ in chunk_ids)
            self.db.execute(
                f"UPDATE audio_chunks SET transcription_status='done', updated_at=? WHERE chunk_id IN ({placeholders})",
                (now, *chunk_ids),
            )
        return sync_res

    # ------------------------------------------------------------------
    # Audio Playback & HTTP Range Support (Mac UI + iPhone Streaming)
    # ------------------------------------------------------------------

    def list_source_audio_chunks(self, source_id: str) -> list[dict[str, Any]]:
        rows = self.db.execute(
            """
            SELECT chunk_id, chunk_seq, recorded_at, duration_sec, codec, byte_size, relative_path,
                   vad_status, transcription_status
            FROM audio_chunks
            WHERE source_id=?
            ORDER BY chunk_seq ASC
            """,
            (source_id.lower(),),
        ).fetchall()
        out = []
        for r in rows:
            abs_path = self.store.directory / r["relative_path"]
            out.append(
                {
                    "chunk_id": r["chunk_id"],
                    "chunk_seq": int(r["chunk_seq"]),
                    "recorded_at": float(r["recorded_at"]),
                    "duration_sec": float(r["duration_sec"]),
                    "end_at": float(r["recorded_at"]) + float(r["duration_sec"]),
                    "codec": r["codec"],
                    "byte_size": int(r["byte_size"]),
                    "exists": abs_path.is_file(),
                    "path": str(abs_path),
                    "vad_status": r["vad_status"],
                    "transcription_status": r["transcription_status"],
                }
            )
        return out

    def resolve_audio_file(
        self,
        *,
        chunk_id: str | None = None,
        source_id: str | None = None,
        at_timestamp: float | None = None,
    ) -> tuple[Path, str, float]:
        """Resolves an audio file on disk for playback / HTTP Range streaming.
        Returns `(abs_path, content_type, chunk_recorded_at)`.
        """
        row = None
        if chunk_id:
            row = self.db.execute(
                "SELECT relative_path, codec, recorded_at FROM audio_chunks WHERE chunk_id=?",
                (chunk_id,),
            ).fetchone()
        elif source_id:
            if at_timestamp is not None:
                row = self.db.execute(
                    """
                    SELECT relative_path, codec, recorded_at FROM audio_chunks
                    WHERE source_id=? AND recorded_at <= ?
                    ORDER BY recorded_at DESC LIMIT 1
                    """,
                    (source_id.lower(), float(at_timestamp)),
                ).fetchone()
            if row is None:
                row = self.db.execute(
                    "SELECT relative_path, codec, recorded_at FROM audio_chunks WHERE source_id=? ORDER BY chunk_seq ASC LIMIT 1",
                    (source_id.lower(),),
                ).fetchone()
        if not row:
            raise FileNotFoundError("Audio chunk not found")
        path = (self.store.directory / row["relative_path"]).resolve()
        if not str(path).startswith(str(self.audio_root.resolve())) or not path.is_file():
            raise FileNotFoundError("Audio file missing on disk")
        ctype = "audio/wav" if path.suffix.lower() == ".wav" else "audio/mp4"
        return path, ctype, float(row["recorded_at"])

    # ------------------------------------------------------------------
    # Enrollment & Dictation Helpers
    # ------------------------------------------------------------------

    def enroll_profile_sample_from_audio(
        self,
        speech_bridge: MacSpeechBridgeClient,
        *,
        profile_id: str,
        audio_bytes: bytes,
        filename: str = "sample.m4a",
        source_device: str = "mac",
        source_kind: str = "enrollment",
    ) -> dict[str, Any]:
        if not audio_bytes or len(audio_bytes) > 7_500_000:
            raise ValueError("Voiceprint sample must be 1 byte .. 7.5 MB")
        ext = Path(filename).suffix.lstrip(".").lower() or "m4a"
        with tempfile.NamedTemporaryFile(suffix=f".{ext}", delete=False) as tf:
            tf.write(audio_bytes)
            tmp_path = Path(tf.name)
        try:
            emb_res = speech_bridge.embed(str(tmp_path), apply_vad=True, min_seconds=1.6)
        finally:
            try:
                tmp_path.unlink()
            except OSError:
                pass

        added = self.voiceprints.add_sample(
            profile_id,
            emb_res["embedding"],
            source_kind=source_kind,
            source_device=source_device,
            clean_seconds=float(emb_res.get("clean_seconds") or 0.0),
            snr_db=float(emb_res.get("snr_db") or 0.0),
            clip_bytes=audio_bytes,
            clip_ext=ext,
        )
        settings = self.read_settings()
        rematch = self.voiceprints.rematch_history(
            profile_ids=[profile_id],
            threshold=float(settings.get("speaker_lock_threshold", 0.56)),
            margin=float(settings.get("speaker_lock_margin", 0.08)),
        )
        return {
            "sample": added,
            "quality": {
                "clean_seconds": emb_res.get("clean_seconds"),
                "snr_db": emb_res.get("snr_db"),
                "rms_db": emb_res.get("rms_db"),
                "bucket_frames": emb_res.get("bucket_frames"),
                "latency_ms": emb_res.get("latency_ms"),
            },
            "rematch": rematch,
            "profile": self.voiceprints.get_profile(profile_id),
        }

    def dictate_audio(
        self,
        speech_bridge: MacSpeechBridgeClient,
        *,
        audio_bytes: bytes,
        filename: str = "dictate.m4a",
    ) -> dict[str, Any]:
        if not audio_bytes or len(audio_bytes) > 7_500_000:
            raise ValueError("Dictation audio must be 1 byte .. 7.5 MB")
        ext = Path(filename).suffix.lstrip(".").lower() or "m4a"
        with tempfile.NamedTemporaryFile(suffix=f".{ext}", delete=False) as tf:
            tf.write(audio_bytes)
            tmp_path = Path(tf.name)
        try:
            settings = self.read_settings()
            hotwords = self.voiceprints.build_hotwords(settings.get("custom_hotwords") or [])
            return speech_bridge.dictate(str(tmp_path), hotwords=hotwords)
        finally:
            try:
                tmp_path.unlink()
            except OSError:
                pass

    # ------------------------------------------------------------------
    # Audio Storage Retention (Never deletes voiceprint clips or pending chunks)
    # ------------------------------------------------------------------

    def prune_expired_audio(self) -> dict[str, int]:
        settings = self.read_settings()
        retention_days = int(settings.get("audio_retention_days", 30))
        max_bytes = int(float(settings.get("audio_max_gb", 10.0)) * 1024 * 1024 * 1024)
        cutoff = time.time() - retention_days * 86400

        deleted_count = 0
        freed_bytes = 0

        # 1. Age-based pruning (only transcribed/silent chunks)
        old_rows = self.db.execute(
            """
            SELECT chunk_id, relative_path, byte_size FROM audio_chunks
            WHERE transcription_status IN ('done', 'silent') AND recorded_at < ?
            ORDER BY recorded_at ASC
            """,
            (cutoff,),
        ).fetchall()
        for r in old_rows:
            p = self.store.directory / r["relative_path"]
            if p.is_file():
                try:
                    p.unlink()
                    freed_bytes += int(r["byte_size"] or 0)
                    deleted_count += 1
                except OSError:
                    pass

        # 2. Quota-based pruning (oldest done/silent files first)
        all_done = self.db.execute(
            """
            SELECT chunk_id, relative_path, byte_size FROM audio_chunks
            WHERE transcription_status IN ('done', 'silent')
            ORDER BY recorded_at ASC
            """
        ).fetchall()
        existing_files = []
        total_size = 0
        for r in all_done:
            p = self.store.directory / r["relative_path"]
            if p.is_file():
                sz = p.stat().st_size
                total_size += sz
                existing_files.append((p, sz))
        idx = 0
        while total_size > max_bytes and idx < len(existing_files):
            p, sz = existing_files[idx]
            idx += 1
            try:
                p.unlink()
                total_size -= sz
                freed_bytes += sz
                deleted_count += 1
            except OSError:
                pass
        return {"deleted_files": deleted_count, "freed_bytes": freed_bytes}
