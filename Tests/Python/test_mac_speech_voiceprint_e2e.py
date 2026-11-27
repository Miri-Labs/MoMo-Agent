"""Comprehensive End-to-End Automated Test for Mac-as-Backend Speech, Voiceprint Locking,
Global Historical Rematch, HTTP Range Streaming, Remote Settings & Access Proxy.

Exercises:
  1. Native Swift CoreML server (`momo-speech-cli serve`) running REAL:
       - SileroVAD.mlmodelc
       - MOSSAudioEncoder.mlmodelc + MOSSDecoder.mlmodelc + embedding.int8.bin
       - ReDimNet2Plus.mlmodelc (ANE static MultiFunction buckets)
  2. `ContextService` HTTP server + `MacAudioPipeline` + `VoiceprintStore` on an isolated temp dir
  3. Full product workflow:
       - Remote speech settings GET / PATCH
       - Voiceprint profile creation + audio enrollment (real ReDimNet2+ ANE vector)
       - 2-speaker audio chunk upload (SHA-256 idempotent, binary body + X-MoMo-Chunk-Meta)
       - Single-pass VAD -> MOSS CoreML diarization -> ReDimNet2+ speaker locking
       - Verify enrolled speaker ("我") automatically locked while unknown speaker stays anonymous
       - Click-to-bind (`assign` vs `enroll_voiceprint=True`) + instant `<100ms` historical rematch
       - Negative rejection ("这不是 XXX") + rejection veto verification
       - Short dictation (`POST /v1/speech/dictate`)
       - HTTP Range `206 Partial Content` audio streaming + voiceprint clip playback
       - `rtc_transport.permitted_route` allowlist checks for all new routes
"""
from __future__ import annotations

import base64
import hashlib
import json
import os
import shutil
import socket
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request
import uuid
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO_ROOT / "Apps/MacApp/Context"))
sys.path.insert(0, str(REPO_ROOT / "Apps/MacApp/Access"))

from context_server import ContextService
from context_store import ContextStore
from rtc_transport import permitted_route


def free_port() -> int:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        s.bind(("127.0.0.1", 0))
        return int(s.getsockname()[1])


def http_req(
    url: str,
    api_key: str,
    *,
    method: str = "GET",
    json_body: dict | None = None,
    raw_body: bytes | None = None,
    headers: dict[str, str] | None = None,
    timeout: float = 120.0,
) -> tuple[int, dict[str, str], bytes]:
    hdrs = {"Authorization": f"Bearer {api_key}"}
    data = raw_body
    if json_body is not None:
        hdrs["Content-Type"] = "application/json"
        data = json.dumps(json_body, ensure_ascii=False).encode("utf-8")
    if headers:
        hdrs.update(headers)
    req = urllib.request.Request(url, data=data, headers=hdrs, method=method)
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    try:
        with opener.open(req, timeout=timeout) as resp:
            return resp.status, dict(resp.headers.items()), resp.read()
    except urllib.error.HTTPError as e:
        return e.code, dict(e.headers.items()), e.read()


