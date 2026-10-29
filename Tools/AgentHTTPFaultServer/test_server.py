#!/usr/bin/env -S uv run
"""Real loopback TLS fixture checks, not App/Pi/model acceptance."""

import argparse
import base64
from datetime import datetime, timezone
from email.utils import parsedate_to_datetime
import http.client
import json
import os
from pathlib import Path
import ssl
import subprocess
import sys
import threading
import time
import unittest
import uuid

from run import cleanup_tls, prepare
from server import (DEFAULT_TIMING, FaultServer, PRIVACY_MARKERS, SCENARIOS, SYNTHETIC_KEY,
                    SUMMARY_MODEL, SUMMARY_TEXTS, SUMMARY_RESPONSES, SUMMARY_UNRELATED, configuration)


OUTPUT = None


class FaultServerTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tls = OUTPUT / "tls"
        prepare(cls.tls)
        cls.context = ssl.create_default_context(cafile=str(cls.tls / "ca.pem"))
        cls.context.verify_flags |= ssl.VERIFY_X509_STRICT
        config = configuration()
        config["timing"].update(delaySeconds=0.3, dripIntervalSeconds=0.04,
                                dripDurationSeconds=0.3, fragmentIntervalSeconds=0.00001)
        config["toolArguments"] = {"query": "中文合成验证"}
        cls.server = FaultServer(0, cls.tls / "server.pem", cls.tls / "server-key.pem", OUTPUT, config)
        cls.port = cls.server.server_address[1]
        cls.thread = threading.Thread(target=cls.server.serve_forever, daemon=True)
        cls.thread.start()

    @classmethod
    def tearDownClass(cls):
        cls.server.stopping.set()
        cls.server.shutdown()
        cls.server.server_close()
        cls.thread.join(timeout=2)
        cleanup_tls(cls.tls)

    def connection(self, context=None):
        return http.client.HTTPSConnection("127.0.0.1", self.port, context=context or self.context, timeout=3)

    def request(self, scenario, run_id=None, messages=None):
        run_id = run_id or str(uuid.uuid4())
        connection = self.connection()
        body = {"model": "j17-synthetic", "stream": True, "messages": messages or [{"role": "user", "content": "DO_NOT_LOG_BODY_SENTINEL"}]}
        connection.request("POST", f"/runs/{run_id}/{scenario}/v1/chat/completions", json.dumps(body),
                           {"Authorization": "Bearer " + SYNTHETIC_KEY, "Content-Type": "application/json", "X-Sensitive-Test": "DO_NOT_LOG_HEADER_SENTINEL"})
        return run_id, connection, connection.getresponse()

    def full_response(self, scenario, run_id=None, messages=None):
        run_id, connection, response = self.request(scenario, run_id, messages)
        try:
            return run_id, response.status, dict(response.getheaders()), response.read()
        finally:
            connection.close()

    def snapshot(self, run_id, scenario):
        connection = self.connection()
        try:
            connection.request("GET", f"/runs/{run_id}/{scenario}/counts")
            response = connection.getresponse()
            self.assertEqual(response.status, 200)
            return json.loads(response.read())
        finally:
            connection.close()

    def inspection(self, run_id, scenario):
        connection = self.connection()
        try:
            connection.request("GET", f"/runs/{run_id}/{scenario}/inspection")
            response = connection.getresponse()
            self.assertEqual(response.status, 200)
            return json.loads(response.read())
        finally:
            connection.close()

    def summary_request(self, scenario, text, run_id=None, extra=None):
        run_id = run_id or str(uuid.uuid4())
        body = {"model": SUMMARY_MODEL, "stream": True,
                "messages": [{"role": "system", "content": "Synthetic summary instructions."},
                             {"role": "user", "content": text}]}
        body.update(extra or {})
        connection = self.connection()
        try:
            connection.request("POST", f"/runs/{run_id}/{scenario}/v1/chat/completions", json.dumps(body),
                               {"Authorization": "Bearer " + SYNTHETIC_KEY, "Content-Type": "application/json"})
            response = connection.getresponse()
            return run_id, response.status, response.read()
        finally:
            connection.close()

    def test_summary_success_inspects_exact_text_and_selected_model_without_retaining_body(self):
        run_id = str(uuid.uuid4())
        for revision in ("v1", "v2"):
            _, status, body = self.summary_request("summary-success", SUMMARY_TEXTS[revision], run_id)
            self.assertEqual(status, 200)
            self.assertIn(SUMMARY_RESPONSES[revision].encode(), body)
        report = self.inspection(run_id, "summary-success")
        self.assertEqual([item["fixtureRevision"] for item in report["requests"]], ["v1", "v2"])
        for item in report["requests"]:
            for flag in ("authorityMatches", "contentTypeMatches", "authorizationMatches", "modelMatches",
                         "stream", "systemThenSingleUser", "textOnlyMessages"):
                self.assertTrue(item[flag], flag)
            self.assertFalse(item["hasTools"])
            self.assertFalse(item["containsUnrelatedText"])
            self.assertFalse(item["containsCredential"])
        for forbidden in (*SUMMARY_TEXTS.values(), SYNTHETIC_KEY):
            self.assertNotIn(forbidden, json.dumps(report))

    def test_summary_inspection_detects_bad_scope_model_and_audio(self):
        leaked = SUMMARY_UNRELATED + SYNTHETIC_KEY
        extra = {"model": "wrong-model", "tools": [{"type": "function"}],
                 "messages": [{"role": "user", "content": leaked, "audio": {"id": "synthetic"}}]}
        run_id, _, _ = self.summary_request("summary-success", SUMMARY_TEXTS["v1"], extra=extra)
        report = self.inspection(run_id, "summary-success")
        item = report["requests"][0]
        self.assertFalse(item["modelMatches"])
        self.assertFalse(item["systemThenSingleUser"])
        self.assertFalse(item["textOnlyMessages"])
        self.assertTrue(item["hasTools"])
        self.assertTrue(item["containsUnrelatedText"])
        self.assertTrue(item["containsCredential"])
        self.assertEqual(item["fixtureRevision"], "unexpected")
        self.assertNotIn(leaked, json.dumps(report))

    def test_summary_service_failure_is_persistent_and_inspectable(self):
        run_id = str(uuid.uuid4())
        for _ in range(2):
            _, status, _ = self.summary_request("summary-503", SUMMARY_TEXTS["v1"], run_id)
            self.assertEqual(status, 503)
        self.assertEqual(self.snapshot(run_id, "summary-503")["requests"], 2)
        self.assertEqual(len(self.inspection(run_id, "summary-503")["requests"]), 2)

    def test_actual_encoded_request_inspection_returns_only_safe_findings(self):
        source_id = str(uuid.uuid4())
        context = {"passages": [{"text": PRIVACY_MARKERS["currentV1"],
                   "source": {"sessionID": source_id, "transcriptVersion": 1}}]}
        messages = [{"role": "system", "content": "<momoagent_rules>\nSynthetic\n</momoagent_rules>\n"
                     + "<recent_life_context>\n" + json.dumps(context) + "\n</recent_life_context>"},
                    {"role": "user", "content": [{"type": "text", "text": "synthetic task"}]}]
        run_id, _, _, _ = self.full_response("privacy-success", messages=messages)
        report = self.inspection(run_id, "privacy-success")
        finding = report["requests"][0]
        self.assertEqual(finding["path"], f"/runs/{run_id}/privacy-success/v1/chat/completions")
        for name in ("authorityMatches", "contentTypeMatches", "authorizationMatches", "modelMatches",
                     "stream", "textOnlyMessages", "hasProductionRules", "hasContextEnvelope", "contextValid"):
            self.assertTrue(finding[name], name)
        self.assertEqual(finding["passageSources"], [{"sessionID": source_id, "transcriptVersion": 1}])
        for field in ("bodyMarkers", "messageMarkers", "systemMarkers"):
            self.assertEqual(finding[field], {name: name == "currentV1" for name in PRIVACY_MARKERS})
        for marker in PRIVACY_MARKERS.values():
            self.assertNotIn(marker, json.dumps(report))

    def test_inspection_detects_plain_and_encoded_leaks_without_retaining_them(self):
        for offset in range(3):
            with self.subTest(base64_alignment=offset):
                audio = base64.b64encode(b"x" * offset + PRIVACY_MARKERS["audio"].encode() + b"tail").decode()
                messages = [{"role": "user", "content": [
                    {"type": "text", "text": PRIVACY_MARKERS["unrelated"] + SYNTHETIC_KEY},
                    {"type": "input_audio", "input_audio": {"data": audio, "format": "wav"}}]}]
                run_id, _, _, _ = self.full_response("privacy-success", messages=messages)
                report = self.inspection(run_id, "privacy-success")
                finding = report["requests"][0]
                self.assertFalse(finding["textOnlyMessages"])
                self.assertTrue(finding["bodyMarkers"]["credential"])
                self.assertTrue(finding["messageMarkers"]["unrelated"])
                self.assertTrue(finding["base64Markers"]["audio"])
                for value in (*PRIVACY_MARKERS.values(), audio):
                    self.assertNotIn(value, json.dumps(report))

    def test_verified_tls_and_ephemeral_key_permissions(self):
        self.assertEqual(os.stat(self.tls / "server-key.pem").st_mode & 0o777, 0o600)
        self.assertFalse((self.tls / "ca-key.pem").exists())
        _, status, _, body = self.full_response("success")
        self.assertEqual(status, 200)
        self.assertTrue(body.endswith(b"data: [DONE]\n\n"))
        connection = self.connection(ssl.create_default_context())
        try:
            with self.assertRaises(ssl.SSLCertVerificationError):
                connection.connect()
        finally:
            connection.close()

    def test_auth_failures_ignore_retry_hint_only_at_product_layer(self):
        for scenario, expected in (("auth-401", 401), ("auth-403", 403)):
            with self.subTest(scenario=scenario):
                run_id, status, headers, _ = self.full_response(scenario)
                self.assertEqual(status, expected)
                self.assertEqual(headers["x-should-retry"], "true")
                self.assertEqual(self.full_response(scenario, run_id)[1], expected)
                self.assertEqual(self.snapshot(run_id, scenario)["requests"], 2)

    def test_connection_teardown_does_not_append_another_http_body(self):
        for scenario in ("success", "auth-401"):
            with self.subTest(scenario=scenario):
                connection = self.connection()
                connection.connect()
                try:
                    body = b'{"stream":true,"messages":[]}'
                    request = (f"POST /runs/{uuid.uuid4()}/{scenario}/v1/chat/completions HTTP/1.1\r\n"
                               f"Host: 127.0.0.1:{self.port}\r\nAuthorization: Bearer {SYNTHETIC_KEY}\r\n"
                               f"Content-Length: {len(body)}\r\nContent-Type: application/json\r\n\r\n").encode() + body
                    connection.sock.sendall(request)
                    chunks = []
                    while data := connection.sock.recv(65536):
                        chunks.append(data)
                    head, payload = b"".join(chunks).split(b"\r\n\r\n", 1)
                    headers = dict(line.split(b": ", 1) for line in head.split(b"\r\n")[1:])
                    if scenario == "success":
                        self.assertEqual(payload.count(b"data: [DONE]"), 1)
                        self.assertEqual(payload.find(b"0\r\n\r\n") + 5, len(payload))
                    else:
                        self.assertEqual(len(payload), int(headers[b"Content-Length"]))
                finally:
                    connection.close()

    def test_retry_header_formats_and_first_failure_then_success(self):
        for scenario in ("retry-429-seconds", "retry-429-date", "retry-429-ms", "retry-429-over-budget"):
            with self.subTest(scenario=scenario):
                run_id, status, headers, _ = self.full_response(scenario)
                self.assertEqual(status, 429)
                if scenario.endswith("date"):
                    retry_at = parsedate_to_datetime(headers["Retry-After"])
                    self.assertLessEqual(abs((retry_at - datetime.now(timezone.utc)).total_seconds()), 2)
                elif scenario.endswith("ms"):
                    self.assertEqual(headers["retry-after-ms"], "1000")
                else:
                    self.assertEqual(headers["Retry-After"], "86400" if scenario.endswith("over-budget") else "1")
                self.assertEqual(self.full_response(scenario, run_id)[1], 200)

    def test_retryable_and_persistent_server_statuses(self):
        for scenario in ("retry-500", "retry-503", "always-500", "always-503"):
            with self.subTest(scenario=scenario):
                run_id, status, _, _ = self.full_response(scenario)
                self.assertEqual(status, int(scenario[-3:]))
                second = self.full_response(scenario, run_id)[1]
                self.assertEqual(second, int(scenario[-3:]) if scenario.startswith("always") else 200)

    def test_headers_and_body_delays_are_different_phases(self):
        for scenario in ("headers-delay", "body-delay"):
            with self.subTest(scenario=scenario):
                started = time.monotonic()
                run_id, connection, response = self.request(scenario)
                headers_elapsed = time.monotonic() - started
                try:
                    if scenario == "body-delay":
                        waiting = self.snapshot(run_id, scenario)
                        self.assertEqual(waiting["statuses"], [200])
                        self.assertEqual(waiting["responseBodyBytes"], 0)
                        self.assertIn("body_wait_started", [event["event"] for event in waiting["events"]])
                    response.read(1)
                    body_elapsed = time.monotonic() - started
                    response.read()
                finally:
                    connection.close()
                self.assertGreaterEqual(body_elapsed, 0.27)
                if scenario == "headers-delay":
                    self.assertGreaterEqual(headers_elapsed, 0.27)
                else:
                    self.assertLess(headers_elapsed, 0.25)
                finished = self.snapshot(run_id, scenario)
                events = finished["events"]
                self.assertEqual(sum(event["event"] == "stream_complete" for event in events), 1)
                headers = next(event for event in events if event["event"] == "headers_sent")
                first_byte = next(event for event in events if event["event"] == "body_sent")
                if scenario == "body-delay":
                    self.assertGreaterEqual(first_byte["monotonicSeconds"] - headers["monotonicSeconds"], 0.27)

    def test_stall_and_drip_have_distinct_body_timelines(self):
        for scenario in ("stream-stall", "continuous-drip"):
            with self.subTest(scenario=scenario):
                run_id, _, _, _ = self.full_response(scenario)
                events = self.snapshot(run_id, scenario)["events"]
                times = [e["monotonicSeconds"] for e in events if e["event"] == "body_sent"]
                gaps = [b - a for a, b in zip(times, times[1:])]
                if scenario == "stream-stall":
                    self.assertGreaterEqual(max(gaps), 0.27)
                else:
                    self.assertGreaterEqual(len(times), 8)
                    self.assertLess(max(gaps), 0.20)

    def test_midstream_disconnect_has_incomplete_http_body(self):
        run_id, connection, response = self.request("disconnect-midstream")
        try:
            with self.assertRaises(http.client.IncompleteRead):
                response.read()
        finally:
            connection.close()
        self.assertIn("forced_disconnect", [e["event"] for e in self.snapshot(run_id, "disconnect-midstream")["events"]])

    def test_controlled_long_stream_disconnect_is_authenticated_and_run_scoped(self):
        run_id, connection, response = self.request("controlled-long-stream")
        control = self.connection()
        try:
            self.assertEqual(response.status, 200)
            self.assertTrue(response.read(1))
            control.request("POST", f"/runs/{run_id}/controlled-long-stream/disconnect")
            denied = control.getresponse()
            self.assertEqual(denied.status, 401)
            denied.read()
            self.assertFalse(self.server.case(run_id, "controlled-long-stream").disconnect.is_set())
            control.close()
            control = self.connection()
            control.request("POST", f"/runs/{run_id}/controlled-long-stream/disconnect", headers={
                "Authorization": "Bearer " + SYNTHETIC_KEY})
            accepted = control.getresponse()
            self.assertEqual(accepted.status, 204)
            accepted.read()
            with self.assertRaises(http.client.IncompleteRead):
                response.read()
            report = self.snapshot(run_id, "controlled-long-stream")
            names = [event["event"] for event in report["events"]]
            self.assertIn("controlled_stream_started", names)
            self.assertIn("forced_disconnect", names)
            self.assertNotIn("stream_complete", names)
            self.assertFalse(self.server.case(str(uuid.uuid4()), "controlled-long-stream").disconnect.is_set())
        finally:
            connection.close()
            control.close()

    def test_controlled_long_stream_expires_without_claiming_completion(self):
        run_id, connection, response = self.request("controlled-long-stream")
        try:
            with self.assertRaises(http.client.IncompleteRead):
                response.read()
        finally:
            connection.close()
        names = [event["event"] for event in self.snapshot(run_id, "controlled-long-stream")["events"]]
        self.assertIn("controlled_stream_expired", names)
        self.assertNotIn("stream_complete", names)

    def test_fragmented_chinese_and_tool_json(self):
        for scenario in ("fragmented-text", "fragmented-tool-json"):
            with self.subTest(scenario=scenario):
                run_id, _, _, raw = self.full_response(scenario)
                chunks = [json.loads(line[6:]) for line in raw.decode().splitlines() if line.startswith("data: {")]
                deltas = [chunk["choices"][0]["delta"] for chunk in chunks]
                if scenario == "fragmented-text":
                    self.assertIn("合成响应", "".join(delta.get("content", "") for delta in deltas))
                else:
                    arguments = "".join(call.get("function", {}).get("arguments", "") for delta in deltas for call in delta.get("tool_calls", []))
                    self.assertEqual(json.loads(arguments), self.server.config["toolArguments"])
                self.assertGreater(len(self.snapshot(run_id, scenario)["events"]), 100)

    def test_successful_tool_round_trip_script(self):
        run_id, _, _, raw = self.full_response("success-tools")
        self.assertIn(b'"name":"search_transcripts"', raw)
        self.assertIn(b'"finish_reason":"tool_calls"', raw)
        _, _, _, reply = self.full_response("success-tools", run_id, [{"role": "tool", "tool_call_id": "call_j17_search", "content": "SYNTHETIC_RESULT"}])
        self.assertNotIn(b'"name":"search_transcripts"', reply)
        self.assertIn(b'"finish_reason":"stop"', reply)

    def test_cancel_then_explicitly_release_late_tool(self):
        run_id, connection, response = self.request("late-tool-after-cancel")
        response.read(1)
        deadline = time.monotonic() + 0.2
        while not any(e["event"] == "awaiting_release" for e in self.snapshot(run_id, "late-tool-after-cancel")["events"]):
            self.assertLess(time.monotonic(), deadline)
            time.sleep(0.005)
        # Connection: close transfers socket ownership to HTTPResponse after headers.
        response.close()
        connection.close()
        control = self.connection()
        try:
            control.request("POST", f"/runs/{run_id}/late-tool-after-cancel/release", headers={"Authorization": "Bearer " + SYNTHETIC_KEY})
            self.assertEqual(control.getresponse().status, 204)
        finally:
            control.close()
        deadline = time.monotonic() + 0.2
        while not any(e["event"] == "late_tool_attempted" for e in self.snapshot(run_id, "late-tool-after-cancel")["events"]):
            self.assertLess(time.monotonic(), deadline)
            time.sleep(0.005)

    def test_run_path_isolation_and_synthetic_authorization(self):
        first, _, _, _ = self.full_response("retry-500")
        second, _, _, _ = self.full_response("retry-500")
        self.assertNotEqual(first, second)
        self.assertEqual(self.snapshot(first, "retry-500")["statuses"], [500])
        self.assertEqual(self.snapshot(second, "retry-500")["statuses"], [500])
        connection = self.connection()
        try:
            connection.request("POST", f"/runs/{first}/success/v1/chat/completions", "{}", {"Authorization": "Bearer DO_NOT_LOG_WRONG_KEY"})
            self.assertEqual(connection.getresponse().status, 401)
        finally:
            connection.close()

    def test_logs_and_counts_only_contain_whitelisted_fields(self):
        run_id, _, _, _ = self.full_response("success")
        snapshot = self.snapshot(run_id, "success")
        self.assertEqual(set(snapshot), {"runID", "scenario", "requests", "snapshotMonotonicSeconds", "responseBodyBytes", "statuses", "events"})
        raw = (OUTPUT / "events.jsonl").read_text()
        for sensitive in (SYNTHETIC_KEY, "DO_NOT_LOG", "SYNTHETIC_RESULT", "search_transcripts", "合成正文"):
            self.assertNotIn(sensitive, raw)
        for line in raw.splitlines():
            self.assertEqual(set(json.loads(line)), {"runID", "scenario", "request", "event", "monotonicSeconds", "status", "byteCount"})

    def test_config_rejects_unknown_fields_and_unbounded_timing(self):
        path = OUTPUT / "invalid-config.json"
        for data in ({"apiKey": "synthetic"}, {"timing": {"delaySeconds": 10000}}, {"timing": {"retryAfterSeconds": 0.5}}):
            path.write_text(json.dumps(data))
            with self.assertRaises(ValueError):
                configuration(path)
        path.unlink()

    def test_cli_ready_and_sigterm_cleanup(self):
        directory = OUTPUT / "cli-service"
        process = subprocess.Popen([sys.executable, str(Path(__file__).with_name("run.py")), "serve",
            "--tls", str(self.tls), "--output", str(directory)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        try:
            deadline = time.monotonic() + 5
            while not (directory / "ready.json").exists():
                self.assertIsNone(process.poll())
                self.assertLess(time.monotonic(), deadline)
                time.sleep(0.01)
            ready = json.loads((directory / "ready.json").read_text())
            self.assertEqual(ready["host"], "127.0.0.1")
            self.assertEqual(ready["pid"], process.pid)
            connection = http.client.HTTPSConnection("127.0.0.1", ready["port"], context=self.context, timeout=3)
            try:
                connection.request("GET", f"/runs/{uuid.uuid4()}/success/counts")
                response = connection.getresponse()
                self.assertEqual(response.status, 200)
                self.assertEqual(json.loads(response.read())["requests"], 0)
            finally:
                connection.close()
            process.terminate()
            self.assertEqual(process.wait(timeout=3), 0)
            self.assertTrue(json.loads((directory / "stopped.json").read_text())["stopped"])
        finally:
            if process.poll() is None:
                process.kill()
                process.wait(timeout=3)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    args, remaining = parser.parse_known_args()
    OUTPUT = args.output
    OUTPUT.mkdir(parents=True, mode=0o700, exist_ok=False)
    unittest.main(argv=[__file__, *remaining])
