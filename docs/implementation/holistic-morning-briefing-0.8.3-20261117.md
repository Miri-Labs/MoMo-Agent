# Holistic 4-Dimensional Morning Briefing (`0.8.3` / Build `125`)

**Date:** 2026-11-17

## Root Cause Analysis

1. **Pre-Dawn Briefing Freeze (`01:31 AM` vs `08:00 AM`):** Nightly Dream wrote `# 晨间简报 · YYYY-MM-DD` at ~01:30 AM before the user finished sleeping, and `_deliver_morning_briefing` at `08:00 AM` echoed that file verbatim without checking overnight sleep, morning HRV, or newly synced recordings.
2. **Multi-Batch Continuation Amnesia (`daily_review.py`):** Across multi-batch Dream runs (e.g., 103 pages / 26 batches), health context was attached only to Page 1 while the final batch synthesized `BRIEFING.md` in a fresh stateless session.
3. **Health Tool Gate & Chat-Only Fallback (`superagent_gateway.py` & `memory_review.py`):** `phone_context`'s schema discouraged reading `health` unless explicitly asked, and `morning_briefing_evidence` previously read only `conversation.sqlite` user messages + 5 notes (zero recordings, zero HealthKit, zero calendar/reminders).
4. **Meta-Chat Dominance:** Troubleshooting MoMo itself in chat overshadowed real-world meetings and business discussions captured in daytime Watch recordings.

## Solution (`0.8.3`)

- **New `Apps/MacApp/Context/morning_briefing.py`:**
  - Synthesizes a **4-dimensional morning evidence pack** (`recent_recordings_36h` with speaker attribution + `recent_journals`, `physiology_and_recovery` with sleep stage breakdown and 7-day HRV/RHR baselines, `situation_and_schedule` across calendar/reminders/telemetry, and `project_and_core_notes` + deprioritized meta-chat).
  - Automatically regenerates `BRIEFING.md` at morning delivery time (`>= day_start_hour`) whenever `BRIEFING.md` is missing, dated earlier, or was written pre-dawn before morning context arrived.
- **Dream Day/Night Separation & Multi-Batch Context (`daily_review.py`, `memory_review.py`):**
  - Pre-dawn Dream runs focus on consolidating `journal`, `projects/`, `people/`, and `MEMORY.md` without prematurely freezing today's `BRIEFING.md` before sleep completes; multi-batch final sessions receive `final_synthesis_context` (`health_rhythm` + `recent_recordings_30h`).
- **On-Demand Live Regeneration (`POST /momo/v1/briefing/regenerate` & `momo-cli briefing --regenerate`):**
  - Regenerates today's holistic `BRIEFING.md` (with actionable cards) and delivers the updated morning briefing to the chat timeline.