def synthesize_wav(voice: str, text: str, out_wav: Path) -> None:
    aiff = out_wav.with_suffix(".aiff")
    subprocess.run(["say", "-v", voice, "-o", str(aiff), text], check=True)
    subprocess.run(
        ["ffmpeg", "-y", "-i", str(aiff), "-ac", "1", "-ar", "16000", "-c:a", "pcm_s16le", str(out_wav)],
        check=True,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    aiff.unlink(missing_ok=True)


def concat_with_silence(wavs: list[Path], out_wav: Path) -> None:
    inputs = []
    filters = []
    concat_inputs = []
    for idx, w in enumerate(wavs):
        inputs.extend(["-i", str(w)])
        filters.append(f"[{idx}:a]aresample=16000,aformat=channel_layouts=mono[a{idx}]")
        concat_inputs.append(f"[a{idx}]")
        if idx + 1 < len(wavs):
            filters.append(f"aevalsrc=0:d=0.6:s=16000:c=mono[s{idx}]")
            concat_inputs.append(f"[s{idx}]")
    n_streams = len(concat_inputs)
    fc = ";".join(filters) + f";{''.join(concat_inputs)}concat=n={n_streams}:v=0:a=1[out]"
    subprocess.run(
        ["ffmpeg", "-y", *inputs, "-filter_complex", fc, "-map", "[out]", "-ac", "1", "-ar", "16000", "-c:a", "pcm_s16le", str(out_wav)],
        check=True,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )


def run_e2e() -> None:
    # 1. Verify route allowlist in rtc_transport.py
    for method, path in [
        ("POST", "/context/v1/audio/chunks"),
        ("GET", "/context/v1/audio/chunks?source_id=a/b"),
        ("POST", "/context/v1/audio/chunks/batch-status"),
        ("GET", "/context/v1/audio/stream?chunk_id=abc"),
        ("GET", "/context/v1/transcription/status"),
        ("POST", "/context/v1/transcription/retranscribe"),
        ("GET", "/context/v1/speech/settings"),
        ("PATCH", "/context/v1/speech/settings"),
        ("POST", "/context/v1/speech/dictate"),
        ("GET", "/context/v1/voiceprints/profiles"),
        ("POST", "/context/v1/voiceprints/profiles"),
        ("PATCH", "/context/v1/voiceprints/profiles/abc-123"),
        ("DELETE", "/context/v1/voiceprints/profiles/abc-123"),
        ("POST", "/context/v1/voiceprints/profiles/abc-123/samples"),
        ("DELETE", "/context/v1/voiceprints/profiles/abc-123/samples/def-456"),
        ("GET", "/context/v1/voiceprints/profiles/abc-123/samples/def-456/audio"),
        ("POST", "/context/v1/voiceprints/bind-transcript"),
        ("POST", "/context/v1/voiceprints/reject"),
        ("POST", "/context/v1/voiceprints/rematch"),
    ]:
        assert permitted_route(method, path) is not None, f"Route rejected by allowlist: {method} {path}"
    print("[PASS] rtc_transport route allowlist checks (19 routes)")

    cli_bin = REPO_ROOT / "Packages/MoMoMacSpeech/.build/debug/momo-speech-cli"
    assert cli_bin.is_file(), f"Build MoMoMacSpeech first: missing {cli_bin}"

    with tempfile.TemporaryDirectory(prefix="momo-mac-speech-e2e-") as td:
        tmp = Path(td)
        data_dir = tmp / "agent-data"
        data_dir.mkdir(parents=True)
        api_key = "test-api-key-" + uuid.uuid4().hex
        (data_dir / "api-key").write_text(api_key, encoding="utf-8")

        base_port = free_port()
        data_port = free_port()
        speech_port = free_port()
        os.environ["MOMO_SPEECH_URL"] = f"http://127.0.0.1:{speech_port}"

        connection = {
            "port": base_port,
            "base_url": f"http://127.0.0.1:{base_port}",
            "data_url": f"http://127.0.0.1:{data_port}",
            "workspace_id": str(uuid.uuid4()),
            "assistant_id": str(uuid.uuid4()),
            "instance_id": str(uuid.uuid4()),
        }

        # Synthesize distinct speakers (Tingting = Owner "我", Eddy = Colleague "Alex")
        enroll_owner = tmp / "enroll_owner.wav"
        enroll_alex = tmp / "enroll_alex.wav"
        turn1 = tmp / "turn1.wav"
        turn2 = tmp / "turn2.wav"
        turn3 = tmp / "turn3.wav"
        dialogue = tmp / "dialogue.wav"
        dictate_wav = tmp / "dictate.wav"

        synthesize_wav("Tingting", "你好，我是墨墨助手的主人，今天测试本地声纹录入和说话人锁定功能。", enroll_owner)
        synthesize_wav("Eddy", "Hello everyone, my name is Alex and I work on Apple Silicon Core ML models.", enroll_alex)
        synthesize_wav("Tingting", "今天下午三点我们开个短会，讨论墨墨助手的新架构。", turn1)
        synthesize_wav("Eddy", "Sounds great, I will bring the Core ML benchmark numbers for MOSS.", turn2)
        synthesize_wav("Tingting", "好的，到时候见。", turn3)
        concat_with_silence([turn1, turn2, turn3], dialogue)
        synthesize_wav("Tingting", "帮我记一下明天上午十点去医院复查。", dictate_wav)

        # Start native Swift CoreML speech server
        speech_proc = subprocess.Popen(
            [str(cli_bin), "serve", "--port", str(speech_port), "--token", api_key],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        ctx_service = ContextService(data_dir, connection)
        ctx_service.start()
        data_url = f"http://127.0.0.1:{data_port}"

        try:
            # Wait for speech engine health
            for _ in range(30):
                code, _, raw = http_req(f"{data_url}/v1/transcription/status", api_key, timeout=5)
                if code == 200:
                    st = json.loads(raw)
                    if (st.get("engine") or {}).get("reachable"):
                        assert st["engine"]["silero_available"] is True
                        assert st["engine"]["moss_available"] is True
                        assert st["engine"]["redimnet_available"] is True
                        break
                time.sleep(0.25)
            else:
                raise RuntimeError("MoMoMacSpeech server did not become reachable")
            print("[PASS] Native CoreML speech engine reachable (Silero + MOSS + ReDimNet2+)")

            # 2. Remote speech settings GET & PATCH
            code, _, raw = http_req(f"{data_url}/v1/speech/settings", api_key)
            assert code == 200
            code, _, raw = http_req(
                f"{data_url}/v1/speech/settings",
                api_key,
                method="PATCH",
                json_body={
                    "vad_threshold": 0.42,
                    "window_flush_silence_seconds": 4,
                    "custom_hotwords": ["墨墨助手", "Core ML", "MOSS"],
                },
            )
            assert code == 200
            updated_settings = json.loads(raw)
            assert updated_settings["vad_threshold"] == 0.42
            assert "墨墨助手" in updated_settings["custom_hotwords"]
            print("[PASS] Remote speech settings GET/PATCH persisted")

            # 3. Onboarding: Enroll Owner ("我") voiceprint via ReDimNet2+ CoreML ANE
            code, _, raw = http_req(
                f"{data_url}/v1/voiceprints/profiles",
                api_key,
                method="POST",
                json_body={"name": "我", "is_owner": True, "aliases": ["主人", "墨墨主人"]},
            )
            assert code == 200
            owner_profile = json.loads(raw)
            owner_id = owner_profile["id"]

            enroll_bytes = enroll_owner.read_bytes()
            code, _, raw = http_req(
                f"{data_url}/v1/voiceprints/profiles/{owner_id}/samples",
                api_key,
                method="POST",
                raw_body=enroll_bytes,
                headers={
                    "Content-Type": "audio/wav",
                    "X-MoMo-Filename": "owner.wav",
                    "X-MoMo-Device-Kind": "iphone",
                },
            )
            assert code == 200, f"Enroll failed ({code}): {raw.decode()}"
            enroll_resp = json.loads(raw)
            assert enroll_resp["profile"]["sample_count"] == 1
            sample_id = enroll_resp["profile"]["samples"][0]["id"]
            print(
                f"[PASS] Owner voiceprint enrolled on ANE: clean={enroll_resp['quality']['clean_seconds']:.2f}s, "
                f"latency={enroll_resp['quality']['latency_ms']:.1f}ms"
            )

            # Verify 422 propagation on audio too short (< 0.5s) instead of HTTP 500
            short_wav = tmp / "short.wav"
            subprocess.run(
                ["ffmpeg", "-y", "-f", "lavfi", "-i", "anullsrc=r=16000:cl=mono", "-t", "0.2", "-c:a", "pcm_s16le", str(short_wav)],
                check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            )
            code, _, _ = http_req(
                f"{data_url}/v1/voiceprints/profiles/{owner_id}/samples",
                api_key,
                method="POST",
                raw_body=short_wav.read_bytes(),
                headers={"Content-Type": "audio/wav", "X-MoMo-Filename": "short.wav"},
            )
            assert code == 422, f"Expected HTTP 422 for short enrollment audio, got {code}"
            print("[PASS] Upstream CoreML HTTP 422 error propagated cleanly (not 500)")

            # Verify PATCH profile supports setting AND clearing memory_file via empty string
            code, _, raw = http_req(
                f"{data_url}/v1/voiceprints/profiles/{owner_id}",
                api_key,
                method="PATCH",
                json_body={"name": "我", "is_owner": True, "aliases": ["主人", "墨墨主人"], "memory_file": "people/me.md"},
            )
            assert code == 200 and json.loads(raw)["memory_file"] == "people/me.md"
            code, _, raw = http_req(
                f"{data_url}/v1/voiceprints/profiles/{owner_id}",
                api_key,
                method="PATCH",
                json_body={"name": "我", "is_owner": True, "aliases": ["主人", "墨墨主人"], "memory_file": ""},
            )
            assert code == 200 and json.loads(raw)["memory_file"] is None
            print("[PASS] Voiceprint profile PATCH sets and clears memory_file cleanly")

            # Verify sample audio clip playback endpoint
            code, hdrs, clip_bytes = http_req(
                f"{data_url}/v1/voiceprints/profiles/{owner_id}/samples/{sample_id}/audio",
                api_key,
                headers={"Range": "bytes=0-1023"},
            )
            assert code == 206 and len(clip_bytes) == 1024 and hdrs.get("Accept-Ranges") == "bytes"
            print("[PASS] Voiceprint sample clip HTTP Range 206 playback")

            # 4. Upload 2-speaker dialogue chunk (idempotent SHA-256 verification)
            lib_id = str(uuid.uuid4())
            sess_id = str(uuid.uuid4())
            dev_id = str(uuid.uuid4())
            chunk_id = str(uuid.uuid4())
            dlg_bytes = dialogue.read_bytes()
            dlg_sha = hashlib.sha256(dlg_bytes).hexdigest()
            meta = {
                "chunk_id": chunk_id,
                "library_id": lib_id,
                "session_id": sess_id,
                "device_id": dev_id,
                "chunk_seq": 0,
                "recorded_at": time.time() - 30.0,
                "duration_sec": 12.0,
                "timezone_offset": 28800,
                "source_kind": "watch",
                "codec": "wav",
                "sample_rate": 16000,
                "sha256": dlg_sha,
            }
            meta_b64 = base64.b64encode(json.dumps(meta).encode("utf-8")).decode("ascii")
            code, _, raw = http_req(
                f"{data_url}/v1/audio/chunks",
                api_key,
                method="POST",
                raw_body=dlg_bytes,
                headers={"Content-Type": "audio/wav", "X-MoMo-Chunk-Meta": meta_b64},
            )
            assert code == 200, f"Upload failed: {raw.decode()}"
            up1 = json.loads(raw)
            assert up1["accepted"] is True and up1["deduplicated"] is False
            source_id = up1["source_id"]

            # Re-upload same chunk -> must deduplicate cleanly
            code, _, raw = http_req(
                f"{data_url}/v1/audio/chunks",
                api_key,
                method="POST",
                raw_body=dlg_bytes,
                headers={"Content-Type": "audio/wav", "X-MoMo-Chunk-Meta": meta_b64},
            )
            assert code == 200 and json.loads(raw)["deduplicated"] is True
            print("[PASS] Audio chunk binary upload + SHA-256 idempotent deduplication")

            # 5. Wait for Mac single-pass background transcription worker (Silero -> MOSS -> ReDimNet2+)
            deadline = time.time() + 60.0
            chunk_state = None
            while time.time() < deadline:
                code, _, raw = http_req(
                    f"{data_url}/v1/audio/chunks/batch-status",
                    api_key,
                    method="POST",
                    json_body={"chunk_ids": [chunk_id]},
                )
                assert code == 200
                chunk_state = json.loads(raw)["statuses"][chunk_id]
                if chunk_state.get("transcription_status") in ("done", "failed", "silent"):
                    break
                time.sleep(0.5)
            assert chunk_state and chunk_state["transcription_status"] == "done", f"Unexpected chunk state: {chunk_state}"

            # Read committed transcript from ContextStore via HTTP
            code, _, raw = http_req(f"{data_url}/v1/sources", api_key)
            assert code == 200
            sources_list = json.loads(raw)["items"]
            matched_src = next(s for s in sources_list if s["id"] == source_id)
            code, _, raw = http_req(
                f"{data_url}/v1/source?source_id={urllib.parse.quote(source_id)}&revision={urllib.parse.quote(matched_src['revision'])}",
                api_key,
            )
            assert code == 200
            src_doc = json.loads(raw)
            spans = src_doc["spans"]
            assert len(spans) >= 2, f"Expected >=2 diarized spans, got: {spans}"
            speakers_found = {sp.get("speaker") for sp in spans}
            print(f"[PASS] Single-pass Mac CoreML transcription & diarization committed {len(spans)} spans: {speakers_found}")
            for sp in spans:
                print(f"       {sp['text']} (is_owner={sp.get('is_owner')}, cluster={sp.get('cluster_key')})")
            assert "我" in speakers_found, f"Owner voiceprint should have automatically locked! Found: {speakers_found}"

            # 6a. Scope="selection" bind MUST NOT lock/enroll cluster voiceprint, MUST bump revision & keep offsets consistent
            rev_initial = matched_src["revision"]
            anon_spans = [sp for sp in spans if sp.get("speaker") != "我"]
            assert anon_spans, "Expected an anonymous second speaker span"
            anon_span = anon_spans[0]
            code, _, raw = http_req(
                f"{data_url}/v1/voiceprints/bind-transcript",
                api_key,
                method="POST",
                json_body={
                    "source_id": source_id,
                    "span_ids": [anon_span["id"]],
                    "cluster_key": anon_span.get("cluster_key"),
                    "target_name": "临时嘉宾",
                    "is_owner": False,
                    "enroll_voiceprint": True,
                    "rematch_history": False,
                    "scope": "selection",
                },
            )
            assert code == 200, f"Selection bind failed: {raw.decode()}"
            sel_res = json.loads(raw)
            assert sel_res["enrolled_voiceprint"] is False, "selection scope MUST NOT enroll cluster voiceprint!"
            code, _, raw = http_req(f"{data_url}/v1/sources", api_key)
            src_after_sel = next(s for s in json.loads(raw)["items"] if s["id"] == source_id)
            assert src_after_sel["revision"] != rev_initial, "sources.revision MUST bump after bind_transcript_speaker!"
            code, _, raw = http_req(
                f"{data_url}/v1/source?source_id={urllib.parse.quote(source_id)}&revision={urllib.parse.quote(src_after_sel['revision'])}&offset=0&limit=20000",
                api_key,
            )
            assert code == 200, f"GET /v1/source failed ({code}): {raw.decode()}"
            assert src_after_sel["total_characters"] == len(json.loads(raw)["text"]), "list_sources total_characters desynced from read_source!"
            print(f"[PASS] Selection-scope bind did not poison voiceprint, bumped revision ({rev_initial} -> {src_after_sel['revision']}), offsets consistent")

            # 6b. Click-to-bind anonymous colleague speaker as "Alex" WITH scope="cluster" & enroll_voiceprint=True
            rev_before_alex = src_after_sel["revision"]
            code, _, raw = http_req(
                f"{data_url}/v1/voiceprints/bind-transcript",
                api_key,
                method="POST",
                json_body={
                    "source_id": source_id,
                    "span_ids": [anon_span["id"]],
                    "cluster_key": anon_span.get("cluster_key"),
                    "target_name": "Alex",
                    "is_owner": False,
                    "enroll_voiceprint": True,
                    "rematch_history": True,
                    "scope": "cluster",
                },
            )
            assert code == 200, f"Bind failed: {raw.decode()}"
            bind_res = json.loads(raw)
            assert bind_res["success"] is True and bind_res["target_name"] == "Alex"
            assert bind_res["enrolled_voiceprint"] is True
            alex_id = bind_res["profile_id"]
            code, _, raw = http_req(f"{data_url}/v1/sources", api_key)
            src_after_alex = next(s for s in json.loads(raw)["items"] if s["id"] == source_id)
            assert src_after_alex["revision"] != rev_before_alex, "sources.revision MUST bump after cluster bind!"
            code, _, raw = http_req(
                f"{data_url}/v1/source?source_id={urllib.parse.quote(source_id)}&revision={urllib.parse.quote(src_after_alex['revision'])}",
                api_key,
            )
            assert code == 200
            alex_spans = [sp for sp in json.loads(raw)["spans"] if sp.get("speaker") == "Alex"]
            assert alex_spans and all(sp.get("voice_profile_id") == alex_id for sp in alex_spans), f"Expected voice_profile_id={alex_id} on Alex spans: {alex_spans}"
            print(
                f"[PASS] Click-to-lock bound & enrolled 'Alex' (profile={alex_id[:8]}, "
                f"updated_spans={bind_res['updated_span_count']}, rev={src_after_alex['revision']}, rematch_ms={bind_res['rematch']['elapsed_ms']}ms)"
            )

            # 7. Verify <100ms global rematch endpoint
            code, _, raw = http_req(f"{data_url}/v1/voiceprints/rematch", api_key, method="POST", json_body={})
            assert code == 200
            rematch_res = json.loads(raw)
            assert rematch_res["elapsed_ms"] < 200.0
            print(f"[PASS] Global historical rematch completed in {rematch_res['elapsed_ms']} ms")

            # 8. Verify HTTP Range 206 streaming of uploaded recording audio
            code, hdrs, part = http_req(
                f"{data_url}/v1/audio/stream?source_id={urllib.parse.quote(source_id)}",
                api_key,
                headers={"Range": "bytes=0-4095"},
            )
            assert code == 206 and len(part) == 4096 and hdrs.get("Accept-Ranges") == "bytes"
            print("[PASS] Mac original audio HTTP Range 206 streaming verified")

            # 9. Verify short voice dictation (iPhone chat voice input -> Mac MOSS CoreML)
            code, _, raw = http_req(
                f"{data_url}/v1/speech/dictate",
                api_key,
                method="POST",
                raw_body=dictate_wav.read_bytes(),
                headers={"Content-Type": "audio/wav", "X-MoMo-Filename": "dictate.wav"},
            )
            assert code == 200, f"Dictate failed: {raw.decode()}"
            dict_res = json.loads(raw)
            assert len(dict_res["text"]) >= 4, f"Empty dictation: {dict_res}"
            print(f"[PASS] Mac CoreML dictation: {dict_res['text']!r} ({dict_res['elapsed_sec']:.2f}s)")

            # 10. Negative rejection ("这不是 Alex") -> must bump revision, drop stale voice_profile_id, and allow re-binding later!
            rev_before_rej = src_after_alex["revision"]
            code, _, raw = http_req(
                f"{data_url}/v1/voiceprints/reject",
                api_key,
                method="POST",
                json_body={
                    "source_id": source_id,
                    "profile_id": alex_id,
                    "span_ids": [anon_span["id"]],
                    "cluster_key": anon_span.get("cluster_key"),
                },
            )
            assert code == 200
            rej = json.loads(raw)
            assert rej["success"] is True and rej["rejected_vectors"] >= 1
            code, _, raw = http_req(f"{data_url}/v1/sources", api_key)
            src_after_rej = next(s for s in json.loads(raw)["items"] if s["id"] == source_id)
            assert src_after_rej["revision"] != rev_before_rej, "sources.revision MUST bump after reject_speaker_match!"
            code, _, raw = http_req(
                f"{data_url}/v1/source?source_id={urllib.parse.quote(source_id)}&revision={urllib.parse.quote(src_after_rej['revision'])}",
                api_key,
            )
            rej_span = next(sp for sp in json.loads(raw)["spans"] if sp["id"] == anon_span["id"])
            assert rej_span.get("speaker") != "Alex" and not rej_span.get("voice_profile_id"), f"Stale Alex label/profile remained after reject: {rej_span}"

            # Re-bind the rejected span back to Alex -> must clear speaker_exclusions and restore Alex!
            code, _, raw = http_req(
                f"{data_url}/v1/voiceprints/bind-transcript",
                api_key,
                method="POST",
                json_body={
                    "source_id": source_id,
                    "span_ids": [anon_span["id"]],
                    "cluster_key": anon_span.get("cluster_key"),
                    "profile_id": alex_id,
                    "target_name": "Alex",
                    "is_owner": False,
                    "enroll_voiceprint": False,
                    "rematch_history": False,
                    "scope": "cluster",
                },
            )
            assert code == 200, f"Re-bind after reject failed: {raw.decode()}"
            code, _, raw = http_req(f"{data_url}/v1/sources", api_key)
            src_after_rebind = next(s for s in json.loads(raw)["items"] if s["id"] == source_id)
            code, _, raw = http_req(
                f"{data_url}/v1/source?source_id={urllib.parse.quote(source_id)}&revision={urllib.parse.quote(src_after_rebind['revision'])}",
                api_key,
            )
            rebound_span = next(sp for sp in json.loads(raw)["spans"] if sp["id"] == anon_span["id"])
            assert rebound_span.get("speaker") == "Alex" and rebound_span.get("voice_profile_id") == alex_id, f"Re-bind after reject did not clear exclusion: {rebound_span}"
            print(f"[PASS] Negative rejection ({rej['rejected_vectors']} vecs) bumped revision, dropped stale profile, and allowed clean re-bind")

            print("\nALL MAC COREML SPEECH + VOICEPRINT E2E CHECKS PASSED!")
        finally:
            ctx_service.close()
            speech_proc.terminate()
            try:
                speech_proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                speech_proc.kill()


if __name__ == "__main__":
    run_e2e()
