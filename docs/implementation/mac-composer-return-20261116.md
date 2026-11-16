# Mac composer Return repair — 2026-11-16

Scope: only the Mac branch of `ClientComposer`, its AppKit key handler, and an offline regression fixture. The existing SwiftUI multiline field, `canSend` predicate, send button and Command+Return shortcut remain. The iPhone input path is unchanged. No release artifact, installation, runtime/configuration change or real message is involved.

The native local key monitor checks the event's key window and the first responder's owning `NSTextField`. That field must belong to this composer's small `NSHostingController` container; a stale SwiftUI focus flag or another field's shared editor cannot grant ownership. This reuses the current field and gives it a concrete native scope without depending on SwiftUI private class names, accessibility identifiers or screen coordinates. The container measures the field at the proposed width and its natural height, preserving multiline growth and the five-line limit.

- Return and keypad Enter call the existing guarded send action once. Repeated key-down events are consumed without sending again.
- Shift+Return/Enter inserts a native newline. Other modifier combinations pass through.
- Marked text is inspected before AppKit commits it. Ordinary confirmation keys remain with native text input; the old sending `onSubmit` handler is removed.
- Normal Command+Return still reaches the existing send-button shortcut. Its repeats and presses during marked-text composition are consumed while this field owns focus.
- Inactive windows, other controls, hidden/disabled/noneditable fields and detached views are excluded. Dismantling removes the monitor and releases its callback.

Validation command, from the repository root:

```sh
bash Tests/Support/check-chat-composer-return.sh
```

Result: exit 0, **109 native behavior assertions passed** on macOS 26.6.2 (arm64), Apple Swift 6.4. The runner compiles the production handler and typography with `-swift-version 6 -warnings-as-errors -target arm64-apple-macos14.0`, then dispatches synthetic `NSEvent`s through `NSApplication` into native SwiftUI/AppKit controls. It uses temporary nonactivating panels with real key-window state. Coverage includes Return/keypad/Shift/Command, repeats, Chinese/Japanese native marked text and commit, immediate focus changes, another/inactive window, hidden fields, whitespace/attachment/disabled gates, updated callbacks, multiline growth/shrinkage/limit and removal/remount. `git diff --check` also passed.

The fixture exercises the production event-processing path. Its send callback only records in-memory values and models the existing send gate; it does not instantiate the live task store. This is a standalone compilation, not a full application build or installed-app acceptance. Real Chinese/Japanese candidate windows and physical keyboard input were not exercised; no system input source was changed. Default font size only.

Cleanup: the runner removes its executable/module cache on exit. The exploratory scratch directory, temporary test app and inspection binaries were also removed after checking that no process held them. No new runtime directory was retained. Filesystem available space after cleanup is recorded below; it is not attributed entirely to this task.

Available space: **13,530,336 KiB (about 12.9 GiB)**, measured with `df -k .` after cleanup.
