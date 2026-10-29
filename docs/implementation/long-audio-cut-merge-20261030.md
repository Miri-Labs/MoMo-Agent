# Long-recording cut-and-merge pipeline

Public version remains 0.0.1; internal build 8. The implementation keeps the existing local speech models and separates VAD endpoints, bounded ASR requests, acoustic speaker turns, and reading paragraphs.

## Decisions and sources

- [WhisperX cut-and-merge](https://github.com/m-bain/whisperX/blob/5d3678b8535698a2826a5db9eb3e4105aef85dd9/whisperx/vads/vad.py) provides the architectural reference: short VAD segments need not become separate ASR calls. Its [long-segment splitting](https://github.com/m-bain/whisperX/blob/5d3678b8535698a2826a5db9eb3e4105aef85dd9/whisperx/vads/pyannote.py) seeks a low speech-probability location instead of assuming the model limit is a sentence boundary.
- [Meetily's long-segment splitter](https://github.com/Zackriya-Solutions/meetily/blob/a2cb62e827da7ef59f65064c97233efb2313878e/frontend/src-tauri/src/audio/common.rs) motivates pause/energy-aware cuts. Its desktop 25 s target and absolute RMS threshold are not copied into the phone pipeline: MoMo preserves the 20 s memory ceiling and uses relative energy for quiet Watch recordings.
- [Buzz's transcript resizing](https://chidiwilliams.github.io/buzz/docs/usage/plugins) illustrates that reading paragraphs are a separate stage after transcription. This change uses existing ASR punctuation and speaker evidence, with no generative rewriting of the original text.

## Behavior

Archive Silero detects 300 ms pauses. The planner joins speech across gaps up to 2 s, skips longer gaps, and selects a detected pause in the latter half of each bounded window. For the 20 s ceiling, it prefers a complete utterance near 13 s; a pause of at least 1 s takes precedence over the target. If no detected pause exists, a relative 160 ms energy valley may provide a cut; otherwise the memory ceiling remains the fallback. Quiet audio is retained, and the existing VAD-only gain normalization is unchanged.

SenseVoice receives up to 1 s of left and right context, while disjoint cores own the output text. Punctuation follows its preceding word even when its timestamp crosses a core boundary. Speaker changes continue to create separate turns. FunASR-Nano retains its existing CPU runtime and core-only recognition because it has no genuine word timestamps; this change does not invent alignment timestamps or silently substitute another model.

An open input tail waits for the join horizon or sufficient right context. A native 16 s memory flush is not treated as a completed utterance. Pending onset/coda padding cannot be committed as silence. A checkpoint before a new utterance preserves the original context boundary, while a checkpoint within ongoing speech can reuse the original left context.

Reading groups preserve all source references and playback/correction targets. They join a continued sentence across ASR windows, prefer a sentence-ending boundary after 30 s, and retain a 90 s upper bound for unpunctuated speech. Speaker changes, long gaps, missing audio, issues, and epoch boundaries still break the group.

The archive fingerprint advances to `silero6-cut-merge-v6`. The previous `silero6-bounded-speech-v5` fingerprint is migrated using the existing completed-analysis preservation path. Completed historical transcripts, manual identity corrections, and source audio are not automatically replaced.

The phone selects `sherpaCoreML`: SenseVoice uses the existing Core ML execution-provider path, and WeSpeaker retains its existing Core ML path. FunASR-Nano remains on CPU because its quantized dynamic graph is not compatible with efficient Core ML partitioning. This is not a claim that every operation runs on ANE.

## Validation

Validation includes pause grouping, disjoint bounded coverage, quiet-volume invariance, provisional-tail behavior, punctuation ownership, checkpoint/context invariance, archive playback/correction regressions, native Chinese fixture recognition across incremental receipt and restart, and a controlled comparison using the user's prior three-minute recording.

The prior-recording comparison uses the same production Core ML ASR and speaker decoder for both window policies. Private transcripts, embeddings, and audio stay in local validation artifacts, outside Git. There is no human verbatim reference for this recording, so no CER/WER improvement is claimed.

Core ML cold specialization can move a CTC peak by one 60 ms acoustic frame without changing the recognized words. The repeatability check requires exact text/tokens and provenance, and bounds timing differences to one frame; CPU repeatability remains exact.

Final build, test, and device acceptance results are recorded with the delivery artifacts. An offline test or signed build does not establish installation or phone performance.

Validated on 2026-10-30: the speech run reported 91 tests (88 passed, 3 optional fixture-dependent tests skipped), and the archive run reported 247 tests (246 passed, 1 copied-device fixture test skipped). Native CPU/Core ML recognition and the new prior-recording comparison ran successfully; the optional Nano real-model test was not run. The Release phone/embedded Watch/widget build succeeded, all 29 bundle checks passed against the existing local upgrade identities, and all three signatures/profile identities were verified. The controlled recording produced 12 ASR windows and 29 acoustic turns versus 9 windows and 31 turns with the previous window policy; these are internal processing counts, not final UI row counts or accuracy scores. Both transcripts still contain recognition errors. Device installation was deferred at the user's request; phone performance remains unverified.
