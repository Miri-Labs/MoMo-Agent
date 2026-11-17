# Holistic Life Context, Organic Vault & Illustration Disambiguation (0.8.4)

## Motivation
Previously, memory curation (`Dream` + transcript ingestion), prompt injection (`momoMemoryPromptBlock`), and background scene extraction (`LifeIllustrations`) exhibited two structural gaps:
1. **Work-biased memory & rigid folder assumptions:** `USER.md` and `MEMORY.md` primarily accumulated work OKRs and project status while neglecting the user's real everyday life (household relationships, pet species/names/ASR homophones such as household cat `皮皮`/`屁屁`, city & home/office spaces, daily routines). Downstream consumers hardcoded `people/` and `places/` subfolder expectations, and `momoMemoryPromptBlock` sorted vault files alphabetically rather than by recency while capping `MEMORY.md` below its character ceiling.
2. **Missing cross-source Life Context recall during chat, proactive assessment, and illustration scene extraction:** Without dynamic cross-source recall (`USER.md` + `MEMORY.md` + organic Markdown notes + historical recordings/chat), background illustration scene extraction treated `"皮皮"` as an ambiguous generic `"宠物"` (causing image generation to render a dog instead of a cat) and mixed background short-video/esports audio into scene summaries.

## Changes
- **Unified Directory-Agnostic Life Context (`Apps/MacApp/Context/life_context.py`):**
  - Added `core_memory_snapshot`, `extract_recall_queries`, `contextual_memory_recall`, `ambient_situation_digest`, and `build_life_context_pack`.
  - Blends canonical `USER.md` + `MEMORY.md` with BM25+RRF `MemorySearch` across any natural `memories/` Markdown layout, past recordings (excluding the current episode window), and user chat statements (excluding assistant echoes), plus live situational awareness (preserving `visit.title`).
- **Dream `v10-holistic-life-context` & Personal Context (`memory_review.py`, `personal_context.py`, `transcript_ingestion.py`):**
  - Upgraded `CURATION_POLICY_VERSION` to `"v10-holistic-life-context"`.
  - Treats personal/household/pet/place understanding as a first-class citizen alongside work projects in `USER.md`, `MEMORY.md`, and naturally organized Markdown notebooks without rigid folder templates or verbose audit disclaimers.
  - Explicitly distinguishes real household interaction from background short-video/livestream media audio, and proactively backfills missing household/pet/location context via `search_memory` + `read_memory_evidence` + `phone_context(kind='visits')`.
- **End-to-End Consumer Integration (`sessions.ts`, `superagent_gateway.py`, `superagent_runtime.py`, `morning_briefing.py`, `life_pulse.py`, `situational_context.py`):**
  - `momoMemoryPromptBlock` (`Vendor/SuperAgent/src/app/sessions.ts`): includes full `USER.md` (2400 chars), `MEMORY.md` (4000 chars), `PROACTIVE_PREFERENCES.md`, `BRIEFING.md`, and the 80 most recently updated Markdown notes regardless of folder depth/naming.
  - `SuperAgentGateway` thread context endpoints (`/momo/v1/threads/...`), `morning_briefing.build_holistic_briefing_pack`, and `life_pulse.format_pulse_brief` now inject grounded Life Context & `visit.title`.
- **Organic Memory Disambiguation & Single-Slot Regeneration for Illustrations (`life_illustrations.py`, `life_illustration_generator.py`, `context_server.py`, `rtc_transport.py`, `momo_cli.py`):**
  - `CodexIllustrationGenerator.prepare()` enriches episode evidence with `life_context` (excluding the slot's own time window) and exposes read-only `search_memory` / `read_memory_evidence` tools during scene extraction (`SCENE_POLICY`), enforcing exact pet species/anatomy cues (e.g., unmistakable feline ears/whiskers/tail for household cat `皮皮`) and filtering background video noise.
  - Added `POST /v1/life-illustrations/regenerate` (`momo-cli life-illustrations --regenerate <slot_id>`) with immediate manual dispatch wakeup, plus `momo-cli dream [--run]`.

## Verification
- `Tests/AgentRuntime/test_life_context.py` + full `AgentRuntime` regression suite (`test_memory_review.py`, `test_personal_context.py`, `test_morning_briefing.py`, `test_situational_context.py`, `test_life_illustrations.py`, `test_momo_memory.py`, `test_superagent_runtime.py`)
- `Vendor/SuperAgent` build (`pnpm build`) and `vitest` (`tests/prompts.spec.ts`, `tests/momo-source.spec.ts`, `tests/momo-pim.spec.ts`)
- Offline Mac runtime verification (`Tests/Support/verify-mac-runtime.py`), `/Applications/MoMo Agent.app` `0.8.4 (126)` live upgrade, live Dream `v10` curation, and live regeneration of slot `175ba78c-a301-5ab8-80e1-bc2b4f976c8a`.
