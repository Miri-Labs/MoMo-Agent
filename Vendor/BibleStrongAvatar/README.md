# MoMoAgent waiting avatar

The application uses actual code from [Bible Strong Avatar Lab](https://github.com/smontlouis/bible-strong-avatar-lab), pinned to commit `79fe9ba06e4874b11394b8e8a3f2c493c9d197ba`. Its author is Stéphane Montlouis-Calixte and its license is **AGPL-3.0-only**, reproduced without modification in [upstream/LICENSE](upstream/LICENSE). The same complete notice is bundled beside the runtime in the application.

This is a source-code integration of the upstream standalone procedural engine and browser runtime. Projection, rounded body geometry, ambient motion, expression transitions and blinking execute upstream code. It does not embed the hosted Studio, React, analytics, a network service or a WebView page from the upstream website.

`momoagent-avatar.json` is an original MoMoAgent definition written in code: a rounded body with two unequal short waveform lobes and simple eyes. It is not an upstream character or a Studio preset. CSS supplies the current text color and page-colored eyes in both appearances. The home brand icon is unchanged.

## Source and reproducible build

`upstream/` contains the unchanged TypeScript geometry/runtime sources, the upstream checked-in generated standalone engine, its entry/build script, package manifests, lockfile and license. `upstream-manifest.json` records byte counts and SHA-256 hashes for every copied source. The application bundle can be regenerated **without installing dependencies**:

```sh
node Vendor/BibleStrongAvatar/build.mjs
node Vendor/BibleStrongAvatar/build.mjs --check
node Vendor/BibleStrongAvatar/test.mjs
```

The build validates all source hashes, extracts the upstream committed IIFE and browser-runtime string, applies the explicit single-match lifecycle changes in `build.mjs`, and appends our definition and `adapter.js`. It never evaluates upstream strings during the build. The output is `Apps/iPhoneApp/Features/Assistant/Rendering/Web/vendor/momoagent-avatar.js` plus its full license. The exact checked-in IIFE remains in `upstream/src/features/export/standaloneEngine.generated.ts`; extraction is distinct from recompiling TypeScript.

To independently regenerate that upstream IIFE from TypeScript, use the full upstream repository at the pinned commit, its pinned `pnpm@10.34.5` and Node >= 22.12, run `pnpm install --frozen-lockfile` and `pnpm engine`, then compare the generated source with this saved copy. No such dependency installation is required by the iOS build or the local extraction/check command.

## Local runtime changes

- Static mounting never starts ambient animation. Playback owns all frame, step and blink scheduling.
- Stop, pause and destroy cancel pending RAF and step/blink timers. Stop restores the open-eye first pose. A destroyed controller cannot restart.
- Geometry paints are limited to 30 per second on one display-aligned RAF clock, or 15 in Low Power Mode. Changing the power budget retains the current pose and schedule. The previous timer-plus-RAF scheduler added uneven frame gaps; no separate frame timer remains.
- Playback immediately targets the next pose because mount/stop already display the first one. The listening cycle uses a visible ±24° yaw, no holds and no independent body drift, with a stationary viewport and rotation center.
- Head/eye class names allow the application stylesheet to supply colors without modifying geometry. The local adapter hides the decorative SVG from accessibility; the existing chat status announcer remains authoritative.
- The empty home uses a curious turn with up to 36 degrees of yaw and 12 degrees of roll, a changing gaze and a visible one-eye wink. Its three poses have no holds or independent body drift. The resting conversation header retains its quieter cycle. Switching profiles reuses the SVG and transitions from its current pose. Listening has open eyes and a lean toward the person; thinking has a pronounced asymmetric gaze and head tilt; actual tool execution uses wide narrow eyes, a ±9° turn and a squash pulse; speaking has open round eyes and nodding. The chat admits animation only while the waiting indicator is shown, the document is visible and neither native nor CSS Reduce Motion is enabled. Page hiding stops it. Reasoning rows mount separate static instances with distinct clip identifiers.

The runtime tests execute the actual bundled upstream geometry under a controlled clock and verify animation, blink, paint limits, zero scheduled work when stopped, unique clip IDs and destruction. The WebKit test separately checks actual CSS appearance and controlled visibility/Reduce Motion integration. A controlled visibility event is not evidence of physical-device background behavior.

## Original MoMo scene expressions

`momo-expressions.js` defines eight original scenes: present, listening, thinking, working, speaking, settled, concerned and greeting. Each eye is generated from MoMo-specific width, height, bend, tilt and gaze offsets. A curved capsule is sampled into 64 consistently ordered vertices; no reference contours, recipes or player are imported. GrokBot's [animation anatomy](https://github.com/ArvinYin1/grokbot-animation-anatomy) informed the general separation of geometry, transition and state, rather than the resulting shapes or motion data.

Explicit, single-match patches let the existing surface projection accept these custom points, including MoMo's current eye position, orientation, head surface and blink compression. `momo-expression-runtime.js` blends parameters over 220–420 ms on the existing frame clock, along with a continuous roll, lift and squash transform inside the SVG. A finished reply has large arched eyes and one hop before returning to presence; repeated snapshots do not replay it. Opening completed history suppresses that reaction. Idle taps produce a wink and a larger hop; busy taps give an acknowledging nod. Static updates schedule no work. The original body, waveform lobes, color handling and 30/15 fps budgets remain.

The contour generator samples straight edges as well as corners before bending. This makes a broad smiling eye curve through its center instead of turning into a straight bar. Regression checks enforce visible eye-size/asymmetry differences at the actual 84-point header scale, including broad focus eyes and a readable wink. Animation previews and viewport clipping evidence are linked in [the implementation record](../../docs/implementation/momo-expressive-motion-20261018.md).

`MoMoAvatar.create(...).setExpression(name)` selects a scene and `MoMoAvatar.expressions` lists them. The generated bundle contains the parameter generator and local state transitions. No second player, timer, fetch or extra runtime dependency is introduced. The earlier imported GrokBot data, extractor and source directory have been removed; the pre-existing avatar engine's AGPL attribution remains intact.

All original source notices and the full AGPL license are retained. This integration does not change or relicense the upstream code; distribution of the combined application must account for its license obligations.
