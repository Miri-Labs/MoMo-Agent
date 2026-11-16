# Jarvis Situational Awareness, HealthKit v2 & LLM-Driven Life Pulse (`0.8.0` / Build `122`)

**Date:** 2026-11-16

## Summary

MoMo Agent `0.8.0` upgrades MoMo from a reactive chat/transcript assistant into a holistic personal steward with tri-device telemetry, `CoreMotion` mobility awareness, full-spectrum `HealthKit v2` context, and an autonomous, **100% LLM-driven** `Life Pulse` (`kind="life_signals"`) pipeline.

### Architectural Principles

1. **Zero Rule-Driven Threshold Triggers:** The context layer never hardcodes business thresholds (e.g., no `if battery < 12%` alert rules). It only gathers factual world state, deduplicates semantic fingerprints, and delivers a **Unified Situation & Delta Brief** on a calm **1.5-hour (`5400s`)** cadence into SuperAgent's native `POST /momo/v1/proactive/ingest` (`kind="life_signals"`).
2. **Autonomous Orchestrator + Worker Execution:** SuperAgent's Orchestrator evaluates the holistic brief alongside recent conversations, notebooks, schedule, reminders, sleep/recovery, and mobility; when warranted, it dispatches a Worker that can proactively plan, invoke tools (`Reminders`, `Calendar`, `Notes`, `Web`, `Workspace`), and/or notify the user.
3. **Battery-Neutral Piggyback Transport:** Apple Watch piggybacks battery/charging/low-power/thermal/storage fields onto existing `WatchCaptureStatus` frames (`StatusSnapshot.swift`) with zero extra radio wakes; iPhone piggybacks opportunistic background sync (`deviceTelemetry`, `health`, `sources`) onto incoming Watch chunk `PhoneContextDelivery` wakes.

---

## Key Components

### 1. Tri-Device Telemetry & Mobility (`device_telemetry.py`, `DeviceTelemetry.swift`, `PhoneSourcesReader.swift`)
- **Watch (`WatchRuntime.swift` + `StatusSnapshot.swift`):** Backward-compatible optional `batteryLevel`, `batteryState`, `lowPowerMode`, `thermalState`, and `freeStorageBytes` on `WatchCaptureStatus`, displayed in `WatchStatusPopover`.
- **iPhone (`PhoneDeviceTelemetrySync`):** Default-enabled zero-permission telemetry (`batteryLevel`, `batteryState`, `lowPowerMode`, `thermalState`, `freeStorageBytes`, and `AVAudioSession` output `audioRoute` such as AirPods / CarAudio / Speaker) plus paired Watch telemetry synced to `POST /v1/device-telemetry`.
- **Mac (`probe_mac_telemetry`):** 15s-cached local `pmset -g batt` + `ioreg -c IOHIDSystem` (`HIDIdleTime` active presence) + free disk probe.
- **Mobility (`PhoneSourceKind.motion`):** Opt-in `CMMotionActivityManager` 24h merged activity segments (`stationary`, `walking`, `running`, `cycling`, `automotive`, `unknown`) synced to `POST /v1/phone-sources`.

### 2. Full-Spectrum Apple Health (`HealthSnapshot v2`)
- Expanded `HealthContext.swift`, `PhoneHealthReader.swift`, and `health_store.py` across a 7-day rolling window:
  - **Sleep (`sleep_sessions`):** Merged sleep episodes with `asleep_seconds`, `in_bed_seconds`, `deep_seconds`, `core_seconds`, `rem_seconds`, `awake_seconds`.
  - **Workouts (`workouts`):** `HKWorkout` sessions (including `climbing`, `running`, `strength_training`, etc.) with duration, active kcal, and distance.
  - **Activity Rings (`activity_summaries`):** 7-day `Move` / `Exercise` / `Stand` progress and goals.
  - **13 Quantity Metrics (`observations`):** Daily deduplicated `steps`, `active_energy`, `distance_walking_running`, `flights_climbed`, plus `heart_rate`, `resting_heart_rate`, `hrv_sdnn`, `oxygen_saturation`, `respiratory_rate`, `wrist_temperature`, `vo2_max`, `environmental_audio_exposure`, and `headphone_audio_exposure`.
- Added 1-tap incremental authorization (`补充授权睡眠、运动与体征数据`) in `PhoneHealthSettingsView.swift`.

### 3. Unified Situational Synthesis & 1.5h `Life Pulse`
- **`situational_context.py` (`GET /v1/situation`, MCP `read_situational_context`, `momo-cli situation`):** Synthesizes `clock`, `devices`, `mobility_and_place`, `body_and_sleep`, `schedule`, and `concise_summary` with explicit freshness markers.
- **`life_pulse.py`:** Computes quantized semantic state vectors (`life_pulse_state`), enforces a uniform **`5400s` (1.5h)** cadence across deltas and heartbeats, suppresses late-night sleep hours (`00:00–06:30` local unless waking up or an event is within 90m), and posts structured situation + delta briefs to `/momo/v1/proactive/ingest` (`kind="life_signals"`).
- **`superagent_runtime.py` & `superagent_gateway.py`:** Added open-ended `situational_stewardship` proactive admission rule and `momo:pulse:*` thread context resolution.

---

## Verification

- Python runtime & gateway suites: `test_situational_context.py`, `test_health.py`, `test_phone_sources.py`, `test_context.py`, `test_dream_evidence.py`, `test_memory_review.py`, `test_superagent_runtime.py`, `test_life_illustrations.py`.
- Swift package suites: `StatusSnapshotTests` (`MoMoAgentKit`) and `MoMoAgentClientTests` (`SituationalContextContractTests`).
- Release bundle & signature gates: `scripts/bundle-mac-runtime.py`, `Tests/Support/verify-mac-runtime.py`, `Tests/Support/verify-release-bundle.py --variant local-upgrade`, and live installation across Mac (`/Applications/MoMo Agent.app`), iPhone (`00008150-000A31AA1447801C`), and Apple Watch (`00008301-1895081201B8202E`).
