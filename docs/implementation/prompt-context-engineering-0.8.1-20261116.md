# Steward Prompt & Context Engineering Upgrade (`0.8.1` / Build `123`)

**Date:** 2026-11-16

## Summary

MoMo Agent `0.8.1` refactors MoMo's runtime, proactive stewardship, and Dream consolidation prompts by synthesizing best practices from **Meta `muse-agent`**, **xAI `grok-bot`**, and **Anthropic's Prompt & Context Engineering guidelines**.

### Core Upgrades

1. **Sole Principal, Discretion & Narration Hygiene (`superagent_runtime.py`):**
   - Establishes explicit principal loyalty (*Knowing much, showing little*): broad internal read access serves judgment, while external queries, forms, and messages carry only task-minimal details.
   - Eliminates internal engineering jargon in user-facing replies (`MEMORY.md`, `PROACTIVE_PREFERENCES.md`, `notebook`, `ticket`, `worktree`, `orchestrator`, `eval`, `life_signals`, `source_id`, raw `/Users/...` paths), keeping brevity scoped strictly to final replies rather than the research/tool depth behind them.
   - Enforces **No Ghost Follow-ups**: never promise future notifications unless a concrete reminder, calendar alert, or scheduled check is actually persisted.

2. **Epistemic Humility & `PROACTIVE_PREFERENCES.md` (`momo_memory.py`, `life_pulse.py`, `superagent_runtime.py`):**
   - Explicitly grounds proactive evaluation in unobserved-world humility: missing records or unchecked reminders do not prove the user hasn't handled something offline.
   - Adds canonical `memories/PROACTIVE_PREFERENCES.md` support in `MoMoMemory` (`path='PROACTIVE_PREFERENCES.md'` / `category='proactive_preferences'`) and automatically injects active preferences into `life_pulse.format_pulse_brief(...)`, distinguishing standing preferences from one-time dismissals ("这次不用").

3. **Signal Waterfall, Untrusted Data Fence & Right-Altitude Dream Curation (`memory_review.py`, `superagent_gateway.py`):**
   - Defines explicit grounding priority (`current user statement > fresh tool/snapshot observation with timestamp/age > standing USER.md/MEMORY.md`).
   - Replaces brittle defensive shouting with causal "Right Altitude" instructions across Orchestrator, Worker, and Dream (`CURATION_POLICY_VERSION = "v8-steward-context-engineering"`), framing memory as durable understanding written *for the next conversation* rather than a transaction log.
