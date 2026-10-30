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
- Stop, pause and destroy cancel both pending RAF and frame-delay callbacks. Stop restores the open-eye first pose. A destroyed controller cannot restart.
- Frame scheduling is limited to at most 24 paints per second, including transitions and blinking, rather than repainting those phases at display refresh rate.
- Head/eye class names allow the application stylesheet to supply colors without modifying geometry. The local adapter hides the decorative SVG from accessibility; the existing chat status announcer remains authoritative.
- The chat admits animation only while the waiting indicator is shown, the document is visible and neither native nor CSS Reduce Motion is enabled. Page hiding stops it. Reasoning rows mount separate static instances with distinct clip identifiers.

The runtime tests execute the actual bundled upstream geometry under a controlled clock and verify animation, blink, paint limits, zero scheduled work when stopped, unique clip IDs and destruction. The WebKit test separately checks actual CSS appearance and controlled visibility/Reduce Motion integration. A controlled visibility event is not evidence of physical-device background behavior.

All original source notices and the full AGPL license are retained. This integration does not change or relicense the upstream code; distribution of the combined application must account for its license obligations.
