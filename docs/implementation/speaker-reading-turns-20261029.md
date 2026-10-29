# Speaker turns and continuous reading

Version 0.0.1, internal build 6. This fixes two boundaries that were previously conflated: an inference window is not a reading paragraph, and an ASR sentence is not necessarily one speaker's turn.

## Recognition

- Pyannote's exclusive tracks determine speaker changes, including short tracks without a learnable voiceprint. Different tracks within one 10-second block remain separate even if embeddings are similar. Across blocks, WeSpeaker similarity can identify continuity.
- SenseVoice's genuine token onsets are aligned to acoustic turns while retaining the full-context text. Onset support is capped at 200 ms when choosing a boundary; punctuation follows its preceding words. These are approximate acoustic boundaries, not manually verified word end times.
- A single acoustic turn does not split again at every short silent interval. Short interjections retain the full decode's language context.
- Missing timestamps or ITN spelling changes trigger bounded per-turn recognition. FunASR-Nano's synthetic timestamps remain excluded. Failed/empty turn decoding retains the original successful transcript and records a speaker failure.
- Speaker evidence remains local. Core ML settings and model weights are unchanged; segmentation stays on CPU. This change does not establish iPhone ANE utilization or human-labelled diarization accuracy.

## Reading and feedback

- Adjacent spans with matching identity, within the same recording epoch and no more than a 2-second gap, share one reading row. Long turns start a new reading block at 45 seconds. Two unknown labels may join when there is no explicit speaker boundary; this is a reading heuristic, not evidence that their identities match.
- Explicit speaker changes, different identities/confirmation states, epochs, audio-availability transitions and intervening issue rows prevent joining.
- Durable spans, source references and timestamps remain intact. Playback includes every member, and feedback validates and updates all members in one transaction before refreshing matches.
- Split spans persist their speaker boundary, including through manual corrections and document reconciliation. Reading anchors and Watch marks resolve to the containing row.
- Existing transcripts gain reading grouping immediately. This release does not automatically re-transcribe completed history; previously unsplit multi-speaker text needs new recognition to acquire its acoustic boundaries.

## Validation

- 247 archive tests, including grouped playback, atomic correction, stale references, and separation across speaker/gap/epoch boundaries.
- 83 speech tests with a local opt-in recording test through the production Core ML adapter; 60 seconds from the user's existing recording (19:35:07 onwards). Test data and transcripts are not committed.
- Default-font iPhone simulator journey verifies merged reading, explicit speaker separation, and owner/not-owner feedback. Screenshot reviewed.
- Signed release bundle and device installation are verified separately; local delivery evidence records their outcomes. Public version remains 0.0.1 and main retains a single root commit.
