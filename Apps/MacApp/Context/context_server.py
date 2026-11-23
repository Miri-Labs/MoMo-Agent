"""Authenticated source sync and transcript processing through DeepSeek Harness."""
import base64
import hmac
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import logging
import os
from pathlib import Path
import re
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from context_store import ContextStore, Conflict
from mac_audio_pipeline import MacAudioPipeline, MacSpeechBridgeClient
from voiceprint_store import VoiceprintStore
from momo_memory import MoMoMemory, memory_home
import daily_review
import transcript_ingestion
import memory_review
import recording_summary
from life_illustrations import LifeIllustrations
from device_telemetry import read_device_telemetry, sync_device_telemetry
from health_store import read_health, sync_health
from phone_sources import read_phone_sources, sync_phone_source
from connectors import (
    ConnectorError,
    configure_email_connector,
    connectors_status,
    disconnect_connector,
    list_connector_items,
    read_connector_item,
    start_feishu_oauth,
    sync_connectors,
)
from situational_context import read_situational_context
import life_pulse


class ContextService:
    def __init__(self, data, connection):
        self.data = Path(data)
        self.directory = self.data / "context"
        self.connection = connection
        self.key = (self.data / "api-key").read_text().strip()
        self.memory = MoMoMemory(self.data)
        self.stopped = threading.Event()
        self.illustration_wake = threading.Event()
        self.illustration_manual = threading.Event()
        self.audio_wake = threading.Event()
        self.next_dispatch = time.monotonic() + 60
        base_port = int(connection.get("port") or (urllib.parse.urlsplit(connection["data_url"]).port - 1))
        speech_url = os.environ.get("MOMO_SPEECH_URL") or f"http://127.0.0.1:{base_port + 4}"
        self.speech_bridge = MacSpeechBridgeClient(speech_url, self.key)
        store = ContextStore(self.directory); store.close()
        illustrations = LifeIllustrations(self.data); illustrations.recover(); illustrations.close()
        service = self

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *_):
                pass  # Do not put personal source content or credentials into access logs.

            def respond(self, code, body):
                encoded = json.dumps(body, ensure_ascii=False).encode()
                self.send_response(code)
                self.send_header("Content-Type", "application/json; charset=utf-8")
                self.send_header("Content-Length", str(len(encoded)))
                self.send_header("Cache-Control", "no-store")
                self.end_headers()
                self.wfile.write(encoded)

            def respond_audio_file(self, file_path: Path, content_type: str, extra_headers: dict | None = None):
                total_size = file_path.stat().st_size
                range_hdr = self.headers.get("Range")
                start, end = 0, total_size - 1
                partial = False
                if range_hdr and range_hdr.startswith("bytes="):
                    spec = range_hdr[6:].split(",", 1)[0].strip()
                    if "-" in spec:
                        s_part, e_part = spec.split("-", 1)
                        if s_part:
                            start = max(0, int(s_part))
                            end = min(total_size - 1, int(e_part)) if e_part else total_size - 1
                        elif e_part:
                            length = max(1, int(e_part))
                            start = max(0, total_size - length)
                            end = total_size - 1
                        if start > end or start >= total_size:
                            self.send_response(416)
                            self.send_header("Content-Range", f"bytes */{total_size}")
                            self.end_headers()
                            return
                        partial = True
                length = max(0, end - start + 1)
                with open(file_path, "rb") as f:
                    f.seek(start)
                    chunk = f.read(length)
                self.send_response(206 if partial else 200)
                self.send_header("Content-Type", content_type)
                self.send_header("Accept-Ranges", "bytes")
                self.send_header("Content-Length", str(len(chunk)))
                if partial:
                    self.send_header("Content-Range", f"bytes {start}-{end}/{total_size}")
                self.send_header("Cache-Control", "private, no-store")
                for k, v in (extra_headers or {}).items():
                    self.send_header(k, str(v))
                self.end_headers()
                self.wfile.write(chunk)

            def _read_body_bytes(self, max_bytes: int = 8_000_000) -> bytes:
                size = int(self.headers.get("Content-Length", "0"))
                if size < 0 or size > max_bytes:
                    raise ValueError(f"Request body exceeds {max_bytes} bytes")
                return self.rfile.read(size) if size > 0 else b""

            def _read_audio_payload(self) -> tuple[bytes, dict]:
                raw = self._read_body_bytes(8_000_000)
                ctype = (self.headers.get("Content-Type") or "").lower()
                if "application/json" in ctype:
                    obj = json.loads(raw.decode("utf-8")) if raw else {}
                    b64 = obj.get("audio_base64") or ""
                    audio = base64.b64decode(b64) if b64 else b""
                    meta = obj.get("meta") if isinstance(obj.get("meta"), dict) else obj
                    return audio, meta
                meta_hdr = self.headers.get("X-MoMo-Chunk-Meta", "")
                meta = {}
                if meta_hdr:
                    try:
                        meta = json.loads(base64.b64decode(meta_hdr).decode("utf-8"))
                    except Exception:
                        meta = json.loads(meta_hdr)
                return raw, meta

            def handle_request(self):
                supplied = self.headers.get("Authorization", "")
                if not hmac.compare_digest(supplied.encode(), ("Bearer " + service.key).encode()):
                    self.respond(401, {"error": {"code": "unauthorized", "message": "Invalid connection credential"}})
                    return
                store = ContextStore(service.directory)
                illustrations = None
                try:
                    url = urllib.parse.urlsplit(self.path)
                    query = urllib.parse.parse_qs(url.query)
                    after = query.get("after", [""])[0]
                    limit = int(query.get("limit", ["100"])[0])
                    if url.path.startswith('/v1/life-illustrations/'):
                        illustrations = LifeIllustrations(service.data)
                        illustrations.reconcile(store)
                        suffix = url.path.removeprefix('/v1/life-illustrations/')
                        if suffix in ('settings', 'retry', 'regenerate'):
                            from life_illustration_generator import CodexIllustrationGenerator
                            availability = CodexIllustrationGenerator(service.data).availability()
                        if self.command == 'POST':
                            size = int(self.headers.get('Content-Length', '0'))
                            if size > 4096 or (suffix != 'retry' and size <= 0):
                                self.respond(413, {'error': {'code': 'body_too_large'}}); return
                            body = json.loads(self.rfile.read(size)) if size > 0 else {}
                            if suffix == 'settings':
                                result = illustrations.update_settings(body, availability)
                                if result.get('enabled'):
                                    service.illustration_wake.set()
                            elif suffix == 'retry':
                                if not isinstance(body, dict) or body:
                                    raise ValueError('retry takes no parameters')
                                result = illustrations.retry_incomplete(store, availability)
                                service.illustration_wake.set()
                            elif suffix == 'regenerate':
                                if not isinstance(body, dict) or set(body) != {'id'}:
                                    raise ValueError('regenerate requires exact {"id": "<slot_id>"}')
                                result = illustrations.regenerate(body['id'], store, availability)
                                service.illustration_manual.set()
                                service.illustration_wake.set()
                            elif suffix == 'delete':
                                result = illustrations.delete(body['id'])
                            else:
                                self.respond(404, {'error': {'code': 'not_found'}}); return
                        elif suffix == 'settings':
                            result = illustrations.settings(availability)
                        elif suffix == 'manifest':
                            result = illustrations.manifest(query.get('cursor', ['0'])[0], limit)
                        elif suffix.startswith('assets/'):
                            raw = illustrations.asset(suffix.removeprefix('assets/'))
                            self.send_response(200)
                            self.send_header('Content-Type', 'image/png')
                            self.send_header('Content-Length', str(len(raw)))
                            self.send_header('Cache-Control', 'private, no-store')
                            self.end_headers(); self.wfile.write(raw); return
                        else:
                            self.respond(404, {'error': {'code': 'not_found'}}); return
                        self.respond(200, result); return

                    # ------------------------------------------------------------------
                    # Mac-as-Backend Speech, Audio Ingestion, Streaming & Voiceprint API
                    # ------------------------------------------------------------------
                    if (
                        url.path.startswith("/v1/audio/")
                        or url.path.startswith("/v1/transcription/")
                        or url.path.startswith("/v1/speech/")
                        or url.path.startswith("/v1/voiceprints/")
                    ):
                        pipeline = MacAudioPipeline(store, data_dir=service.data)
                        vp = pipeline.voiceprints

                        if url.path == "/v1/audio/chunks" and self.command == "POST":
                            audio_bytes, meta = self._read_audio_payload()
                            result = pipeline.ingest_audio_chunk(meta=meta, audio_bytes=audio_bytes)
                            service.audio_wake.set()
                            self.respond(200, result); return
                        if url.path == "/v1/audio/chunks" and self.command == "GET":
                            sid = query.get("source_id", [""])[0]
                            if not sid:
                                raise ValueError("source_id query parameter is required")
                            self.respond(200, {"source_id": sid, "chunks": pipeline.list_source_audio_chunks(sid)}); return
                        if url.path == "/v1/audio/chunks/batch-status" and self.command == "POST":
                            body = json.loads(self._read_body_bytes(262_144) or b"{}")
                            self.respond(200, pipeline.batch_chunk_status(body.get("chunk_ids") or [])); return
                        if url.path == "/v1/audio/stream" and self.command == "GET":
                            chunk_id = query.get("chunk_id", [None])[0]
                            source_id = query.get("source_id", [None])[0]
                            at_ts_raw = query.get("at", [None])[0]
                            at_ts = float(at_ts_raw) if at_ts_raw is not None else None
                            fpath, ctype, rec_at = pipeline.resolve_audio_file(
                                chunk_id=chunk_id, source_id=source_id, at_timestamp=at_ts
                            )
                            self.respond_audio_file(fpath, ctype, {"X-MoMo-Chunk-Recorded-At": f"{rec_at:.3f}"})
                            return

                        if url.path == "/v1/transcription/status" and self.command == "GET":
                            self.respond(200, pipeline.transcription_status(service.speech_bridge)); return
                        if url.path == "/v1/transcription/retranscribe" and self.command == "POST":
                            body = json.loads(self._read_body_bytes(65_536) or b"{}")
                            result = pipeline.request_retranscribe(body["source_id"])
                            service.audio_wake.set()
                            self.respond(200, result); return

                        if url.path == "/v1/speech/settings":
                            if self.command == "GET":
                                self.respond(200, pipeline.read_settings()); return
                            if self.command in ("POST", "PATCH"):
                                body = json.loads(self._read_body_bytes(65_536) or b"{}")
                                result = pipeline.update_settings(body)
                                if not result.get("paused"):
                                    service.audio_wake.set()
                                self.respond(200, result); return
                        if url.path == "/v1/speech/dictate" and self.command == "POST":
                            audio_bytes, meta = self._read_audio_payload()
                            fname = self.headers.get("X-MoMo-Filename") or str(meta.get("filename") or "dictate.m4a")
                            result = pipeline.dictate_audio(service.speech_bridge, audio_bytes=audio_bytes, filename=fname)
                            self.respond(200, result); return

                        if url.path == "/v1/voiceprints/profiles":
                            if self.command == "GET":
                                self.respond(200, {"profiles": vp.list_profiles()}); return
                            if self.command == "POST":
                                body = json.loads(self._read_body_bytes(65_536) or b"{}")
                                prof = vp.create_or_update_profile(
                                    name=body.get("name", ""),
                                    is_owner=bool(body.get("is_owner", False)),
                                    aliases=body.get("aliases"),
                                    memory_file=body.get("memory_file"),
                                    notes=body.get("notes"),
                                )
                                self.respond(200, prof); return

                        m_prof = re.fullmatch(r"/v1/voiceprints/profiles/([A-Za-z0-9_-]+)", url.path)
                        if m_prof:
                            pid = m_prof.group(1)
                            if self.command == "GET":
                                prof = vp.get_profile(pid)
                                if not prof:
                                    raise FileNotFoundError("Voice profile not found")
                                self.respond(200, prof); return
                            if self.command == "PATCH":
                                body = json.loads(self._read_body_bytes(65_536) or b"{}")
                                existing = vp.get_profile(pid)
                                if not existing:
                                    raise FileNotFoundError("Voice profile not found")
                                prof = vp.create_or_update_profile(
                                    profile_id=pid,
                                    name=body.get("name", existing["name"]),
                                    is_owner=bool(body.get("is_owner", existing["is_owner"])),
                                    aliases=body.get("aliases"),
                                    memory_file=body.get("memory_file"),
                                    notes=body.get("notes"),
                                )
                                self.respond(200, prof); return
                            if self.command == "DELETE":
                                self.respond(200, vp.delete_profile(pid)); return

                        m_samples = re.fullmatch(r"/v1/voiceprints/profiles/([A-Za-z0-9_-]+)/samples", url.path)
                        if m_samples and self.command == "POST":
                            pid = m_samples.group(1)
                            audio_bytes, meta = self._read_audio_payload()
                            fname = self.headers.get("X-MoMo-Filename") or str(meta.get("filename") or "sample.m4a")
                            dev = self.headers.get("X-MoMo-Device-Kind") or str(meta.get("source_device") or "mac")
                            kind = str(meta.get("source_kind") or "enrollment")
                            result = pipeline.enroll_profile_sample_from_audio(
                                service.speech_bridge,
                                profile_id=pid,
                                audio_bytes=audio_bytes,
                                filename=fname,
                                source_device=dev,
                                source_kind=kind,
                            )
                            self.respond(200, result); return

                        m_sample_audio = re.fullmatch(r"/v1/voiceprints/profiles/([A-Za-z0-9_-]+)/samples/([A-Za-z0-9_-]+)/audio", url.path)
                        if m_sample_audio and self.command == "GET":
                            clip = vp.sample_clip_path(m_sample_audio.group(1), m_sample_audio.group(2))
                            if clip is None:
                                raise FileNotFoundError("Voice sample clip not found")
                            ctype = "audio/wav" if clip.suffix.lower() == ".wav" else "audio/mp4"
                            self.respond_audio_file(clip, ctype); return

                        m_sample_del = re.fullmatch(r"/v1/voiceprints/profiles/([A-Za-z0-9_-]+)/samples/([A-Za-z0-9_-]+)", url.path)
                        if m_sample_del and self.command == "DELETE":
                            self.respond(200, vp.delete_sample(m_sample_del.group(1), m_sample_del.group(2))); return

                        if url.path == "/v1/voiceprints/bind-transcript" and self.command == "POST":
                            body = json.loads(self._read_body_bytes(131_072) or b"{}")
                            result = vp.bind_transcript_speaker(
                                source_id=body["source_id"],
                                span_ids=body.get("span_ids"),
                                cluster_key=body.get("cluster_key"),
                                profile_id=body.get("profile_id"),
                                target_name=body.get("target_name"),
                                is_owner=bool(body.get("is_owner", False)),
                                enroll_voiceprint=bool(body.get("enroll_voiceprint", False)),
                                rematch_history=bool(body.get("rematch_history", True)),
                                scope=str(body.get("scope") or "cluster"),
                                reason=str(body.get("reason") or "User voiceprint binding"),
                            )
                            self.respond(200, result); return

                        if url.path == "/v1/voiceprints/reject" and self.command == "POST":
                            body = json.loads(self._read_body_bytes(131_072) or b"{}")
                            result = vp.reject_speaker_match(
                                source_id=body["source_id"],
                                profile_id=body.get("profile_id"),
                                speaker_name=body.get("speaker_name"),
                                span_ids=body.get("span_ids"),
                                cluster_key=body.get("cluster_key"),
                                reason=str(body.get("reason") or "User rejected speaker match"),
                            )
                            self.respond(200, result); return

                        if url.path == "/v1/voiceprints/rematch" and self.command == "POST":
                            body = json.loads(self._read_body_bytes(65_536) or b"{}")
                            settings = pipeline.read_settings()
                            result = vp.rematch_history(
                                profile_ids=body.get("profile_ids"),
                                threshold=float(body.get("threshold") or settings.get("speaker_lock_threshold", 0.56)),
                                margin=float(body.get("margin") or settings.get("speaker_lock_margin", 0.08)),
                            )
                            self.respond(200, result); return

                        self.respond(404, {"error": {"code": "not_found", "message": "Unknown speech/voiceprint route"}}); return
                    if self.command == "POST":
                        size = int(self.headers.get("Content-Length", "0"))
                        if not 0 < size <= 8_000_000:
                            self.respond(413, {"error": {"code": "body_too_large", "message": "Source exceeds 8 MB; nothing was truncated or accepted"}})
                            return
                        body = json.loads(self.rfile.read(size))
                        if url.path == "/v1/sources":
                            result = store.sync_source(body)
                            if body["spans"]:
                                try:
                                    service.request("/momo/v1/proactive/ingest",
                                                    {"origin": "source_sync", "source_id": result["source_id"]})
                                except (OSError, ValueError):
                                    # The phone retries the same committed revision if its wakeup was lost.
                                    self.respond(503, {"error": {"code": "ingest_unavailable",
                                                                 "message": "Transcript saved; retry delivery"}})
                                    return
                        elif url.path == "/v1/device-telemetry":
                            result = sync_device_telemetry(store, body)
                            service.maybe_emit_life_pulse(store)
                        elif url.path == "/v1/health":
                            result = sync_health(store, body)
                            service.maybe_emit_life_pulse(store)
                        elif url.path == "/v1/phone-sources":
                            result = sync_phone_source(store, body)
                            service.maybe_emit_life_pulse(store)
                        elif url.path == "/v1/summaries":
                            result = recording_summary.enqueue(store, body)
                        elif url.path == "/v1/memories/forget":
                            identity, revision = body["id"], body.get("base_revision")
                            if isinstance(identity, str) and identity.startswith("momo-page-") and revision is None:
                                raise Conflict("Refresh memory before forgetting a notebook")
                            result = service.memory.forget(identity, revision)
                        elif url.path == "/v1/memories/dream":
                            job, enqueued = memory_review.enqueue_manual_dream(store, service.data)
                            service.next_dispatch = 0
                            result = {"job_id": job["id"], "state": job["state"], "enqueued": enqueued}
                        elif url.path == "/v1/speakers/ack":
                            result = store.ack_speaker_relabels(body.get("ids") or [])
                        elif url.path == "/v1/connectors/email/configure":
                            result = configure_email_connector(service.data, body)
                            service.trigger_connector_sync("email")
                        elif url.path == "/v1/connectors/feishu/oauth/start":
                            result = start_feishu_oauth(
                                service.data,
                                body,
                                on_connected=lambda: service.trigger_connector_sync("feishu"),
                            )
                        elif url.path == "/v1/connectors/sync":
                            target = str(body.get("connector") or "all").strip()
                            result = sync_connectors(service.data, store, target)
                        elif url.path == "/v1/connectors/disconnect":
                            target = str(body.get("connector") or "").strip()
                            clear_data = bool(body.get("clear_data", False))
                            result = disconnect_connector(service.data, store, target, clear_data=clear_data)
                        else:
                            self.respond(404, {"error": {"code": "not_found", "message": "Unknown MoMo route"}}); return
                    elif url.path == "/v1/connectors":
                        result = connectors_status(service.data, store)
                    elif url.path == "/v1/connectors/items":
                        c_kind = query.get("connector", ["all"])[0]
                        c_limit = min(int(query.get("limit", ["30"])[0]), 100)
                        result = {"items": list_connector_items(store, connector=c_kind, limit=c_limit)}
                    elif url.path == "/v1/connectors/item":
                        item = read_connector_item(store, query.get("id", [""])[0])
                        if item is None:
                            self.respond(404, {"error": {"code": "not_found", "message": "Connector item not found"}}); return
                        result = item
                    elif url.path == "/v1/summaries":
                        result = recording_summary.read(store, query['id'][0])
                    elif url.path == "/v1/device-telemetry":
                        result = read_device_telemetry(store, after, limit=min(limit, 50))
                    elif url.path == "/v1/situation":
                        result = read_situational_context(store, data_dir=service.data)
                    elif url.path == "/v1/health":
                        result = read_health(store, after, limit=min(limit, 50), category=query.get("category", ["all"])[0])
                    elif url.path == "/v1/phone-sources":
                        result = read_phone_sources(store, query.get("kind", [""])[0], after, limit=min(limit, 100))
                    elif url.path == "/v1/memories":
                        revision = query.get("revision", [None])[0]
                        result = service.memory.list(after, limit, int(revision) if revision is not None else None)
                        result["workspace_id"] = connection["workspace_id"]
                    elif url.path == "/v1/sources":
                        summarize = query.get("summarize", ["0"])[0] == "1"
                        result = store.list_sources(after, min(limit, 200), summarize=summarize, include_organization=False)
                        for item in result["items"]:
                            item["summary"] = item.pop("recorded_summary", None); item["organization"] = None
                    elif url.path == "/v1/source":
                        source_limit = min(int(query.get("limit", ["12000"])[0]), 24_000)
                        result = store.read_source(query["source_id"][0], query["revision"][0], int(query.get("offset", ["0"])[0]), source_limit, location_offset=int(query.get("location_offset", ["0"])[0]))
                    elif url.path == "/v1/status":
                        result = {"application": "MoMoAgent", "workspace_id": connection["workspace_id"],
                                  "engine": "superagent",
                                  "revision": store.revision, "source_sync": True,
                                  "memories_watermark": service.memory.stat_watermark(),
                                  "sources_watermark": store.sources_watermark(),
                                  "memory_writer": "SuperAgent",
                                  "memory_pending": store.db.execute("SELECT COUNT(*) FROM jobs WHERE state IN ('pending','running')").fetchone()[0],
                                  "memory_needs_review": store.db.execute("SELECT COUNT(*) FROM jobs WHERE state='needs_review'").fetchone()[0]}
                        result['memory_review'] = memory_review.status(store)
                        result['speaker_relabels'] = store.pending_speaker_relabels(limit=32)
                        result['speaker_exclusions'] = store.pending_speaker_exclusions()
                        result['retire_unknown_speaker'] = bool(store.db.execute(
                            "SELECT 1 FROM speaker_relabel_queue WHERE new_speaker='身份待确认' LIMIT 1"
                        ).fetchone())
                    else:
                        self.respond(404, {"error": {"code": "not_found", "message": "Unknown MoMo route"}}); return
                    self.respond(200, result)
                except Conflict as error:
                    self.respond(409, {"error": {"code": "revision_conflict", "message": str(error)}})
                except ConnectorError as error:
                    self.respond(400, {"error": {"code": "connector_error", "message": str(error)}})
                except urllib.error.HTTPError as error:
                    detail = str(error)
                    try:
                        raw = error.read()
                        parsed = json.loads(raw.decode("utf-8")) if raw else {}
                        if isinstance(parsed, dict):
                            err_obj = parsed.get("error")
                            if isinstance(err_obj, str) and err_obj:
                                detail = err_obj
                            elif isinstance(err_obj, dict) and err_obj.get("message"):
                                detail = str(err_obj["message"])
                    except Exception:
                        pass
                    code = int(error.code) if 400 <= int(error.code) < 600 else 502
                    self.respond(code, {"error": {"code": "speech_engine_error", "message": detail}})
                except FileNotFoundError as error:
                    msg = "Audio or voiceprint resource is unavailable" if (
                        path.startswith("/v1/audio/") or path.startswith("/v1/voiceprints/")
                    ) else "Illustration is unavailable"
                    self.respond(404, {'error': {'code': 'not_found', 'message': msg}})
                except (ValueError, KeyError, TypeError) as error:
                    self.respond(400, {"error": {"code": "invalid_source", "message": str(error)}})
                except Exception as error:
                    logging.error("MoMo context transaction failed: %s", type(error).__name__)
                    self.respond(500, {"error": {"code": "storage_failure", "message": "MoMo context could not be committed"}})
                finally:
                    store.close()
                    if illustrations:
                        illustrations.close()

            do_GET = handle_request
            do_POST = handle_request
            do_PATCH = handle_request
            do_DELETE = handle_request

        address = urllib.parse.urlsplit(connection["data_url"])
        self.server = ThreadingHTTPServer(("127.0.0.1", address.port), Handler)
        self.server.daemon_threads = True
        self.threads = [threading.Thread(target=self.server.serve_forever, daemon=True, name="momo-sync"),
                        threading.Thread(target=self.dispatch, daemon=True, name="momo-transcript-dispatch"),
                        threading.Thread(target=self.dispatch_summaries, daemon=True, name="momo-summary-dispatch"),
                        threading.Thread(target=self.dispatch_audio_transcription, daemon=True, name="momo-audio-transcription")]
        self.threads.append(threading.Thread(target=self.dispatch_illustrations, daemon=True, name='momo-life-illustrations'))

    def start(self):
        self._connector_sync_lock = threading.Lock()
        try:
            store = ContextStore(self.directory)
            try:
                MacAudioPipeline(store, data_dir=self.data).recover_interrupted()
            finally:
                store.close()
        except Exception as exc:
            logging.warning("MoMo Mac audio startup recovery skipped: %s", exc)
        for thread in self.threads:
            thread.start()

    def trigger_connector_sync(self, connector: str = "all") -> None:
        lock = getattr(self, "_connector_sync_lock", None)
        if lock is None:
            self._connector_sync_lock = threading.Lock()
            lock = self._connector_sync_lock
        if not lock.acquire(blocking=False):
            return

        def _run():
            try:
                store = ContextStore(self.directory)
                try:
                    sync_connectors(self.data, store, connector)
                finally:
                    store.close()
            except Exception:
                pass
            finally:
                lock.release()

        threading.Thread(target=_run, daemon=True, name=f"momo-connector-sync-{connector}").start()

    def close(self):
        self.stopped.set()
        self.illustration_wake.set()
        self.audio_wake.set()
        if self.threads[0].is_alive():
            self.server.shutdown()
        self.server.server_close()
        for thread in self.threads:
            if thread.ident is not None:
                thread.join(timeout=6)

    def dispatch_audio_transcription(self):
        """Background single-pass CoreML transcription worker (Silero VAD -> MOSS -> ReDimNet2+ -> ContextStore)."""
        last_prune = 0.0
        while not self.stopped.is_set():
            self.audio_wake.wait(4.0)
            self.audio_wake.clear()
            if self.stopped.is_set():
                break
            store = ContextStore(self.directory)
            try:
                pipeline = MacAudioPipeline(store, data_dir=self.data)

                def _notify_ingest(source_id, _sync_res):
                    try:
                        self.request("/momo/v1/proactive/ingest", {"origin": "mac_audio_transcription", "source_id": source_id})
                    except Exception:
                        pass
                    self.illustration_wake.set()
                    self.next_dispatch = 0

                while not self.stopped.is_set():
                    res = pipeline.process_next_batch(self.speech_bridge, on_source_committed=_notify_ingest)
                    if res is None:
                        break
                now = time.monotonic()
                if now - last_prune >= 3600:
                    pipeline.prune_expired_audio()
                    last_prune = now
            except Exception as error:
                logging.error("MoMo Mac audio transcription dispatch failed: %s: %s", type(error).__name__, error)
            finally:
                store.close()

    def request(self, path, body=None, operation=None):
        headers = {"Authorization": "Bearer " + self.key, "Content-Type": "application/json",
                   "X-MoMo-Session-Key": "momo-memory:" + self.connection["assistant_id"]}
        if operation:
            headers["Idempotency-Key"] = operation
        request = urllib.request.Request(self.connection["base_url"] + path,
            data=json.dumps(body, sort_keys=True).encode() if body is not None else None, headers=headers)
        opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
        with opener.open(request, timeout=5) as response:
            return json.load(response)

    def background_quota_exhausted(self, now):
        from provider_notice import canonical_provider, read_provider_notice
        from model_setup import load_config
        notice = read_provider_notice(self.data, now=now)
        if not notice or notice['kind'] != 'quota':
            return False
        model = load_config(self.data).get('model') or {}
        return isinstance(model, dict) and notice['provider'] == canonical_provider(model.get('provider'))

    def maybe_emit_life_pulse(self, store, now=None):
        conn = getattr(self, "connection", None)
        if not isinstance(conn, dict) or not conn.get("base_url") or not conn.get("assistant_id"):
            return None
        ts = time.time() if now is None else float(now)
        try:
            eng_file = Path(self.data) / "runtime/engine.json"
            if eng_file.is_file() and json.loads(eng_file.read_text(encoding="utf-8")).get("proactive_mode") == "off":
                return None
            if self.background_quota_exhausted(ts):
                return None
            return life_pulse.maybe_emit_pulse(
                store,
                lambda payload: self.request("/momo/v1/proactive/ingest", payload),
                data_dir=self.data,
                now=ts,
            )
        except Exception:
            return None

    def dispatch(self):
        # Only durable admission/reconciliation. Active runtime owns model calls, tools and execution.
        while not self.stopped.wait(2):
            store = ContextStore(self.directory)
            try:
                now = time.time()
                if time.monotonic() >= getattr(self, "next_pulse_dispatch", 0):
                    self.next_pulse_dispatch = time.monotonic() + 30
                    self.maybe_emit_life_pulse(store, now=now)
                if time.monotonic() >= getattr(self, "next_connector_sync", 0):
                    self.next_connector_sync = time.monotonic() + 900
                    self.trigger_connector_sync("all")
                review = store.db.execute(
                    "SELECT * FROM memory_reviews WHERE state='running' OR (state='pending' AND first_attempt IS NOT NULL) ORDER BY rowid LIMIT 1"
                ).fetchone()
                if review:
                    self.advance_review(store, review)
                    continue
                job = transcript_ingestion.next_job(store, now, False)
                if job:
                    self.advance_job(store, job)
                    continue
                manual = store.db.execute(
                    "SELECT * FROM memory_reviews WHERE state='pending' AND json_extract(input,'$.manual_requested_at') IS NOT NULL ORDER BY rowid LIMIT 1"
                ).fetchone()
                if manual:
                    self.advance_review(store, manual)
                    continue
                if time.monotonic() >= self.next_dispatch and memory_review.chat_idle(self.data, now):
                    self.next_dispatch = time.monotonic() + 60
                    if self.background_quota_exhausted(now):
                        continue
                    memory_review.recover_empty_legacy(store, memory_home(self.data))
                    review = memory_review.next_review(store, self.data, now)
                    if review:
                        self.advance_review(store, review)
            except Exception as error:
                logging.error("MoMo memory dispatch transaction failed: %s", type(error).__name__)
            finally:
                store.close()

    def dispatch_summaries(self):
        while not self.stopped.wait(2):
            store = ContextStore(self.directory)
            try:
                job = recording_summary.next_job(store)
                if job:
                    recording_summary.advance(store, job, self.request)
            except Exception as error:
                logging.error('MoMo summary dispatch failed: %s', type(error).__name__)
            finally:
                store.close()

    def dispatch_illustrations(self):
        # A separate worker and idle admission keep image work out of chat and summary queues.
        while not self.stopped.is_set():
            self.illustration_wake.wait(30)
            self.illustration_wake.clear()
            if self.stopped.is_set():
                break
            store = ContextStore(self.directory)
            illustrations = LifeIllustrations(self.data)
            try:
                from life_illustration_generator import CodexIllustrationGenerator
                generator = CodexIllustrationGenerator(self.data)
                if generator.availability()['supported']:
                    illustrations.scan(store)
                    manual = self.illustration_manual.is_set()
                    if manual:
                        self.illustration_manual.clear()
                    while not self.stopped.is_set() and (manual or memory_review.chat_idle(self.data, time.time(), idle_seconds=60)):
                        manual = False
                        if not illustrations.advance(generator, store):
                            break
                else:
                    illustrations.reconcile(store)
            except Exception as error:
                logging.error('MoMo illustration dispatch failed: %s', type(error).__name__)
            finally:
                illustrations.close(); store.close()

    @staticmethod
    def review_timed_out(job, snapshot, now):
        if snapshot.get("updated_at"):
            return now - float(snapshot["updated_at"]) > 420
        # Older gateways do not publish tool-round progress.
        return ((job["first_attempt"] and now - job["first_attempt"] > 420)
                or (job["replay_before"] and now >= job["replay_before"]))

    def advance_job(self, store, job):
        try:
            if job["run_id"]:
                snapshot = self.request("/v1/runs/" + urllib.parse.quote(job["run_id"], safe=""))
            else:
                batch = transcript_ingestion.prepare(store, job)
                if not batch["passages"]:
                    transcript_ingestion.finish(store, job)
                    return
                first, deadline = job["first_attempt"], job["replay_before"]
                if first is None:
                    guarantee = self.request("/v1/capabilities")["features"]["runs_idempotency"]
                    if not guarantee.get("durable") or not guarantee.get("supported") or guarantee.get("retention_seconds", 0) <= 120:
                        raise Conflict("Gateway lacks durable transcript admission")
                    first = time.time(); deadline = first + guarantee["retention_seconds"] - 60
                    claimed = store.db.execute("UPDATE jobs SET first_attempt=?,replay_before=? WHERE id=? AND state='pending'",
                                               (first, deadline, job["id"])).rowcount
                    if not claimed:
                        return  # A source update superseded this unadmitted batch.
                if time.time() >= deadline:
                    raise Conflict("Memory admission receipt expired; inspect the original run")
                prompt = transcript_ingestion.prompt(batch)
                snapshot = self.request("/v1/runs", {"input": prompt, "session_id": "momo-transcript-" + job["id"]}, job["id"])
                store.db.execute("UPDATE jobs SET run_id=?,state='running',error=NULL WHERE id=? AND state='pending'",
                                 (snapshot["run_id"], job["id"]))
                snapshot = self.request("/v1/runs/" + urllib.parse.quote(snapshot["run_id"], safe=""))
            if snapshot.get("session_id") != "momo-transcript-" + job["id"] or not snapshot.get("run_id") or (job["run_id"] and snapshot["run_id"] != job["run_id"]):
                raise Conflict("Memory task identity mismatch")
            status = snapshot["status"]
            if status == "completed":
                receipt = memory_review.outcome(memory_home(self.data), snapshot['session_id'], snapshot.get('output'))
                transcript_ingestion.finish(store, job, receipt)
            elif status == 'failed':
                memory_review.handle_failed_run(store, 'jobs', job, snapshot)
            elif status in {"started", "queued", "running", "stopping"}:
                now_ts = time.time()
                if self.review_timed_out(job, snapshot, now_ts):
                    if memory_review.retry_completed(store, 'jobs', job, 'Memory run timed out'):
                        return
                    raise Conflict("Memory execution timed out")
            else:
                raise Conflict("Memory execution needs review: " + status)
        except Exception as error:
            if isinstance(error, urllib.error.HTTPError) and error.code == 404 and job["run_id"]:
                if memory_review.retry_completed(store, 'jobs', job, 'Memory run missing'):
                    return
            review = isinstance(error, Conflict) or isinstance(error, urllib.error.HTTPError) and error.code in {400, 403, 404, 409, 410, 422}
            # Keep the same admission key after a transient failure or lost acknowledgement.
            store.db.execute("UPDATE jobs SET state=CASE WHEN ? THEN 'needs_review' ELSE state END,error=? WHERE id=? AND state IN ('pending','running')",
                             (int(review), str(error)[:500], job["id"]))

    def advance_review(self, store, job):
        session = 'momo-review-' + job['id']
        try:
            if job['run_id']:
                snapshot = self.request('/v1/runs/' + urllib.parse.quote(job['run_id'], safe=''))
            else:
                deadline = job['replay_before']
                if job['first_attempt'] is None:
                    guarantee = self.request('/v1/capabilities')['features']['runs_idempotency']
                    if not guarantee.get('durable') or not guarantee.get('supported') or guarantee.get('retention_seconds', 0) <= 120:
                        raise Conflict('Gateway lacks durable memory admission')
                    first = time.time(); deadline = first + guarantee['retention_seconds'] - 60
                    with store.write():
                        job = store.db.execute("""UPDATE memory_reviews SET first_attempt=?,replay_before=?
                            WHERE id=? AND state='pending' AND first_attempt IS NULL RETURNING *""",
                            (first, deadline, job['id'])).fetchone()
                        if job is None:
                            return
                        if json.loads(job['input']).get('daily'):
                            job = daily_review.skip_superseded_in_transaction(store, job)
                if time.time() >= deadline:
                    raise Conflict('Memory review admission receipt expired; inspect the original run')
                prompt = daily_review.prompt(store, job) if json.loads(job['input']).get('daily') else memory_review.prompt(job)
                snapshot = self.request('/v1/runs', {'input': prompt, 'session_id': session}, job['id'])
                store.db.execute("UPDATE memory_reviews SET run_id=?,state='running',error=NULL WHERE id=?", (snapshot['run_id'],job['id']))
                snapshot = self.request('/v1/runs/' + urllib.parse.quote(snapshot['run_id'], safe=''))
            if snapshot.get('session_id') != session or not snapshot.get('run_id') or (job['run_id'] and snapshot['run_id'] != job['run_id']):
                raise Conflict('Memory review identity mismatch')
            if snapshot['status'] == 'completed':
                receipt = memory_review.outcome(memory_home(self.data), session, snapshot.get('output'))
                memory_review.finish(store, job, receipt, memory_home(self.data))
            elif snapshot['status'] == 'failed':
                memory_review.handle_failed_run(store, 'memory_reviews', job, snapshot)
            elif snapshot['status'] in {'started','queued','running','stopping'}:
                # The gateway owns the idle timeout. Only it can say a worker
                # has stopped writing; polling a stale heartbeat cannot.
                return
            else:
                raise Conflict('Memory review execution needs review: ' + snapshot['status'])
        except Exception as error:
            if isinstance(error, urllib.error.HTTPError) and error.code == 404 and job['run_id']:
                if memory_review.retry_completed(store, 'memory_reviews', job, 'Memory review run missing'):
                    return
            review = isinstance(error, Conflict) or isinstance(error, urllib.error.HTTPError) and error.code in {400,403,404,409,410,422}
            store.db.execute("UPDATE memory_reviews SET state=CASE WHEN ? THEN 'needs_review' ELSE state END,error=? WHERE id=? AND state IN ('pending','running')",
                             (int(review),str(error)[:500],job['id']))
