# Domain Docs

Layout: **single-context** (`GLOSSARY.md` at repo root when created, plus `docs/adr/`).

## Before exploring, read these

- **`GLOSSARY.md`** at the repo root (if present; proceed silently if absent until `/domain-modeling` creates it).
- **`docs/adr/`**: read ADRs relevant to the subsystem you are modifying.

## Rules

- Use the vocabulary established in `GLOSSARY.md` and `AGENTS.md` (product name: **MoMo Agent**, assistant: **MoMo**; never rename Bundle IDs, Keychain service names, or live data directories).
- Flag any contradiction with an existing ADR explicitly rather than silently overriding it.
