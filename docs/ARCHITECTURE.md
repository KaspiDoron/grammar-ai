# Architecture

Grammar AI is a menu-bar app that corrects the selected text in any macOS app.
This document explains how it is put together and why. The evidence behind
the platform decisions is in [RESEARCH.md](RESEARCH.md).

## The one flow

```text
hotkey / menu / Services
        |
        v
  capture selection      AX first, Cmd+C fallback         (GrammarAISystem)
        |
        v
  correct with Claude    provider behind a protocol       (GrammarAICore)
        |
        v
  validate the reply     parse JSON, sanity-check size    (GrammarAICore)
        |
        v
  confirm (optional)     keyboard-first panel             (GrammarAI)
        |
        v
  replace selection      re-verify, paste, restore        (GrammarAISystem)
```

The order is the safety guarantee. The user's document is touched only in the
last step, after the reply was parsed and validated. Any failure before that
leaves the original text exactly as it was, and the last step itself refuses
to paste if the app or the selection changed while Claude was thinking.

## Modules

Three SwiftPM targets, no third-party dependencies.

- `GrammarAICore` - Foundation only. Models, settings, the prompt, the
  response validator, the pipeline actor, both Claude providers, the Keychain
  wrapper and logging. Everything here is unit-tested without a Mac UI.
- `GrammarAISystem` - macOS integration without UI: Accessibility permission
  and selection reading, clipboard snapshot and restore, synthesized Cmd+C
  and Cmd+V with layout-aware key codes, the selection capturer and text
  replacer, the Carbon global hotkey, shortcut conflict detection and launch
  at login.
- `GrammarAI` - the executable. AppKit shell (status item, windows, HUD,
  Services provider) with SwiftUI content (Settings, onboarding, confirm
  panel) and the coordinator that wires everything together.

Dependencies only point downwards: `GrammarAI` -> `GrammarAISystem` ->
`GrammarAICore`.

## Important interfaces

All in `GrammarAICore/Protocols/Protocols.swift`:

- `AITextCorrectionProvider` - `correct(text:context:)` and
  `checkAvailability()`. Implemented by `ClaudeCodeProvider` and
  `AnthropicAPIProvider`. A new engine (OpenAI, Gemini, a local model) is one
  new type plus one case in `ProviderFactory`.
- `TextSelectionCapturing` - returns a `CapturedSelection` (text, how it was
  captured, which app). Implemented by `SelectionCapturer`.
- `TextReplacing` and `ClipboardWriting` - implemented by `TextReplacer`.
  Replacement returns `.replaced` or `.copiedToClipboard(reason:)`; it throws
  only when it could do neither.
- `CorrectionConfirming` - the optional confirm-before-replacing step.

`CorrectionPipeline` checks for cancellation one last time immediately before
replacing, and `TextReplacer` again before it borrows the clipboard, so a run
the user cancelled can never reach the document.

`CorrectionPipeline` is an actor that owns one run at a time (a second
trigger while busy is ignored), snapshots the settings at trigger time, and
reports `PipelineEvent`s to the UI. It depends only on the protocols above,
which is what makes the safety ordering testable with fakes.

## Claude integration

- `ClaudeCodeProvider` runs the local `claude -p` with every tool, MCP
  server, skill, hook and session file disabled, in an empty working
  directory, with the selection on stdin. It reuses the Claude Code login, so
  there is nothing to configure.
- `AnthropicAPIProvider` calls the Messages API over HTTPS with an ephemeral
  `URLSession` (no cache, no cookies) and the key read from the Keychain at
  request time.
- The prompt (`CorrectionPrompt`) is data: a replaceable base instruction,
  one paragraph per mode, the preserve options and the language rule. The
  selection is wrapped in `<text_to_correct>` tags and the prompt states that
  it is data, never instructions, so "ignore your instructions" inside a
  selection gets its grammar fixed instead of being obeyed.
- The reply must be the JSON object `{"corrected_text", "changed",
  "language"}`. `ResponseValidator` parses it (tolerating a code fence),
  rejects empty or implausibly sized text, strips wrapping the model added,
  and re-applies the selection's original leading and trailing whitespace.
- A correction must also resemble what it corrects. The validator scores the
  character-pair similarity between the original and the reply: close replies
  pass, unrelated ones (an injected instruction that worked, a refusal, a
  translation) are rejected, and the uncertain band in between is flagged
  `needsReview`. The pipeline never pastes a flagged result on trust - it
  opens the confirm panel even if confirmation is switched off.
- The delimiter tags carry a random per-request suffix, so text inside a
  selection cannot close the data region by containing a literal closing tag.

## Permissions and security model

- One permission: Accessibility. It is checked silently; the system prompt is
  requested once, from onboarding. No Input Monitoring, no Screen Recording,
  no Automation.
- Not sandboxed (the sandbox forbids Accessibility control of other apps).
  Hardened runtime on, no entitlements.
- The only secret is the optional API key: login Keychain only, readable
  without a prompt only by this app's code signature; never in UserDefaults,
  logs or the UI in clear text.
- Logs go to the unified log and contain event names and sanitized technical
  details only. `Log` takes a static event name precisely so user text cannot
  be interpolated by accident.
- Nothing is persisted about corrections. There is no history.

## UX structure

- `NSStatusItem` with an `NSMenu` (not `MenuBarExtra`): full control of key
  equivalent display, checkmarks and the working animation.
- Feedback is a small non-activating HUD panel, so focus never leaves the app
  the user is typing in. "Show notifications" turns the HUD off; errors then
  surface in the status item and its menu.
- Settings and onboarding are SwiftUI inside plain `NSWindow`s. The SwiftUI
  `Settings` scene is unreliable to open programmatically from an accessory
  (LSUIElement) app, so we do not use it.

## Automatic mode (designed, not built)

`CorrectionTrigger` already distinguishes where a run came from. Automatic
mode would be a new trigger source that watches the focused element for
`kAXValueChangedNotification` (never keystrokes), debounces, and feeds the
same pipeline with confirmation forced on, so a suggestion is shown and
nothing is replaced without the user accepting it. It is opt-in by design and
is intentionally absent from this version: sending every sentence to a model
unprompted is a privacy and cost decision that deserves its own design pass.

## Testing strategy

- Unit tests (Swift Testing, run by `scripts/test.sh`): prompt construction,
  validator, pipeline ordering and every failure path with fakes, both
  providers against fake process and HTTP transports, settings persistence,
  key combos, clipboard snapshot round-trips on a private pasteboard.
- Live tests (`scripts/test.sh --live`): real Claude on the fixed sample
  sentences - tone, slang, emoji, Hebrew, mixed language, prompt injection.
- Manual procedures for what cannot be automated (other apps' text fields):
  [MANUAL_TESTING.md](MANUAL_TESTING.md).

## Biggest risks

- Apps differ. Capture and paste behaviour in third-party apps can change
  with their updates; the clipboard fallback and the copy-instead downgrade
  exist so the failure mode is "no change", never "wrong change".
- Clipboard restore timing. Restoring before the target app has read the
  pasteboard would paste the old clipboard. Mitigated by a floor delay plus
  AX confirmation, see RESEARCH.md section 2.
- The Claude Code CLI is an external program; its flags or output envelope
  may change. The provider fails closed (invalid response, nothing pasted)
  and the API-key provider is the alternative.
- Distribution. Without a Developer ID the app is built locally; the
  Accessibility grant only survives rebuilds with a stable signing identity.
