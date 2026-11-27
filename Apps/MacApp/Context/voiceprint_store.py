"""Mac-native Voiceprint Roster, Speaker Locking, and Instant Global Historical Rematch.

Combines:
  - SpeechRoster's clean open-set locking policy (`threshold + margin`, explicit separation of
    `assign` vs `enroll_voiceprint`, and clean center-cropped voice windows)
  - MoMo's multi-subcenter speaker profiles (up to 3 spherical k-means prototypes per person),
    medoid outlier filtering, negative rejection veto (`best - neg >= 0.05`), and cross-window
    session cluster continuity with `cannot-link` protection.

All embeddings are 192-d L2-normalized float32 vectors produced by ReDimNet2+ LMFT B6 CoreML.
"""
from __future__ import annotations

import hashlib
import json
import math
import re
import sqlite3
import struct
import time
import uuid
from pathlib import Path
from typing import Any

EMBEDDING_DIM = 192
MAX_SUBCENTERS = 3
DEFAULT_LOCK_THRESHOLD = 0.56
DEFAULT_LOCK_MARGIN = 0.08
DEFAULT_NEGATIVE_MARGIN = 0.05
DEFAULT_SESSION_MERGE_THRESHOLD = 0.62


def init_voiceprint_schema(db: sqlite3.Connection) -> None:
    db.executescript(
        """
        CREATE TABLE IF NOT EXISTS voice_profiles (
            id TEXT PRIMARY KEY,
            name TEXT NOT NULL,
            is_owner INTEGER NOT NULL DEFAULT 0,
            aliases TEXT NOT NULL DEFAULT '[]',
            memory_file TEXT,
            notes TEXT NOT NULL DEFAULT '',
            created_at REAL NOT NULL,
            updated_at REAL NOT NULL
        );

        CREATE TABLE IF NOT EXISTS voice_embeddings (
            id TEXT PRIMARY KEY,
            profile_id TEXT NOT NULL REFERENCES voice_profiles(id) ON DELETE CASCADE,
            source_kind TEXT NOT NULL,
            source_device TEXT NOT NULL DEFAULT 'mac',
            embedding BLOB NOT NULL,
            dim INTEGER NOT NULL DEFAULT 192,
            clean_seconds REAL NOT NULL DEFAULT 0.0,
            snr_db REAL NOT NULL DEFAULT 0.0,
            clip_relative_path TEXT,
            origin_source_id TEXT,
            origin_span_id TEXT,
            created_at REAL NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_voice_embeddings_profile ON voice_embeddings(profile_id);

        CREATE TABLE IF NOT EXISTS voice_rejections (
            id TEXT PRIMARY KEY,
            profile_id TEXT NOT NULL REFERENCES voice_profiles(id) ON DELETE CASCADE,
            embedding BLOB NOT NULL,
            source_id TEXT,
            cluster_key TEXT,
            reason TEXT NOT NULL DEFAULT '',
            created_at REAL NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_voice_rejections_profile ON voice_rejections(profile_id);

        CREATE TABLE IF NOT EXISTS session_speaker_clusters (
            source_id TEXT NOT NULL,
            cluster_key TEXT NOT NULL,
            window_id TEXT NOT NULL DEFAULT '',
            raw_speaker_tag TEXT NOT NULL DEFAULT '',
            embedding BLOB,
            clean_seconds REAL NOT NULL DEFAULT 0.0,
            snr_db REAL NOT NULL DEFAULT 0.0,
            sample_start_sec REAL NOT NULL DEFAULT 0.0,
            sample_end_sec REAL NOT NULL DEFAULT 0.0,
            matched_profile_id TEXT REFERENCES voice_profiles(id) ON DELETE SET NULL,
            matched_name TEXT,
            match_score REAL,
            match_margin REAL,
            locked_by_user INTEGER NOT NULL DEFAULT 0,
            span_ids TEXT NOT NULL DEFAULT '[]',
            updated_at REAL NOT NULL,
            PRIMARY KEY(source_id, cluster_key)
        );
        CREATE INDEX IF NOT EXISTS idx_clusters_profile ON session_speaker_clusters(matched_profile_id);
        CREATE INDEX IF NOT EXISTS idx_clusters_source ON session_speaker_clusters(source_id);
        """
    )


def pack_embedding(vec: list[float]) -> bytes:
    if len(vec) != EMBEDDING_DIM:
        raise ValueError(f"Expected {EMBEDDING_DIM}-d embedding, got {len(vec)}")
    norm_sq = sum(float(x) * float(x) for x in vec)
    if not math.isfinite(norm_sq) or norm_sq <= 1e-12:
        raise ValueError("Zero or non-finite embedding vector")
    inv = 1.0 / math.sqrt(norm_sq)
    normed = [float(x) * inv for x in vec]
    return struct.pack(f"<{EMBEDDING_DIM}f", *normed)


def unpack_embedding(blob: bytes | None) -> list[float] | None:
    if not blob:
        return None
    expected = EMBEDDING_DIM * 4
    if len(blob) != expected:
        return None
    return list(struct.unpack(f"<{EMBEDDING_DIM}f", blob))


def cosine(a: list[float], b: list[float]) -> float:
    dot = 0.0
    for x, y in zip(a, b):
        dot += x * y
    return max(-1.0, min(1.0, dot))


def _l2_normalize(vec: list[float]) -> list[float]:
    n = math.sqrt(sum(x * x for x in vec))
    if n <= 1e-12:
        return vec
    inv = 1.0 / n
    return [x * inv for x in vec]


def _filter_medoid_outliers(vectors: list[list[float]], min_keep: int = 3) -> list[list[float]]:
    """Removes noisy enrollment outliers when >= 4 samples exist for a person."""
    if len(vectors) <= min_keep:
        return vectors
    n = len(vectors)
    avg_sims = []
    for i in range(n):
        s = sum(cosine(vectors[i], vectors[j]) for j in range(n) if j != i) / (n - 1)
        avg_sims.append((s, i))
    medoid_idx = max(avg_sims, key=lambda pair: pair[0])[1]
    medoid = vectors[medoid_idx]
    kept = [v for v in vectors if cosine(v, medoid) >= 0.40]
    return kept if len(kept) >= min_keep else vectors


