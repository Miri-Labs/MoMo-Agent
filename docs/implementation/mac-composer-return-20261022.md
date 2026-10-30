# Mac composer Return repair — 1.26.2

Scope: Mac chat input only, existing layout and iPhone input unchanged. Return submits once; Shift+Return inserts a line break; empty input stays local; existing Command+Return remains supported. IME candidate confirmation stays with the native text-input system.

The shared composer had only a Command+Return button shortcut and no submission handler. The Mac multiline TextField now uses native `onSubmit`. Native Shift+Return also submits that field, so only that combination is handled as `NSTextView.insertNewlineIgnoringFieldEditor`; marked text is left to the input method. No global key monitor or new editor implementation.

Validation: universal Mac Beta build passed. CUA operated an isolated copy of the production app against a loopback synthetic service: Return submitted and cleared, Shift+Return retained two lines without submitting, Return submitted both lines intact once, empty Return created no message, Command+Return still submitted. Durable journal and received payload assertions passed. No real model called; live IME candidate UI was not exercised. The normal profile's existing messages and empty draft were preserved.

Installed Mac Beta 1.26.2 with the same designated signing requirement as 1.26.1. Latest Mac archive verified. Task build output and isolated test app/data cleaned after validation. Hermes branch only; no main merge.
