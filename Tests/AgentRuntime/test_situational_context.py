"""Tests for device telemetry, HealthSnapshot v2, motion context, unified situational snapshot, and 1.5h Life Pulse."""
from __future__ import annotations

import copy
import datetime as dt
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
import urllib.error
import urllib.request
import uuid

from aiohttp.test_utils import TestClient, TestServer

ROOT = Path(__file__).resolve().parents[2]
for extra in (
    ROOT / "Apps/MacApp/Runtime",
    ROOT / "Apps/MacApp/Context",
    ROOT / "Apps/MacApp/Access",
    ROOT / "Vendor/HermesAgent",
):
    if str(extra) not in sys.path:
        sys.path.insert(0, str(extra))

import momo_agent
from context_server import ContextService
from context_store import Conflict, ContextStore
import daily_review
from device_telemetry import (
    clear_mac_telemetry_cache,
    parse_ioreg_idle,
    parse_pmset_batt,
    probe_mac_telemetry,
    read_device_telemetry,
    sync_device_telemetry,
)
from health_store import read_health, sync_health
import life_pulse
import memory_review
from phone_sources import read_phone_sources, sync_phone_source
from rtc_transport import permitted_route
from situational_context import read_situational_context
from superagent_gateway import SuperAgentGateway


SHANGHAI = dt.timezone(dt.timedelta(hours=8))
BASE_TS = dt.datetime(2026, 11, 16, 14, 0, 0, tzinfo=SHANGHAI).timestamp()


def make_telemetry_payload(
    device_id: str,
    *,
    revision: int = 1,
    state: str = "enabled",
    observed_at: float = BASE_TS,
    phone_batt: float | None = 0.64,
    phone_state: str = "unplugged",
    audio_name: str | None = "AirPods Pro",
    watch_batt: float | None = 0.82,
    watch_activity: str = "recording",
) -> dict:
    if state == "disabled":
        return {
            "device_id": device_id,
            "revision": revision,
            "state": "disabled",
            "observed_at": observed_at,
            "timezone": "Asia/Shanghai",
            "phone": None,
            "watch": None,
        }
    return {
        "device_id": device_id,
        "revision": revision,
        "state": state,
        "observed_at": observed_at,
        "timezone": "Asia/Shanghai",
        "phone": {
            "battery_level": phone_batt,
            "battery_state": phone_state,
            "low_power_mode": False,
            "thermal_state": 0,
            "free_storage_bytes": 64_000_000_000,
            "audio_route": (
                {"port_type": "BluetoothA2DPOutput", "port_name": audio_name}
                if audio_name
                else None
            ),
        },
        "watch": {
            "device_id": "AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEE",
            "sampled_at": observed_at - 10,
            "activity": watch_activity,
            "pending_chunk_count": 2,
            "pending_bytes": 48_000,
            "battery_level": watch_batt,
            "battery_state": "unplugged",
            "low_power_mode": False,
            "thermal_state": 0,
            "free_storage_bytes": 12_000_000_000,
        },
    }


class DeviceTelemetryTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.store = ContextStore(Path(self.temp.name))
        self.device_id = str(uuid.uuid4()).upper()
        self.payload = make_telemetry_payload(self.device_id)

    def tearDown(self) -> None:
        self.store.close()
        self.temp.cleanup()

    def test_sync_idempotency_conflict_and_disabled_wipe(self) -> None:
        receipt = sync_device_telemetry(self.store, self.payload)
        self.assertEqual(receipt["device_id"], self.device_id.lower())
        self.assertEqual(receipt, sync_device_telemetry(self.store, self.payload))

        mutated_same_rev = copy.deepcopy(self.payload)
        mutated_same_rev["phone"]["battery_level"] = 0.50
        with self.assertRaises(Conflict):
            sync_device_telemetry(self.store, mutated_same_rev)

        # Disabled state requires phone=None and watch=None
        bad_disabled = copy.deepcopy(self.payload)
        bad_disabled["revision"] = 2
        bad_disabled["state"] = "disabled"
        with self.assertRaises(ValueError):
            sync_device_telemetry(self.store, bad_disabled)

        valid_disabled = make_telemetry_payload(self.device_id, revision=2, state="disabled", observed_at=BASE_TS + 30)
        sync_device_telemetry(self.store, valid_disabled)

        # Stale revision 1 cannot overwrite revision 2 opt-out
        with self.assertRaises(Conflict):
            sync_device_telemetry(self.store, self.payload)

        snap = read_device_telemetry(self.store, now=BASE_TS + 40)["items"][0]
        self.assertEqual(snap["state"], "disabled")
        self.assertIsNone(snap["phone"])
        self.assertIsNone(snap["watch"])
        self.assertEqual(0, self.store.db.execute("SELECT COUNT(*) FROM jobs").fetchone()[0])

    def test_mac_probe_parsers_and_15s_memory_cache(self) -> None:
        laptop_batt = (
            "Now drawing from 'AC Power'\n"
            " -InternalBattery-0 (id=123)\t95%; charging; 0:25 remaining present: true\n"
        )
        self.assertEqual(
            parse_pmset_batt(laptop_batt),
            {
                "battery_level": 0.95,
                "power_source": "ac",
                "battery_state": "charging",
                "time_remaining_minutes": 25,
            },
        )
        ac_attached = (
            "Now drawing from 'AC Power'\n"
            " -InternalBattery-0 (id=123)\t80%; AC attached; not charging present: true\n"
        )
        self.assertEqual(parse_pmset_batt(ac_attached)["battery_state"], "ac_attached")
        desktop_ac = "Now drawing from 'AC Power'\n"
        self.assertEqual(parse_pmset_batt(desktop_ac)["battery_level"], None)
        self.assertEqual(parse_pmset_batt(desktop_ac)["power_source"], "ac")

        ioreg_out = '    |   "HIDIdleTime" = 42500000000\n'
        self.assertEqual(parse_ioreg_idle(ioreg_out), 42.5)

        clear_mac_telemetry_cache()
        with patch("device_telemetry.subprocess.run") as run_mock:
            run_mock.return_value.returncode = 0
            run_mock.return_value.stdout = laptop_batt + ioreg_out
            first = probe_mac_telemetry(now=BASE_TS)
            second = probe_mac_telemetry(now=BASE_TS + 5)
            self.assertEqual(run_mock.call_count, 2)  # pmset + ioreg once, then served from 15s cache
            self.assertEqual(first["battery_level"], 0.95)
            self.assertTrue(second["user_active_at_mac"])
            self.assertIsNotNone(second["free_storage_bytes"])
        clear_mac_telemetry_cache()


class SituationalSynthesisAndRoutesTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.data = Path(self.temp.name) / "Agent"
        self.data.mkdir(parents=True)
        (self.data / "api-key").write_text("fixture-secret", encoding="utf-8")
        self.store = ContextStore(self.data / "context")
        self.dev = str(uuid.uuid4())

    def tearDown(self) -> None:
        self.store.close()
        self.temp.cleanup()

    def _seed_full_situation(self, now_ts: float = BASE_TS) -> None:
        sync_device_telemetry(self.store, make_telemetry_payload(self.dev, observed_at=now_ts - 20))
        sync_phone_source(
            self.store,
            {
                "device_id": self.dev,
                "kind": "motion",
                "revision": 1,
                "state": "enabled",
                "observed_at": now_ts - 15,
                "window_start": now_ts - 3600,
                "window_end": now_ts - 5,
                "timezone": "Asia/Shanghai",
                "records": [
                    {
                        "id": "mot-1",
                        "title": "automotive",
                        "source_name": "iPhone Motion",
                        "start": now_ts - 600,
                    }
                ],
            },
        )
        sync_phone_source(
            self.store,
            {
                "device_id": self.dev,
                "kind": "visits",
                "revision": 1,
                "state": "enabled",
                "observed_at": now_ts - 60,
                "window_start": now_ts - 86400,
                "window_end": now_ts - 60,
                "timezone": "Asia/Shanghai",
                "records": [
                    {
                        "id": "vis-office",
                        "source_name": "CoreLocation",
                        "start": now_ts - 7200,
                        "latitude": 31.2304,
                        "longitude": 121.4737,
                        "accuracy": 35.0,
                    }
                ],
            },
        )
        sleep_start = dt.datetime(2026, 11, 16, 1, 15, tzinfo=SHANGHAI).timestamp()
        sleep_end = dt.datetime(2026, 11, 16, 8, 30, tzinfo=SHANGHAI).timestamp()
        sync_health(
            self.store,
            {
                "device_id": self.dev,
                "revision": 1,
                "state": "enabled",
                "observed_at": now_ts - 30,
                "window_start": now_ts - 7 * 86400,
                "window_end": now_ts - 30,
                "timezone": "Asia/Shanghai",
                "observations": [
                    {
                        "metric": "steps",
                        "unit": "count",
                        "value": 6420,
                        "start": sleep_end,
                        "end": now_ts - 60,
                        "source_name": "Apple Watch",
                        "source_bundle": "com.apple.health.watch",
                    },
                    {
                        "metric": "heart_rate",
                        "unit": "count/min",
                        "value": 74,
                        "start": now_ts - 120,
                        "end": now_ts - 115,
                        "source_name": "Apple Watch",
                        "source_bundle": "com.apple.health.watch",
                    },
                    {
                        "metric": "resting_heart_rate",
                        "unit": "count/min",
                        "value": 58,
                        "start": sleep_end,
                        "end": sleep_end + 60,
                        "source_name": "Apple Watch",
                        "source_bundle": "com.apple.health.watch",
                    },
                    {
                        "metric": "hrv_sdnn",
                        "unit": "ms",
                        "value": 61.5,
                        "start": sleep_end - 600,
                        "end": sleep_end - 540,
                        "source_name": "Apple Watch",
                        "source_bundle": "com.apple.health.watch",
                    },
                    {
                        "metric": "wrist_temperature",
                        "unit": "degC",
                        "value": -0.25,
                        "start": sleep_start,
                        "end": sleep_end,
                        "source_name": "Apple Watch",
                        "source_bundle": "com.apple.health.watch",
                    },
                ],
                "sleep_sessions": [
                    {
                        "id": "sleep-nov16",
                        "start": sleep_start,
                        "end": sleep_end,
                        "asleep_seconds": 6.8 * 3600,
                        "in_bed_seconds": 7.25 * 3600,
                        "deep_seconds": 1.4 * 3600,
                        "core_seconds": 3.8 * 3600,
                        "rem_seconds": 1.6 * 3600,
                        "awake_seconds": 0.45 * 3600,
                        "source_name": "Apple Watch",
                        "source_bundle": "com.apple.health.watch",
                    }
                ],
                "workouts": [
                    {
                        "id": "wk-morning",
                        "activity_type": "cycling",
                        "start": sleep_end + 1800,
                        "end": sleep_end + 3600,
                        "duration_seconds": 1800,
                        "active_energy_kcal": 215.0,
                        "distance_meters": 8200.0,
                        "source_name": "Apple Watch",
                        "source_bundle": "com.apple.health.watch",
                    }
                ],
                "activity_summaries": [
                    {
                        "date": "2026-11-16",
                        "active_energy_kcal": 410,
                        "active_energy_goal_kcal": 600,
                        "exercise_minutes": 34,
                        "exercise_goal_minutes": 30,
                        "stand_hours": 8,
                        "stand_goal_hours": 12,
                    }
                ],
            },
        )
        sync_phone_source(
            self.store,
            {
                "device_id": self.dev,
                "kind": "calendar",
                "revision": 1,
                "state": "enabled",
                "observed_at": now_ts - 30,
                "window_start": now_ts - 3600,
                "window_end": now_ts + 86400,
                "timezone": "Asia/Shanghai",
                "records": [
                    {
                        "id": "ev-review",
                        "title": "0.8.0 架构评审",
                        "source_name": "Work Calendar",
                        "start": now_ts + 3600,
                        "end": now_ts + 7200,
                        "all_day": False,
                    }
                ],
            },
        )
        sync_phone_source(
            self.store,
            {
                "device_id": self.dev,
                "kind": "reminders",
                "revision": 1,
                "state": "enabled",
                "observed_at": now_ts - 30,
                "window_start": now_ts - 3600,
                "window_end": now_ts - 30,
                "timezone": "Asia/Shanghai",
                "records": [
                    {
                        "id": "rem-deck",
                        "title": "发评审演示材料",
                        "source_name": "Reminders",
                        "start": now_ts + 1800,
                    }
                ],
            },
        )

    def test_situational_snapshot_concise_summary_rtc_routes_http_cli_and_dream(self) -> None:
        self._seed_full_situation(BASE_TS)
        mocked_mac = {
            "battery_level": 0.95,
            "power_source": "ac",
            "battery_state": "full",
            "time_remaining_minutes": 0,
            "hid_idle_seconds": 12.0,
            "user_active_at_mac": True,
            "free_storage_bytes": 120_000_000_000,
            "as_of": BASE_TS,
        }
        with patch("situational_context.probe_mac_telemetry", return_value=mocked_mac):
            snap = read_situational_context(self.store, data_dir=self.data, now=BASE_TS)

        self.assertEqual(snap["clock"]["date"], "2026-11-16")
        self.assertEqual(snap["clock"]["weekday_zh"], "周一")
        self.assertEqual(snap["devices"]["phone"]["battery_level"], 0.64)
        self.assertEqual(snap["devices"]["watch"]["activity"], "recording")
        self.assertEqual(snap["mobility_and_place"]["motion"]["activity"], "automotive")
        self.assertTrue(snap["mobility_and_place"]["visit"]["ongoing"])
        self.assertAlmostEqual(snap["body_and_sleep"]["latest_sleep"]["asleep_hours"], 6.8)
        self.assertEqual(snap["body_and_sleep"]["today_activity"]["steps"], 6420)
        self.assertEqual(snap["body_and_sleep"]["vitals"]["wrist_temperature"]["value"], -0.25)
        self.assertEqual(snap["schedule"]["upcoming_events"][0]["title"], "0.8.0 架构评审")
        self.assertEqual(snap["schedule"]["due_reminders"][0]["title"], "发评审演示材料")
        self.assertLess(len(snap["concise_summary"]), 240)
        self.assertIn("手表 82%(录音中)", snap["concise_summary"])
        self.assertIn("AirPods Pro", snap["concise_summary"])
        self.assertIn("乘车中", snap["concise_summary"])
        self.assertIn("01:15–08:30(6.8h)", snap["concise_summary"])
        self.assertIn("6420 步", snap["concise_summary"])

        # Age > 15m explicitly marked in concise_summary; motion > 30m dropped as stale
        with patch("situational_context.probe_mac_telemetry", return_value=mocked_mac):
            aged = read_situational_context(self.store, data_dir=self.data, now=BASE_TS + 1200)
            self.assertIn("20m前", aged["concise_summary"])
            stale_motion = read_situational_context(self.store, data_dir=self.data, now=BASE_TS + 2000)
            self.assertIsNone(stale_motion["mobility_and_place"]["motion"])

        # WebRTC route allowlist checks
        self.assertEqual(
            permitted_route("GET", "/context/v1/device-telemetry"),
            ("/v1/device-telemetry", True, False),
        )
        self.assertEqual(
            permitted_route("POST", "/context/v1/device-telemetry"),
            ("/v1/device-telemetry", True, False),
        )
        self.assertEqual(
            permitted_route("GET", "/context/v1/situation"),
            ("/v1/situation", True, False),
        )
        self.assertIsNone(permitted_route("POST", "/context/v1/situation"))
        self.assertIsNone(permitted_route("POST", "/v1/device-telemetry"))

        # Authenticated ContextService HTTP routes (against live wall-clock time)
        live_now = dt.datetime.now(tz=SHANGHAI).timestamp()
        sync_phone_source(
            self.store,
            {
                "device_id": self.dev,
                "kind": "calendar",
                "revision": 2,
                "state": "enabled",
                "observed_at": live_now - 5,
                "window_start": live_now - 3600,
                "window_end": live_now + 86400,
                "timezone": "Asia/Shanghai",
                "records": [
                    {
                        "id": "ev-review",
                        "title": "0.8.0 架构评审",
                        "source_name": "Work Calendar",
                        "start": live_now + 3600,
                        "end": live_now + 7200,
                        "all_day": False,
                    }
                ],
            },
        )
        service = ContextService(self.data, {"data_url": "http://127.0.0.1:0", "workspace_id": str(uuid.uuid4())})
        service.start()
        self.addCleanup(service.close)
        base_http = f"http://127.0.0.1:{service.server.server_port}"
        opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
        headers = {"Authorization": "Bearer fixture-secret"}
        with self.assertRaises(urllib.error.HTTPError) as unauth:
            opener.open(f"{base_http}/v1/situation")
        self.assertEqual(unauth.exception.code, 401)
        unauth.exception.close()
        tel_post = make_telemetry_payload(self.dev, revision=2, observed_at=live_now - 5)
        with opener.open(
            urllib.request.Request(f"{base_http}/v1/device-telemetry", data=json.dumps(tel_post).encode(), headers=headers)
        ) as resp:
            self.assertEqual(json.load(resp)["revision"], 2)
        with opener.open(urllib.request.Request(f"{base_http}/v1/device-telemetry", headers=headers)) as resp:
            self.assertEqual(json.load(resp)["items"][0]["revision"], 2)
        with opener.open(urllib.request.Request(f"{base_http}/v1/situation", headers=headers)) as resp:
            http_sit = json.load(resp)
            self.assertEqual(http_sit["schedule"]["upcoming_events"][0]["id"], "ev-review")

        # CLI commands: situation, health --category, phone-context --kind motion
        cli = str(ROOT / "Apps/MacApp/Runtime/momo_cli.py")
        env = {**os.environ, "PYTHONDONTWRITEBYTECODE": "1"}
        cli_sit = json.loads(
            subprocess.check_output([sys.executable, "-B", cli, "--data-dir", str(self.data), "situation"], text=True, env=env)
        )
        self.assertIn("concise_summary", cli_sit)
        cli_sleep = json.loads(
            subprocess.check_output(
                [sys.executable, "-B", cli, "--data-dir", str(self.data), "health", "--category", "sleep"],
                text=True,
                env=env,
            )
        )
        self.assertEqual(len(cli_sleep["items"][0]["sleep_sessions"]), 1)
        self.assertEqual(cli_sleep["items"][0]["observations"], [])
        cli_motion = json.loads(
            subprocess.check_output(
                [sys.executable, "-B", cli, "--data-dir", str(self.data), "phone-context", "--kind", "motion"],
                text=True,
                env=env,
            )
        )
        self.assertEqual(cli_motion["items"][0]["records"][0]["title"], "automotive")

        # Dream evidence page includes health_and_activity_summary (sleep & workouts, never battery %)
        (self.data / "hermes/memories").mkdir(parents=True, exist_ok=True)
        dream_now = max(BASE_TS, live_now)
        job, enqueued = memory_review.enqueue_manual_dream(self.store, self.data, now=dream_now)
        self.assertTrue(enqueued)
        self.store.db.execute("UPDATE memory_reviews SET state='running', first_attempt=? WHERE id=?", (dream_now, job["id"]))
        page_ev = daily_review.read_page(self.store, job["id"], 1)["evidence"]
        summary = page_ev["health_and_activity_summary"]
        self.assertEqual(summary["sleep_sessions"][0]["asleep_hours"], 6.8)
        self.assertEqual(summary["workouts"][0]["activity_type"], "cycling")
        self.assertIn("NEVER store ephemeral device battery", summary["guidance"])