def build_profile_subcenters(
    vectors: list[list[float]],
    weights: list[float] | None = None,
    max_k: int = MAX_SUBCENTERS,
) -> list[list[float]]:
    """Builds up to 3 spherical k-means prototypes (handles near-field phone vs far-field watch acoustics)."""
    if not vectors:
        return []
    clean = _filter_medoid_outliers(vectors)
    if len(clean) == 1:
        return [_l2_normalize(clean[0])]
    if len(clean) <= 3:
        # Compute mean centroid plus individual distinct prototypes when samples diverge across mics
        w = weights[: len(clean)] if weights and len(weights) >= len(clean) else [1.0] * len(clean)
        mean = [0.0] * EMBEDDING_DIM
        for vec, wt in zip(clean, w):
            for i in range(EMBEDDING_DIM):
                mean[i] += vec[i] * wt
        centroid = _l2_normalize(mean)
        centers = [centroid]
        for vec in clean:
            if all(cosine(vec, c) < 0.86 for c in centers) and len(centers) < max_k:
                centers.append(_l2_normalize(vec))
        return centers

    k = min(max_k, max(1, len(clean) // 2))
    # Deterministic farthest-first seeding
    centers = [_l2_normalize(clean[0])]
    while len(centers) < k:
        best_idx = 0
        best_max_sim = 2.0
        for idx, vec in enumerate(clean):
            ms = max(cosine(vec, c) for c in centers)
            if ms < best_max_sim:
                best_max_sim = ms
                best_idx = idx
        if best_max_sim > 0.88:
            break
        centers.append(_l2_normalize(clean[best_idx]))

    # 8 iterations of spherical k-means
    for _ in range(8):
        buckets: list[list[list[float]]] = [[] for _ in range(len(centers))]
        for vec in clean:
            bi = max(range(len(centers)), key=lambda ci: cosine(vec, centers[ci]))
            buckets[bi].append(vec)
        new_centers = []
        for ci, bucket in enumerate(buckets):
            if not bucket:
                new_centers.append(centers[ci])
                continue
            acc = [0.0] * EMBEDDING_DIM
            for vec in bucket:
                for d in range(EMBEDDING_DIM):
                    acc[d] += vec[d]
            new_centers.append(_l2_normalize(acc))
        centers = new_centers
    return centers


class VoiceprintStore:
    """High-level voiceprint roster, open-set speaker locking, and fast historical rematch."""

    def __init__(self, context_store, data_dir: Path | None = None):
        self.store = context_store
        self.db = context_store.db
        self.data_dir = Path(data_dir) if data_dir else context_store.directory.parent
        self.clips_dir = context_store.directory / "voiceprints"
        self.clips_dir.mkdir(parents=True, exist_ok=True)
        init_voiceprint_schema(self.db)

    # ------------------------------------------------------------------
    # Profile CRUD & Sample Management
    # ------------------------------------------------------------------

    def list_profiles(self) -> list[dict[str, Any]]:
        rows = self.db.execute(
            """
            SELECT p.*,
                   COUNT(e.id) AS sample_count,
                   COALESCE(SUM(e.clean_seconds), 0.0) AS total_clean_seconds
            FROM voice_profiles p
            LEFT JOIN voice_embeddings e ON e.profile_id = p.id
            GROUP BY p.id
            ORDER BY p.is_owner DESC, p.updated_at DESC, p.name ASC
            """
        ).fetchall()
        profiles = []
        for r in rows:
            samples = self.db.execute(
                """
                SELECT id, source_kind, source_device, clean_seconds, snr_db,
                       clip_relative_path, origin_source_id, origin_span_id, created_at
                FROM voice_embeddings
                WHERE profile_id = ?
                ORDER BY created_at DESC
                """,
                (r["id"],),
            ).fetchall()
            rej_count = self.db.execute(
                "SELECT COUNT(*) FROM voice_rejections WHERE profile_id = ?", (r["id"],)
            ).fetchone()[0]
            profiles.append(
                {
                    "id": r["id"],
                    "name": r["name"],
                    "is_owner": bool(r["is_owner"]),
                    "aliases": json.loads(r["aliases"] or "[]"),
                    "memory_file": r["memory_file"],
                    "notes": r["notes"] or "",
                    "sample_count": int(r["sample_count"]),
                    "total_clean_seconds": round(float(r["total_clean_seconds"]), 2),
                    "rejection_count": int(rej_count),
                    "created_at": r["created_at"],
                    "updated_at": r["updated_at"],
                    "samples": [
                        {
                            "id": s["id"],
                            "source_kind": s["source_kind"],
                            "source_device": s["source_device"],
                            "clean_seconds": round(float(s["clean_seconds"]), 2),
                            "snr_db": round(float(s["snr_db"]), 1),
                            "has_clip": bool(s["clip_relative_path"]),
                            "origin_source_id": s["origin_source_id"],
                            "origin_span_id": s["origin_span_id"],
                            "created_at": s["created_at"],
                        }
                        for s in samples
                    ],
                }
            )
        return profiles

    def get_profile(self, profile_id: str) -> dict[str, Any] | None:
        for p in self.list_profiles():
            if p["id"] == profile_id:
                return p
        return None

    def find_profile_by_name(self, name: str, is_owner: bool | None = None) -> dict[str, Any] | None:
        clean = str(name or "").strip()
        if is_owner is True:
            row = self.db.execute("SELECT id FROM voice_profiles WHERE is_owner=1 LIMIT 1").fetchone()
            if row:
                return self.get_profile(row["id"])
        if not clean:
            return None
        row = self.db.execute(
            "SELECT id FROM voice_profiles WHERE LOWER(name) = LOWER(?) LIMIT 1", (clean,)
        ).fetchone()
        if row:
            return self.get_profile(row["id"])
        return None

    def create_or_update_profile(
        self,
        *,
        profile_id: str | None = None,
        name: str,
        is_owner: bool = False,
        aliases: list[str] | None = None,
        memory_file: str | None = None,
        notes: str | None = None,
    ) -> dict[str, Any]:
        clean_name = "我" if is_owner and not str(name or "").strip() else str(name or "").strip()
        if not clean_name or len(clean_name) > 80:
            raise ValueError("Voice profile name must be 1..80 characters")
        clean_aliases = []
        if aliases is not None:
            seen = set()
            for a in aliases:
                s = str(a or "").strip()
                if s and s.casefold() not in seen and len(s) <= 80:
                    seen.add(s.casefold())
                    clean_aliases.append(s)
        now = time.time()
        touched_sources: set[str] = set()
        with self.store.write():
            if profile_id:
                existing = self.db.execute("SELECT * FROM voice_profiles WHERE id=?", (profile_id,)).fetchone()
                if not existing:
                    raise ValueError(f"Voice profile not found: {profile_id}")
                new_aliases = json.dumps(clean_aliases, ensure_ascii=False) if aliases is not None else existing["aliases"]
                new_mem = (str(memory_file).strip() or None) if memory_file is not None else existing["memory_file"]
                new_notes = notes if notes is not None else existing["notes"]
                if is_owner:
                    self.db.execute("UPDATE voice_profiles SET is_owner=0 WHERE id!=?", (profile_id,))
                self.db.execute(
                    """
                    UPDATE voice_profiles
                    SET name=?, is_owner=?, aliases=?, memory_file=?, notes=?, updated_at=?
                    WHERE id=?
                    """,
                    (clean_name, int(bool(is_owner)), new_aliases, new_mem, new_notes, now, profile_id),
                )
                pid = profile_id
                if existing["name"] != clean_name or bool(existing["is_owner"]) != bool(is_owner):
                    rows = self.db.execute(
                        "SELECT source_id, cluster_key, span_ids FROM session_speaker_clusters WHERE matched_profile_id=?",
                        (profile_id,),
                    ).fetchall()
                    for r in rows:
                        touched_sources.add(r["source_id"])
                        self.db.execute(
                            "UPDATE session_speaker_clusters SET matched_name=?, updated_at=? WHERE source_id=? AND cluster_key=?",
                            (clean_name, now, r["source_id"], r["cluster_key"]),
                        )
                        for sid in json.loads(r["span_ids"] or "[]"):
                            self.db.execute(
                                """INSERT INTO span_speaker_overrides(source_id, span_id, speaker, is_owner, reason, updated_at)
                                   VALUES(?,?,?,?,?,?) ON CONFLICT(source_id, span_id) DO UPDATE SET
                                   speaker=excluded.speaker, is_owner=excluded.is_owner, reason=excluded.reason, updated_at=excluded.updated_at""",
                                (r["source_id"], str(sid).lower(), clean_name, int(bool(is_owner)), "Voice profile renamed", now),
                            )
            else:
                if is_owner:
                    existing_owner = self.db.execute("SELECT id FROM voice_profiles WHERE is_owner=1 LIMIT 1").fetchone()
                    if existing_owner:
                        pid = existing_owner["id"]
                        self.db.execute(
                            """
                            UPDATE voice_profiles
                            SET name=?, aliases=?, memory_file=COALESCE(?, memory_file), notes=COALESCE(?, notes), updated_at=?
                            WHERE id=?
                            """,
                            (
                                clean_name,
                                json.dumps(clean_aliases, ensure_ascii=False),
                                (str(memory_file).strip() or None) if memory_file is not None else None,
                                notes,
                                now,
                                pid,
                            ),
                        )
                    else:
                        pid = str(uuid.uuid4())
                        self.db.execute(
                            """
                            INSERT INTO voice_profiles(id, name, is_owner, aliases, memory_file, notes, created_at, updated_at)
                            VALUES(?,?,?,?,?,?,?,?)
                            """,
                            (
                                pid,
                                clean_name,
                                1,
                                json.dumps(clean_aliases, ensure_ascii=False),
                                (str(memory_file).strip() or None) if memory_file is not None else None,
                                notes or "",
                                now,
                                now,
                            ),
                        )
                else:
                    pid = str(uuid.uuid4())
                    self.db.execute(
                        """
                        INSERT INTO voice_profiles(id, name, is_owner, aliases, memory_file, notes, created_at, updated_at)
                        VALUES(?,?,?,?,?,?,?,?)
                        """,
                        (
                            pid,
                            clean_name,
                            0,
                            json.dumps(clean_aliases, ensure_ascii=False),
                            (str(memory_file).strip() or None) if memory_file is not None else None,
                            notes or "",
                            now,
                            now,
                        ),
                    )
            self.store.advance()
        if touched_sources:
            self.store.refresh_mac_source_speakers(touched_sources)
        return self.get_profile(pid)

    def delete_profile(self, profile_id: str) -> dict[str, Any]:
        touched_sources: set[str] = set()
        with self.store.write():
            row = self.db.execute("SELECT id, name FROM voice_profiles WHERE id=?", (profile_id,)).fetchone()
            if not row:
                raise ValueError(f"Voice profile not found: {profile_id}")
            clips = [
                r["clip_relative_path"]
                for r in self.db.execute(
                    "SELECT clip_relative_path FROM voice_embeddings WHERE profile_id=? AND clip_relative_path IS NOT NULL",
                    (profile_id,),
                ).fetchall()
            ]
            cluster_rows = self.db.execute(
                "SELECT source_id, cluster_key, span_ids FROM session_speaker_clusters WHERE matched_profile_id=?",
                (profile_id,),
            ).fetchall()
            now = time.time()
            for cr in cluster_rows:
                touched_sources.add(cr["source_id"])
                for sid in json.loads(cr["span_ids"] or "[]"):
                    self.db.execute(
                        """INSERT INTO span_speaker_overrides(source_id, span_id, speaker, is_owner, reason, updated_at)
                           VALUES(?,?,?,?,?,?) ON CONFLICT(source_id, span_id) DO UPDATE SET
                           speaker=excluded.speaker, is_owner=0, reason=excluded.reason, updated_at=excluded.updated_at""",
                        (cr["source_id"], str(sid).lower(), "说话人", 0, "Voice profile deleted", now),
                    )
            self.db.execute(
                """
                UPDATE session_speaker_clusters
                SET matched_profile_id=NULL, matched_name=NULL, match_score=NULL, match_margin=NULL, locked_by_user=0
                WHERE matched_profile_id=?
                """,
                (profile_id,),
            )
            self.db.execute("DELETE FROM voice_profiles WHERE id=?", (profile_id,))
            self.store.advance()
        if touched_sources:
            self.store.refresh_mac_source_speakers(touched_sources)
        for rel in clips:
            p = self.store.directory / rel
            if p.is_file():
                try:
                    p.unlink()
                except OSError:
                    pass
        return {"deleted": True, "profile_id": profile_id, "name": row["name"]}

    def add_sample(
        self,
        profile_id: str,
        embedding: list[float],
        *,
        source_kind: str = "enrollment",
        source_device: str = "mac",
        clean_seconds: float = 0.0,
        snr_db: float = 0.0,
        clip_bytes: bytes | None = None,
        clip_ext: str = "m4a",
        origin_source_id: str | None = None,
        origin_span_id: str | None = None,
    ) -> dict[str, Any]:
        blob = pack_embedding(embedding)
        sample_id = str(uuid.uuid4())
        rel_path: str | None = None
        if clip_bytes:
            safe_ext = re.sub(r"[^a-zA-Z0-9]", "", clip_ext or "m4a").lower() or "m4a"
            pdir = self.clips_dir / profile_id
            pdir.mkdir(parents=True, exist_ok=True)
            dest = pdir / f"{sample_id}.{safe_ext}"
            dest.write_bytes(clip_bytes)
            rel_path = str(dest.relative_to(self.store.directory))

        now = time.time()
        with self.store.write():
            exists = self.db.execute("SELECT id FROM voice_profiles WHERE id=?", (profile_id,)).fetchone()
            if not exists:
                raise ValueError(f"Voice profile not found: {profile_id}")
            self.db.execute(
                """
                INSERT INTO voice_embeddings(
                    id, profile_id, source_kind, source_device, embedding, dim,
                    clean_seconds, snr_db, clip_relative_path, origin_source_id, origin_span_id, created_at
                ) VALUES(?,?,?,?,?,?,?,?,?,?,?,?)
                """,
                (
                    sample_id,
                    profile_id,
                    source_kind,
                    source_device,
                    blob,
                    EMBEDDING_DIM,
                    float(clean_seconds),
                    float(snr_db),
                    rel_path,
                    origin_source_id,
                    origin_span_id,
                    now,
                ),
            )
            self.db.execute("UPDATE voice_profiles SET updated_at=? WHERE id=?", (now, profile_id))
            self.store.advance()
        return {
            "sample_id": sample_id,
            "profile_id": profile_id,
            "clean_seconds": round(float(clean_seconds), 2),
            "snr_db": round(float(snr_db), 1),
            "has_clip": bool(rel_path),
        }

    def delete_sample(self, profile_id: str, sample_id: str) -> dict[str, Any]:
        with self.store.write():
            row = self.db.execute(
                "SELECT id, clip_relative_path FROM voice_embeddings WHERE id=? AND profile_id=?",
                (sample_id, profile_id),
            ).fetchone()
            if not row:
                raise ValueError(f"Voice sample not found: {sample_id}")
            self.db.execute("DELETE FROM voice_embeddings WHERE id=?", (sample_id,))
            self.db.execute("UPDATE voice_profiles SET updated_at=? WHERE id=?", (time.time(), profile_id))
            self.store.advance()
        if row["clip_relative_path"]:
            p = self.store.directory / row["clip_relative_path"]
            if p.is_file():
                try:
                    p.unlink()
                except OSError:
                    pass
        return {"deleted": True, "sample_id": sample_id, "profile_id": profile_id}

    def sample_clip_path(self, profile_id: str, sample_id: str) -> Path | None:
        row = self.db.execute(
            "SELECT clip_relative_path FROM voice_embeddings WHERE id=? AND profile_id=?",
            (sample_id, profile_id),
        ).fetchone()
        if not row or not row["clip_relative_path"]:
            return None
        path = (self.store.directory / row["clip_relative_path"]).resolve()
        if not str(path).startswith(str(self.clips_dir.resolve())) or not path.is_file():
            return None
        return path

    # ------------------------------------------------------------------
    # Matching Engine (Multi-Subcenter + Margin + Negative Rejection Veto)
    # ------------------------------------------------------------------

    def _load_profile_prototypes(self) -> list[dict[str, Any]]:
        profiles = self.db.execute("SELECT id, name, is_owner FROM voice_profiles").fetchall()
        out = []
        for p in profiles:
            embs = self.db.execute(
                "SELECT embedding, clean_seconds, snr_db FROM voice_embeddings WHERE profile_id=?",
                (p["id"],),
            ).fetchall()
            vecs = []
            wts = []
            for e in embs:
                v = unpack_embedding(e["embedding"])
                if v:
                    vecs.append(v)
                    wts.append(max(0.5, min(6.0, float(e["clean_seconds"] or 2.0))))
            if not vecs:
                continue
            rejs = [
                v
                for r in self.db.execute(
                    "SELECT embedding FROM voice_rejections WHERE profile_id=?", (p["id"],)
                ).fetchall()
                if (v := unpack_embedding(r["embedding"])) is not None
            ]
            out.append(
                {
                    "id": p["id"],
                    "name": p["name"],
                    "is_owner": bool(p["is_owner"]),
                    "centers": build_profile_subcenters(vecs, wts),
                    "rejections": rejs,
                }
            )
        return out

    def match_embedding(
        self,
        embedding: list[float],
        *,
        threshold: float = DEFAULT_LOCK_THRESHOLD,
        margin: float = DEFAULT_LOCK_MARGIN,
        negative_margin: float = DEFAULT_NEGATIVE_MARGIN,
        prototypes: list[dict[str, Any]] | None = None,
    ) -> dict[str, Any]:
        """Matches a single 192-d speaker embedding against all enrolled voice profiles."""
        q = _l2_normalize(embedding)
        protos = prototypes if prototypes is not None else self._load_profile_prototypes()
        if not protos:
            return {"matched": False, "profile_id": None, "name": None, "is_owner": False, "score": 0.0, "margin": 0.0}

        scored: list[tuple[float, dict[str, Any], float]] = []
        for prof in protos:
            best_sim = max(cosine(q, c) for c in prof["centers"])
            max_neg = max((cosine(q, r) for r in prof["rejections"]), default=-1.0)
            scored.append((best_sim, prof, max_neg))
        scored.sort(key=lambda item: item[0], reverse=True)

        top_score, top_prof, top_neg = scored[0]
        second_score = scored[1][0] if len(scored) > 1 else 0.0
        top_margin = top_score - second_score

        if top_score < threshold:
            return {
                "matched": False,
                "profile_id": None,
                "name": None,
                "is_owner": False,
                "score": round(top_score, 4),
                "margin": round(top_margin, 4),
                "reason": "below_threshold",
            }
        if len(scored) > 1 and top_margin < margin:
            return {
                "matched": False,
                "profile_id": None,
                "name": None,
                "is_owner": False,
                "score": round(top_score, 4),
                "margin": round(top_margin, 4),
                "reason": "ambiguous_margin",
            }
        if top_neg > -0.5 and (top_score - top_neg) < negative_margin:
            return {
                "matched": False,
                "profile_id": None,
                "name": None,
                "is_owner": False,
                "score": round(top_score, 4),
                "margin": round(top_margin, 4),
                "reason": "negative_rejection_veto",
            }
        return {
            "matched": True,
            "profile_id": top_prof["id"],
            "name": top_prof["name"],
            "is_owner": top_prof["is_owner"],
            "score": round(top_score, 4),
            "margin": round(top_margin, 4),
            "reason": "locked",
        }

    def resolve_window_speakers(
        self,
        source_id: str,
        window_id: str,
        speaker_embeddings: list[dict[str, Any]],
        *,
        threshold: float = DEFAULT_LOCK_THRESHOLD,
        margin: float = DEFAULT_LOCK_MARGIN,
    ) -> dict[str, dict[str, Any]]:
        """Resolves each local MOSS speaker tag (`S01`, `S02`...) to either:
          - An enrolled `voice_profile` (with `cannot-link` one-to-one conflict prevention in the same window)
          - An existing anonymous cluster in the same `source_id` (`Speaker A`, `Speaker B`...)
          - Or a new anonymous speaker label (`说话人 1`, `说话人 2`...)
        Returns mapping: raw_tag -> {cluster_key, label, is_owner, profile_id, score, margin, embedding, clean_seconds, snr_db}
        """
        protos = self._load_profile_prototypes()
        existing_clusters = self.db.execute(
            "SELECT * FROM session_speaker_clusters WHERE source_id=?", (source_id,)
        ).fetchall()

        existing_anon: list[tuple[str, str, list[float]]] = []
        used_anon_nums: set[int] = set()
        for row in existing_clusters:
            nm = str(row["matched_name"] or "")
            m = re.fullmatch(r"说话人\s*(\d+)", nm)
            if m:
                used_anon_nums.add(int(m.group(1)))
            if not row["matched_profile_id"]:
                vec = unpack_embedding(row["embedding"])
                if vec and nm:
                    existing_anon.append((row["cluster_key"], nm, vec))

        # Score all tags against enrolled profiles first; apply one-to-one cannot-link within the window
        tag_matches: dict[str, dict[str, Any]] = {}
        candidates: list[tuple[float, str, dict[str, Any], dict[str, Any]]] = []
        for item in speaker_embeddings:
            tag = str(item["speaker_tag"])
            emb = item.get("embedding")
            if emb and len(emb) == EMBEDDING_DIM:
                res = self.match_embedding(emb, threshold=threshold, margin=margin, prototypes=protos)
                if res["matched"]:
                    candidates.append((res["score"], tag, res, item))

        # Greedy best-score assignment per bisection half ("" vs "B2_") ensures two distinct MOSS
        # speakers in the same pass don't both lock to the same person, while allowing B2_S01 in the
        # second half of a bisected clip to lock to the same person as S01 in the first half.
        def _half_key(tag: str) -> str:
            idx = tag.rfind("_")
            return tag[:idx] if tag.startswith("B") and idx > 0 else "B1"

        candidates.sort(key=lambda x: x[0], reverse=True)
        claimed_profiles_by_half: dict[str, set[str]] = {}
        for score, tag, res, item in candidates:
            pid = res["profile_id"]
            half = _half_key(tag)
            claimed = claimed_profiles_by_half.setdefault(half, set())
            if pid in claimed:
                continue
            claimed.add(pid)
            tag_matches[tag] = {
                "cluster_key": f"{window_id}:{tag}",
                "label": res["name"],
                "is_owner": bool(res["is_owner"]),
                "profile_id": pid,
                "score": res["score"],
                "margin": res["margin"],
                "embedding": item.get("embedding"),
                "clean_seconds": float(item.get("clean_seconds") or 0.0),
                "snr_db": float(item.get("snr_db") or 0.0),
                "sample_start_sec": float(item.get("sample_start_sec") or 0.0),
                "sample_end_sec": float(item.get("sample_end_sec") or 0.0),
            }

        # Resolve unmatched tags against same-session anonymous clusters (and earlier bisection halves)
        claimed_anon_by_half: dict[str, set[str]] = {}
        ordered_unmatched = sorted(
            [item for item in speaker_embeddings if str(item["speaker_tag"]) not in tag_matches],
            key=lambda it: (0 if _half_key(str(it["speaker_tag"])) == "B1" else 1, str(it["speaker_tag"])),
        )
        for item in ordered_unmatched:
            tag = str(item["speaker_tag"])
            half = _half_key(tag)
            claimed_anon = claimed_anon_by_half.setdefault(half, set())
            emb = item.get("embedding")
            matched_label = None
            matched_score = None
            if emb and len(emb) == EMBEDDING_DIM and existing_anon:
                q = _l2_normalize(emb)
                best_sim = -1.0
                best_lbl = None
                for _, lbl, vec in existing_anon:
                    if lbl in claimed_anon:
                        continue
                    sim = cosine(q, vec)
                    if sim > best_sim:
                        best_sim = sim
                        best_lbl = lbl
                if best_lbl and best_sim >= DEFAULT_SESSION_MERGE_THRESHOLD:
                    matched_label = best_lbl
                    matched_score = round(best_sim, 4)
                    claimed_anon.add(best_lbl)

            if not matched_label:
                next_num = 1
                while next_num in used_anon_nums:
                    next_num += 1
                used_anon_nums.add(next_num)
                matched_label = f"说话人 {next_num}"
                claimed_anon.add(matched_label)

            if emb and len(emb) == EMBEDDING_DIM:
                existing_anon.append((f"{window_id}:{tag}", matched_label, _l2_normalize(emb)))

            tag_matches[tag] = {
                "cluster_key": f"{window_id}:{tag}",
                "label": matched_label,
                "is_owner": False,
                "profile_id": None,
                "score": matched_score,
                "margin": None,
                "embedding": emb if (emb and len(emb) == EMBEDDING_DIM) else None,
                "clean_seconds": float(item.get("clean_seconds") or 0.0),
                "snr_db": float(item.get("snr_db") or 0.0),
                "sample_start_sec": float(item.get("sample_start_sec") or 0.0),
                "sample_end_sec": float(item.get("sample_end_sec") or 0.0),
            }
        return tag_matches

    def record_window_clusters(
        self,
        source_id: str,
        window_id: str,
        resolved: dict[str, dict[str, Any]],
        tag_span_ids: dict[str, list[str]],
    ) -> None:
        now = time.time()
        for tag, info in resolved.items():
            blob = pack_embedding(info["embedding"]) if info.get("embedding") else None
            spans = tag_span_ids.get(tag, [])
            self.db.execute(
                """
                INSERT INTO session_speaker_clusters(
                    source_id, cluster_key, window_id, raw_speaker_tag, embedding,
                    clean_seconds, snr_db, sample_start_sec, sample_end_sec,
                    matched_profile_id, matched_name, match_score, match_margin,
                    locked_by_user, span_ids, updated_at
                ) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,0,?,?)
                ON CONFLICT(source_id, cluster_key) DO UPDATE SET
                    embedding=COALESCE(excluded.embedding, embedding),
                    clean_seconds=excluded.clean_seconds,
                    snr_db=excluded.snr_db,
                    matched_profile_id=excluded.matched_profile_id,
                    matched_name=excluded.matched_name,
                    match_score=excluded.match_score,
                    match_margin=excluded.match_margin,
                    span_ids=excluded.span_ids,
                    updated_at=excluded.updated_at
                """,
                (
                    source_id,
                    info["cluster_key"],
                    window_id,
                    tag,
                    blob,
                    info["clean_seconds"],
                    info["snr_db"],
                    info["sample_start_sec"],
                    info["sample_end_sec"],
                    info["profile_id"],
                    info["label"],
                    info["score"],
                    info["margin"],
                    json.dumps(spans, ensure_ascii=False),
                    now,
                ),
            )

    # ------------------------------------------------------------------
    # Click-to-Lock (Separating `assign` vs `enroll_voiceprint`), Reject, Global Rematch
    # ------------------------------------------------------------------

    def bind_transcript_speaker(
        self,
        *,
        source_id: str,
        span_ids: list[str] | None = None,
        cluster_key: str | None = None,
        profile_id: str | None = None,
        target_name: str | None = None,
        is_owner: bool = False,
        enroll_voiceprint: bool = False,
        rematch_history: bool = True,
        scope: str = "cluster",
        reason: str = "User voiceprint binding",
    ) -> dict[str, Any]:
        """Handles click-to-lock from Mac or iPhone transcript UI.

        Explicitly separates:
          - `enroll_voiceprint=False` (`assign`): updates labels for the selected spans/cluster only.
          - `enroll_voiceprint=True`: also adds the cluster's cached 192-d ReDimNet2+ vector to the
            person's `voice_embeddings` and optionally triggers `<100ms` global historical rematch.
        """
        # Resolve or create target profile if enrolling or profile_id given
        profile = None
        if profile_id:
            profile = self.get_profile(profile_id)
            if not profile:
                raise ValueError(f"Voice profile not found: {profile_id}")
        elif enroll_voiceprint or target_name:
            profile = self.find_profile_by_name(target_name or ("我" if is_owner else ""), is_owner=is_owner)
            if profile is None and enroll_voiceprint:
                profile = self.create_or_update_profile(
                    name=target_name or ("我" if is_owner else ""),
                    is_owner=is_owner,
                )

        resolved_name = profile["name"] if profile else ("我" if is_owner else str(target_name or "").strip())
        resolved_is_owner = profile["is_owner"] if profile else bool(is_owner)
        if not resolved_name:
            raise ValueError("Provide either profile_id or target_name")

        # Locate matching cluster row(s)
        target_clusters = self._find_clusters_for_selection(source_id, span_ids=span_ids, cluster_key=cluster_key)
        all_span_ids = list(span_ids or [])
        if scope == "cluster" and target_clusters:
            seen = {s.lower() for s in all_span_ids}
            for c in target_clusters:
                for sid in json.loads(c["span_ids"] or "[]"):
                    if sid.lower() not in seen:
                        all_span_ids.append(sid)
                        seen.add(sid.lower())

        # Clear any prior negative speaker exclusions for the bound target name so re-binding works.
        if all_span_ids:
            bound_set = {s.lower() for s in all_span_ids}
            with self.store.write():
                for erow in self.db.execute(
                    "SELECT id, speaker, span_ids FROM speaker_exclusions WHERE source_id=?",
                    (source_id,),
                ).fetchall():
                    if erow["speaker"].casefold() != resolved_name.casefold():
                        continue
                    rem = [s for s in json.loads(erow["span_ids"] or "[]") if s.lower() not in bound_set]
                    if not rem:
                        self.db.execute("DELETE FROM speaker_exclusions WHERE id=?", (erow["id"],))
                    elif len(rem) < len(json.loads(erow["span_ids"] or "[]")):
                        self.db.execute(
                            "UPDATE speaker_exclusions SET span_ids=? WHERE id=?",
                            (json.dumps(sorted(rem), separators=(",", ":")), erow["id"]),
                        )

        # Relabel source spans directly in ContextStore (authoritative on Mac)
        relabel_res = self.store._relabel_speakers(
            source_id,
            resolved_name,
            is_owner=resolved_is_owner,
            span_ids=all_span_ids or None,
            scope=scope,
            reason=reason,
            enqueue_phone_sync=False,
        )

        # Only lock/enroll the cluster's 192-d vector when scope == "cluster";
        # single-sentence corrections (`scope == "selection"`) must never poison a cluster's voiceprint.
        enrolled_samples = 0
        now = time.time()
        if scope == "cluster":
            # Also include sibling clusters in the same recording sharing the same speaker label
            extra_names = {c["matched_name"] for c in target_clusters if c["matched_name"]}
            cluster_map = {c["cluster_key"]: c for c in target_clusters}
            if extra_names:
                for sib in self.db.execute(
                    "SELECT * FROM session_speaker_clusters WHERE source_id=?",
                    (source_id,),
                ).fetchall():
                    if sib["matched_name"] in extra_names and sib["cluster_key"] not in cluster_map:
                        cluster_map[sib["cluster_key"]] = sib
            clusters_to_update = list(cluster_map.values())

            with self.store.write():
                for c in clusters_to_update:
                    self.db.execute(
                        """
                        UPDATE session_speaker_clusters
                        SET matched_profile_id=?, matched_name=?, locked_by_user=1, updated_at=?
                        WHERE source_id=? AND cluster_key=?
                        """,
                        (profile["id"] if profile else None, resolved_name, now, source_id, c["cluster_key"]),
                    )
                    if enroll_voiceprint and profile:
                        vec = unpack_embedding(c["embedding"])
                        if vec and float(c["clean_seconds"] or 0.0) >= 1.2:
                            sid = str(uuid.uuid4())
                            self.db.execute(
                                """
                                INSERT INTO voice_embeddings(
                                    id, profile_id, source_kind, source_device, embedding, dim,
                                    clean_seconds, snr_db, origin_source_id, origin_span_id, created_at
                                ) VALUES(?,?,?,?,?,?,?,?,?,?,?)
                                """,
                                (
                                    sid,
                                    profile["id"],
                                    "transcript_bind",
                                    "mac",
                                    c["embedding"],
                                    EMBEDDING_DIM,
                                    float(c["clean_seconds"] or 0.0),
                                    float(c["snr_db"] or 0.0),
                                    source_id,
                                    (all_span_ids[0] if all_span_ids else None),
                                    now,
                                ),
                            )
                            enrolled_samples += 1
                if enrolled_samples > 0 and profile:
                    self.db.execute("UPDATE voice_profiles SET updated_at=? WHERE id=?", (now, profile["id"]))
                self.store.advance()

        self.store.refresh_mac_source_speakers([source_id])

        rematch_summary = None
        if enroll_voiceprint and rematch_history and enrolled_samples > 0:
            rematch_summary = self.rematch_history(profile_ids=[profile["id"]] if profile else None)

        return {
            "success": True,
            "source_id": source_id,
            "profile_id": profile["id"] if profile else None,
            "target_name": resolved_name,
            "is_owner": resolved_is_owner,
            "enrolled_voiceprint": enroll_voiceprint and enrolled_samples > 0,
            "enrolled_samples": enrolled_samples,
            "updated_span_count": relabel_res.get("updated_span_count", 0),
            "rematch": rematch_summary,
        }

    def reject_speaker_match(
        self,
        *,
        source_id: str,
        profile_id: str | None = None,
        speaker_name: str | None = None,
        span_ids: list[str] | None = None,
        cluster_key: str | None = None,
        reason: str = "User rejected speaker match",
    ) -> dict[str, Any]:
        """Marks a speaker assignment as wrong ("这不是 XXX"), saves a negative embedding sample,
        and strips the wrong label from the matched cluster/spans without requiring re-transcription."""
        profile = self.get_profile(profile_id) if profile_id else self.find_profile_by_name(speaker_name or "")
        clusters = self._find_clusters_for_selection(source_id, span_ids=span_ids, cluster_key=cluster_key)

        target_span_ids = list(span_ids or [])
        if clusters:
            seen_sids = {s.lower() for s in target_span_ids}
            for c in clusters:
                for sid in json.loads(c["span_ids"] or "[]"):
                    if sid.lower() not in seen_sids:
                        target_span_ids.append(sid)
                        seen_sids.add(sid.lower())

        rejected_vectors = 0
        now = time.time()
        with self.store.write():
            for c in clusters:
                if profile and c["embedding"]:
                    self.db.execute(
                        """
                        INSERT INTO voice_rejections(id, profile_id, embedding, source_id, cluster_key, reason, created_at)
                        VALUES(?,?,?,?,?,?,?)
                        """,
                        (str(uuid.uuid4()), profile["id"], c["embedding"], source_id, c["cluster_key"], reason, now),
                    )
                    rejected_vectors += 1
                self.db.execute(
                    """
                    UPDATE session_speaker_clusters
                    SET matched_profile_id=NULL, matched_name='说话人', match_score=NULL, match_margin=NULL,
                        locked_by_user=0, updated_at=?
                    WHERE source_id=? AND cluster_key=?
                    """,
                    (now, source_id, c["cluster_key"]),
                )
            for sid in target_span_ids:
                self.db.execute(
                    "DELETE FROM span_speaker_overrides WHERE source_id=? AND span_id=?",
                    (source_id, sid.lower()),
                )
            self.store.advance()

        excl_name = (profile["name"] if profile else str(speaker_name or "").strip())
        if excl_name and target_span_ids:
            self.store.exclude_speaker(excl_name, source_id=source_id, span_ids=target_span_ids)
        self.store.refresh_mac_source_speakers([source_id])

        return {
            "success": True,
            "profile_id": profile["id"] if profile else None,
            "speaker": excl_name,
            "rejected_vectors": rejected_vectors,
            "affected_spans": len(target_span_ids),
        }

    def _configured_thresholds(self) -> tuple[float, float]:
        thr = DEFAULT_LOCK_THRESHOLD
        margin = DEFAULT_LOCK_MARGIN
        try:
            for row in self.db.execute(
                "SELECT key, value FROM speech_settings WHERE key IN ('speaker_lock_threshold', 'speaker_lock_margin')"
            ):
                val = float(json.loads(row["value"]))
                if row["key"] == "speaker_lock_threshold":
                    thr = val
                elif row["key"] == "speaker_lock_margin":
                    margin = val
        except Exception:
            pass
        return thr, margin

    def rematch_history(
        self,
        *,
        profile_ids: list[str] | None = None,
        threshold: float | None = None,
        margin: float | None = None,
    ) -> dict[str, Any]:
        """Re-matches all unlocked historical speaker clusters across all recordings using cached
        192-d ReDimNet2+ vectors — ZERO audio re-decoding or CoreML re-inference (<100ms)."""
        t0 = time.perf_counter()
        cfg_thr, cfg_margin = self._configured_thresholds()
        eff_thr = cfg_thr if threshold is None else float(threshold)
        eff_margin = cfg_margin if margin is None else float(margin)
        protos = self._load_profile_prototypes()
        allowed_pids = set(profile_ids) if profile_ids else None

        rows = self.db.execute(
            """
            SELECT source_id, window_id, raw_speaker_tag, cluster_key, embedding,
                   matched_profile_id, matched_name, locked_by_user, span_ids
            FROM session_speaker_clusters
            WHERE embedding IS NOT NULL AND locked_by_user = 0
            """
        ).fetchall()

        # Pre-seed cannot-link per (source_id, window_id, half) with already user-locked profiles
        def _half(tag: str) -> str:
            idx = tag.rfind("_")
            return tag[:idx] if tag.startswith("B") and idx > 0 else "B1"

        claimed_by_window: dict[tuple[str, str, str], set[str]] = {}
        for lrow in self.db.execute(
            "SELECT source_id, window_id, raw_speaker_tag, matched_profile_id FROM session_speaker_clusters WHERE locked_by_user = 1 AND matched_profile_id IS NOT NULL"
        ):
            wk = (lrow["source_id"], lrow["window_id"], _half(str(lrow["raw_speaker_tag"] or "")))
            claimed_by_window.setdefault(wk, set()).add(lrow["matched_profile_id"])

        scored: list[tuple[float, sqlite3.Row, dict[str, Any]]] = []
        for row in rows:
            vec = unpack_embedding(row["embedding"])
            if not vec:
                continue
            res = self.match_embedding(vec, threshold=eff_thr, margin=eff_margin, prototypes=protos)
            if not res["matched"]:
                continue
            scored.append((res["score"], row, res))
        scored.sort(key=lambda x: x[0], reverse=True)

        updated_clusters = 0
        updated_spans = 0
        touched_sources: set[str] = set()
        now = time.time()

        with self.store.write():
            for _, row, res in scored:
                wk = (row["source_id"], row["window_id"], _half(str(row["raw_speaker_tag"] or "")))
                claimed = claimed_by_window.setdefault(wk, set())
                pid = res["profile_id"]
                if pid in claimed:
                    continue
                claimed.add(pid)
                if allowed_pids is not None and pid not in allowed_pids:
                    continue
                if row["matched_profile_id"] == pid and row["matched_name"] == res["name"]:
                    continue

                self.db.execute(
                    """
                    UPDATE session_speaker_clusters
                    SET matched_profile_id=?, matched_name=?, match_score=?, match_margin=?, updated_at=?
                    WHERE source_id=? AND cluster_key=?
                    """,
                    (
                        pid,
                        res["name"],
                        res["score"],
                        res["margin"],
                        now,
                        row["source_id"],
                        row["cluster_key"],
                    ),
                )
                updated_clusters += 1
                span_ids = json.loads(row["span_ids"] or "[]")
                for sid in span_ids:
                    updated_spans += self.db.execute(
                        """
                        INSERT INTO span_speaker_overrides(source_id, span_id, speaker, is_owner, reason, updated_at)
                        VALUES(?,?,?,?,?,?)
                        ON CONFLICT(source_id, span_id) DO UPDATE SET
                            speaker=excluded.speaker, is_owner=excluded.is_owner,
                            reason=excluded.reason, updated_at=excluded.updated_at
                        """,
                        (
                            row["source_id"],
                            str(sid).lower(),
                            res["name"],
                            int(bool(res["is_owner"])),
                            f"Voiceprint rematch ({res['score']:.2f})",
                            now,
                        ),
                    ).rowcount
                touched_sources.add(row["source_id"])
            if updated_clusters > 0:
                self.store.advance()

        if touched_sources:
            self.store.refresh_mac_source_speakers(touched_sources)

        elapsed_ms = (time.perf_counter() - t0) * 1000.0
        return {
            "scanned_clusters": len(rows),
            "updated_clusters": updated_clusters,
            "updated_spans": updated_spans,
            "touched_sources": sorted(touched_sources),
            "elapsed_ms": round(elapsed_ms, 2),
        }

    # ------------------------------------------------------------------
    # Dynamic MOSS Hotwords Builder (Voiceprints + Memory)
    # ------------------------------------------------------------------

    def build_hotwords(self, custom_hotwords: list[str] | None = None, limit: int = 32) -> list[str]:
        terms: list[str] = []
        seen: set[str] = set()

        def _add(val: str) -> None:
            s = str(val or "").strip()
            if not s or len(s) > 40 or s in ("我", "说话人"):
                return
            key = s.casefold()
            if key not in seen:
                seen.add(key)
                terms.append(s)

        for hw in custom_hotwords or []:
            _add(hw)

        for r in self.db.execute("SELECT name, aliases FROM voice_profiles ORDER BY is_owner DESC, updated_at DESC"):
            _add(r["name"])
            for alias in json.loads(r["aliases"] or "[]"):
                _add(alias)

        # Pull recent person/project titles from Mac memory directory if present
        memory_root = self.data_dir / "memory"
        for subdir in ("people", "projects"):
            d = memory_root / subdir
            if not d.is_dir():
                continue
            files = sorted(d.glob("*.md"), key=lambda p: p.stat().st_mtime, reverse=True)[:12]
            for f in files:
                try:
                    first_line = f.read_text(encoding="utf-8", errors="ignore").splitlines()[0]
                    title = first_line.lstrip("#").strip()
                    if title:
                        _add(title)
                except Exception:
                    pass
            if len(terms) >= limit:
                break
        return terms[:limit]

    # ------------------------------------------------------------------
    # Internal Helpers
    # ------------------------------------------------------------------

    def _find_clusters_for_selection(
        self,
        source_id: str,
        *,
        span_ids: list[str] | None = None,
        cluster_key: str | None = None,
    ) -> list[sqlite3.Row]:
        if cluster_key:
            row = self.db.execute(
                "SELECT * FROM session_speaker_clusters WHERE source_id=? AND cluster_key=?",
                (source_id, cluster_key),
            ).fetchone()
            return [row] if row else []
        wanted = {str(s).lower() for s in (span_ids or []) if str(s).strip()}
        if not wanted:
            return []
        rows = self.db.execute(
            "SELECT * FROM session_speaker_clusters WHERE source_id=?", (source_id,)
        ).fetchall()
        matched = []
        for r in rows:
            c_spans = {str(s).lower() for s in json.loads(r["span_ids"] or "[]")}
            if c_spans & wanted:
                matched.append(r)
        return matched
