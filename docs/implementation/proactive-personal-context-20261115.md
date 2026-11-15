# Proactive personal context and speaker consent

Dream now reconciles suspect ASR and old notes using recording context, independently supported observations across days, phone visits and chat. It maintains home, multiple workplaces and people associations in the existing shared Markdown vault. The existing DSH/SuperAgent runtime, daily review scheduler, phone source replica and speaker synchronization queue remain the execution path.

## Reasoning and evidence

- Raw ASR stays available. Notes preserve the ambiguous original wording, a supported interpretation, source links and unresolved alternatives. A plausible replacement is not presented as the original utterance.
- `read_recording` and CLI `recording` include `location_context`: observed visit intervals overlapping the returned spans, device/snapshot provenance, record IDs, coordinates, accuracy and timezone. `location_offset` pages matches; the public source endpoint accepts the same parameter. Missing arrival/departure is not extrapolated into a stay. Changed phone snapshot revisions require restarting location pagination; `phone_context` remains the complete history-within-coverage path.
- Place/person notes distinguish hypotheses, repeated support, user confirmation and retractions. Home working, travel hotels, guests, remote calls, coordinate drift and multiple workplaces are explicit reasoning cases. An anonymous cluster number is local to one recording. Phone presence is not speaker presence; recurrent interaction is not proof of employment, cohabitation or family status.
- Location evidence references belong in source footnotes. The phone provides rolling snapshots, so notes retain the observation time, coordinate/accuracy and reference; a missing later snapshot is not new evidence against the observation. This change does not introduce an indefinite location-history archive.
- Dream prioritizes new evidence and affected notes instead of requiring a full five-stage vault rewrite each time. Small stable indexes belong in core memory; tentative relationships remain in detail pages.

## Speaker consent

All model paths (Dream, worker PIM bridge and master CLI) call the same proposal boundary. `relabel_speakers` / `relabel_recording_speakers` now return `changed: false` and a proposal state. They cannot grant consent via an argument. A direct user instruction to correct a name can supply evidence; the specific mutation still receives a scoped confirmation.

A proposal freezes source evidence, exact span IDs, target name, owner flag and rationale in the existing context database. Anonymous clusters resolve into a fixed selection, so later turns do not inherit permission. Named clusters require exact selection. Deleted/forgotten sources, changed source metadata and later speaker corrections invalidate outstanding proposals.

The existing gateway delivery loop displays at most one new suggestion per 24 hours, with a recording link, time range, affected-turn count and rationale. It asks for `确认标注 N` or `暂不标注 N`. Only an exact, authenticated chat message can decide a displayed proposal. A quote, attachment, transcript or model tool call is not consent. The confirmation response is local and does not depend on model availability. Repeated posts reuse the decision and phone-delivery ID; a lost chat receipt can be replayed.

An approval atomically applies the selected label and queues the existing iPhone voiceprint update. The reply accurately says that phone synchronization is pending. A refusal persists and suppresses the same suggestion, including when a model changes its wording. Pending suggestions never count as completed Dream memory writes. Existing manually maintained Markdown remains the user-visible knowledge representation; the proposal table stores consent workflow state, not inferred personal facts.

## Validation

Targeted Python tests cover memory/retrieval/review, phone context, runtime bridge and consent. The new tests exercise the actual authenticated chat endpoint, rejection, restart/replay, stale/deleted source invalidation, immutable selection, location pagination and missing boundaries. SuperAgent tests cover the tool schema (including refusal of a model-supplied approval field) and location pagination; typecheck and the tracked bundle are rebuilt. A relocated source bundle imports the gateway and creates the consent schema with only the packaged Runtime path available.

`Tests/AgentRuntime/personal_context_live.py` uses the configured real model against a temporary synthetic profile; credentials are resolved in memory and no test facts enter the user's profile. It seeds deliberately wrong notes, runs the production Dream tool loop, then starts a fresh completion with only the saved Markdown. Cases cover swapped home/work, two workplaces, a temporary hotel, remote coworker speech at home, an ambiguous ASR amount versus an undecided budget, and a candidate speaker awaiting approval. This is a small controlled correction test, not a production accuracy estimate or a comparison with a different model/runtime.

During development the first run repaired the facts but did not propose a speaker; the candidate/confirmation distinction was clarified. The next run proposed correctly but omitted explicit location source identifiers; evidence references and source-footnote guidance were added. One later attempt encountered a model-stream timeout; the test supports one bounded replay using persisted synthetic state.

Final validation: 134 Python tests and 12 SuperAgent tests passed, along with typecheck/build and relocated-runtime verification. In the synthetic correction test, fresh-session fact checks improved from 1/7 to 7/7; all 11 fact/consent/provenance checks passed. See [the acceptance JSON](proactive-personal-context-20261115.acceptance.json). The baseline deliberately contains incorrect notes, so this measures correction of that fixture, not an overall accuracy gain. This source change has not been installed into the running Mac app, nor accepted on a physical iPhone or across a real overnight Dream cycle.