class LifePulseAndGatewayBridgeTests(unittest.IsolatedAsyncioTestCase):
    async def test_uniform_5400s_cadence_semantic_dedup_night_suppression_and_gateway_pulse_context(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            data = Path(tmp) / "Agent"
            conn = momo_agent.initialize(data, 19860)
            store = ContextStore(data / "context")
            dev = str(uuid.uuid4())
            fixed_mac = {
                "battery_level": 0.92,
                "power_source": "ac",
                "battery_state": "full",
                "time_remaining_minutes": 0,
                "hid_idle_seconds": 20.0,
                "user_active_at_mac": True,
                "free_storage_bytes": 100_000_000_000,
                "as_of": BASE_TS,
            }
            emitted: list[dict] = []

            try:
                # 0. Empty store emits nothing
                self.assertIsNone(life_pulse.maybe_emit_pulse(store, emitted.append, data_dir=data, now=BASE_TS))
                self.assertEqual(len(emitted), 0)

                # 1. Initial baseline emission at BASE_TS (14:00 Asia/Shanghai)
                sync_device_telemetry(
                    store,
                    make_telemetry_payload(dev, revision=1, observed_at=BASE_TS, phone_batt=0.84, watch_batt=0.82),
                )
                with patch("situational_context.probe_mac_telemetry", return_value=fixed_mac):
                    first = life_pulse.maybe_emit_pulse(store, emitted.append, data_dir=data, now=BASE_TS)
                self.assertIsNotNone(first)
                self.assertEqual(len(emitted), 1)
                self.assertEqual(emitted[0]["kind"], "life_signals")
                self.assertEqual(emitted[0]["thread_id"], "momo:pulse:2026-11-16")
                self.assertIn("[当前全维态势]", emitted[0]["text"])
                self.assertIn("[较上次巡检的变化]", emitted[0]["text"])
                self.assertIn("[未来 12 小时日程与待办]", emitted[0]["text"])

                # 2. 1% battery jitter within same 10% bucket keeps exact same semantic fingerprint (pending_delta_since stays None)
                sync_device_telemetry(
                    store,
                    make_telemetry_payload(dev, revision=2, observed_at=BASE_TS + 300, phone_batt=0.81, watch_batt=0.82),
                )
                with patch("situational_context.probe_mac_telemetry", return_value=fixed_mac):
                    jitter = life_pulse.maybe_emit_pulse(store, emitted.append, data_dir=data, now=BASE_TS + 300)
                self.assertIsNone(jitter)
                saved_state = json.loads(
                    store.db.execute("SELECT value FROM memory_review_state WHERE key='life_pulse_state'").fetchone()[0]
                )
                self.assertIsNone(saved_state["pending_delta_since"])

                # 3. Both routine delta (+600s) and structural transition (new visit + motion at +1800s) are strictly held until 5400s!
                sync_device_telemetry(
                    store,
                    make_telemetry_payload(
                        dev,
                        revision=3,
                        observed_at=BASE_TS + 600,
                        phone_batt=0.55,
                        audio_name=None,
                    ),
                )
                sync_phone_source(
                    store,
                    {
                        "device_id": dev,
                        "kind": "visits",
                        "revision": 1,
                        "state": "enabled",
                        "observed_at": BASE_TS + 1800,
                        "window_start": BASE_TS - 3600,
                        "window_end": BASE_TS + 1800,
                        "timezone": "Asia/Shanghai",
                        "records": [
                            {
                                "id": "vis-1",
                                "source_name": "CoreLocation",
                                "start": BASE_TS + 1700,
                                "latitude": 31.2,
                                "longitude": 121.5,
                                "accuracy": 25.0,
                            }
                        ],
                    },
                )
                for check_ts in (BASE_TS + 600, BASE_TS + 1800, BASE_TS + 5399):
                    with patch("situational_context.probe_mac_telemetry", return_value=fixed_mac):
                        self.assertIsNone(
                            life_pulse.maybe_emit_pulse(store, emitted.append, data_dir=data, now=check_ts)
                        )
                self.assertEqual(len(emitted), 1)
                saved_mid = json.loads(
                    store.db.execute("SELECT value FROM memory_review_state WHERE key='life_pulse_state'").fetchone()[0]
                )
                self.assertEqual(saved_mid["pending_delta_since"], BASE_TS + 600)

                # 4. At BASE_TS + 5400 (1.5h), pulse fires and includes accumulated deltas since previous emitted pulse!
                sync_device_telemetry(
                    store,
                    make_telemetry_payload(
                        dev,
                        revision=4,
                        observed_at=BASE_TS + 5380,
                        phone_batt=0.55,
                        audio_name=None,
                    ),
                )
                with patch("situational_context.probe_mac_telemetry", return_value=fixed_mac):
                    second = life_pulse.maybe_emit_pulse(store, emitted.append, data_dir=data, now=BASE_TS + 5400)
                self.assertIsNotNone(second)
                self.assertEqual(len(emitted), 2)
                self.assertIn("新到达或停留地点更新", emitted[1]["text"])
                self.assertIn("手机音频输出路由切换", emitted[1]["text"])
                self.assertIn("手机电量/充电状态变化", emitted[1]["text"])

                # 5. Another +5400s (17:00 local) with steady state emits the 1.5h autonomous horizon heartbeat
                sync_device_telemetry(
                    store,
                    make_telemetry_payload(
                        dev,
                        revision=5,
                        observed_at=BASE_TS + 10780,
                        phone_batt=0.54,
                        audio_name=None,
                    ),
                )
                with patch("situational_context.probe_mac_telemetry", return_value=fixed_mac):
                    third = life_pulse.maybe_emit_pulse(store, emitted.append, data_dir=data, now=BASE_TS + 10800)
                self.assertIsNotNone(third)
                self.assertIn("例行 1.5 小时全维巡检", emitted[2]["text"])

                # 6. Quiet late-night sleep hours (02:30 local next day) suppress Life Pulse unless imminent event within 90m
                night_ts = dt.datetime(2026, 11, 17, 2, 30, 0, tzinfo=SHANGHAI).timestamp()
                sync_device_telemetry(
                    store,
                    make_telemetry_payload(
                        dev,
                        revision=6,
                        observed_at=night_ts - 30,
                        phone_batt=0.90,
                        phone_state="charging",
                        audio_name=None,
                        watch_activity="idle",
                    ),
                )
                with patch("situational_context.probe_mac_telemetry", return_value=fixed_mac):
                    suppressed = life_pulse.maybe_emit_pulse(store, emitted.append, data_dir=data, now=night_ts)
                self.assertIsNone(suppressed)

                # Adding an imminent 03:30 early flight event within 90m wakes the pulse
                sync_phone_source(
                    store,
                    {
                        "device_id": dev,
                        "kind": "calendar",
                        "revision": 1,
                        "state": "enabled",
                        "observed_at": night_ts - 10,
                        "window_start": night_ts - 3600,
                        "window_end": night_ts + 86400,
                        "timezone": "Asia/Shanghai",
                        "records": [
                            {
                                "id": "ev-early-flight",
                                "title": "早班航班出发",
                                "source_name": "Calendar",
                                "start": night_ts + 3600,
                                "end": night_ts + 7200,
                                "all_day": False,
                            }
                        ],
                    },
                )
                with patch("situational_context.probe_mac_telemetry", return_value=fixed_mac):
                    woken = life_pulse.maybe_emit_pulse(store, emitted.append, data_dir=data, now=night_ts)
                self.assertIsNotNone(woken)
                self.assertIn("早班航班出发", woken["payload"]["text"])
            finally:
                store.close()

            # 7. SuperAgentGateway /momo/v1/proactive/ingest & /momo/internal/superagent/context for momo:pulse:*
            gateway = SuperAgentGateway(
                data,
                conn,
                python_executable=Path(sys.executable),
                base_env={},
                manage_dsh=False,
            )
            async with TestClient(TestServer(gateway.create_app())) as client:
                auth = {"Authorization": f"Bearer {gateway.api_key}"}
                bridge_headers = {"X-MoMo-Bridge": gateway.bridge_secret}

                resp = await client.post("/momo/v1/proactive/ingest", headers=auth, json=emitted[0])
                self.assertEqual(resp.status, 200)
                polled = await (await client.get("/momo/internal/superagent/triggers?after=0", headers=bridge_headers)).json()
                self.assertEqual(len(polled["events"]), 1)
                ev = polled["events"][0]
                self.assertEqual(ev["stream"], "life_signals")
                self.assertEqual(ev["thread_id"], "pulse:2026-11-16")

                # Simulate an ended pulse ticket on momo:pulse:2026-11-16, then ingest second pulse -> rotates to :r2
                gateway._cached_tickets = [
                    {
                        "id": "t-pulse-1",
                        "title": "会前提醒",
                        "state": "ended",
                        "ended": {"outcome": "completed", "at": dt.datetime.now(dt.timezone.utc).isoformat()},
                        "threads": ["momo:pulse:2026-11-16"],
                        "strength": "inferred",
                    }
                ]
                resp2 = await client.post("/momo/v1/proactive/ingest", headers=auth, json=emitted[1])
                self.assertEqual(resp2.status, 200)
                polled2 = await (
                    await client.get(
                        f"/momo/internal/superagent/triggers?after={polled['next_cursor']}",
                        headers=bridge_headers,
                    )
                ).json()
                ev2 = polled2["events"][0]
                self.assertEqual(ev2["thread_id"], "pulse:2026-11-16:r2")

                ctx = await (
                    await client.get(
                        f"/momo/internal/superagent/context?thread_id={ev2['thread_id']}&message_id={ev2['id']}",
                        headers=bridge_headers,
                    )
                ).json()
                self.assertEqual(len(ctx["messages"]), 2)
                self.assertEqual(ctx["messages"][-1]["id"], ev2["id"])
                self.assertEqual(ctx["body"]["recent_tickets"][0]["id"], "t-pulse-1")

    def test_proactive_preferences_roundtrip_and_life_pulse_injection(self) -> None:
        from momo_memory import MoMoMemory

        with tempfile.TemporaryDirectory() as tmp:
            data = Path(tmp) / "Agent"
            store = ContextStore(data / "context")
            try:
                mem = MoMoMemory(data)
                written = mem.write_notebook(
                    category="proactive_preferences",
                    content="# 主动守护偏好\n\n- 日常电量高于 15% 时无需提醒充电。\n- 重要外部会议前 30 分钟优先准备对方背景速览。",
                )
                self.assertTrue(written["success"])
                self.assertEqual(written["path"], "PROACTIVE_PREFERENCES.md")
                read_back = mem.read_notebook(path="proactive-preferences.md")
                self.assertTrue(read_back["success"])
                self.assertIn("无需提醒充电", read_back["content"])

                dev = str(uuid.uuid4())
                sync_device_telemetry(store, make_telemetry_payload(dev, observed_at=BASE_TS))
                emitted = []
                res = life_pulse.maybe_emit_pulse(store, emitted.append, data_dir=data, now=BASE_TS)
                self.assertIsNotNone(res)
                self.assertIn("[用户主动守护偏好（PROACTIVE_PREFERENCES.md）]", emitted[0]["text"])
                self.assertIn("无需提醒充电", emitted[0]["text"])
            finally:
                store.close()


class SituationalMCPTests(unittest.IsolatedAsyncioTestCase):
    async def test_mcp_exposes_read_situational_context_only_outside_memory_only_mode(self) -> None:
        from mcp import ClientSession, StdioServerParameters
        from mcp.client.stdio import stdio_client

        with tempfile.TemporaryDirectory() as directory:
            store = ContextStore(directory)
            sync_device_telemetry(store, make_telemetry_payload(str(uuid.uuid4())))
            store.close()
            for memory_only in ("0", "1"):
                params = StdioServerParameters(
                    command=sys.executable,
                    args=["-B", str(ROOT / "Apps/MacApp/Context/context_mcp.py")],
                    env={
                        "PATH": os.defpath,
                        "MOMO_CONTEXT_DIRECTORY": directory,
                        "MOMO_MEMORY_ONLY": memory_only,
                        "PYTHONDONTWRITEBYTECODE": "1",
                    },
                )
                async with stdio_client(params) as (read, write):
                    async with ClientSession(read, write) as client:
                        await client.initialize()
                        tool_names = {t.name for t in (await client.list_tools()).tools}
                        self.assertEqual(memory_only == "0", "read_situational_context" in tool_names)
                        if memory_only == "0":
                            res = await client.call_tool("read_situational_context", arguments={})
                            self.assertFalse(res.is_error)
                            body = json.loads(res.content[0].text)
                            self.assertEqual(body["devices"]["telemetry_state"], "enabled")
                            self.assertEqual(body["devices"]["watch"]["activity"], "recording")


if __name__ == "__main__":
    unittest.main()
