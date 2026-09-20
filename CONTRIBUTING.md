# Contributing

Thanks for helping. Grammar AI is small on purpose; the bar for a change is
that it makes the one workflow (select, shortcut, corrected) faster, safer or
more reliable.

## Getting started

You need macOS 14 or later and the Xcode Command Line Tools
(`xcode-select --install`). Xcode itself is optional.

```bash
git clone https://github.com/KaspiDoron/grammar-ai.git
cd grammar-ai
swift build
scripts/test.sh
```

To run the app with the Accessibility permission surviving your rebuilds, run
`scripts/setup-signing.sh` once, then `scripts/bundle-app.sh --run`. Running
the bare binary with `swift run` works for UI work, but launch at login and
the Services menu need the real app bundle.

## Project layout

- `Sources/GrammarAICore` - pure logic. Foundation only. Put anything that can
  be tested without a Mac UI here.
- `Sources/GrammarAISystem` - macOS integration without UI: Accessibility,
  clipboard, synthesized keys, global hotkey, launch at login.
- `Sources/GrammarAI` - the AppKit shell and SwiftUI views.
- `Tests/` - Swift Testing suites for the first two targets.
- `docs/` - architecture, research findings, manual test procedures.

Read [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) before a larger change.

## Rules that are not negotiable

- The user's text is never changed unless the correction was validated and the
  same text is still selected in the same app. When in doubt, do nothing or
  copy to the clipboard. New code paths need a test proving this.
- No user text, model output or credentials in logs. Use `Log`, which takes a
  static event name for exactly this reason.
- No keyboard monitoring, no event taps, no screen capture, no history.
- No third-party dependencies without a discussion in an issue first. The
  native APIs have been enough so far.
- The build must stay free of warnings, in Swift 6 language mode.

## Tests

```bash
scripts/test.sh                       # offline, under a second
scripts/test.sh --filter Pipeline     # one suite
scripts/test.sh --live                # also calls your real Claude setup
```

Tests must never touch the user's real clipboard (use a named pasteboard or
`FakeClipboard`), never post key events and never need a permission. What can
only be checked by hand is described in
[docs/MANUAL_TESTING.md](docs/MANUAL_TESTING.md); please run the relevant
section when you change capture or replacement.

## Checking the UI

```bash
swift build && .build/debug/GrammarAI --screenshots docs/screenshots
```

renders every window to PNG off screen, using throwaway settings. Include the
updated images when a change is visible.

## Adding an AI provider

Implement `AITextCorrectionProvider`, add a case to `ProviderKind` and to
`ProviderFactory`, and give it a section in the AI Provider settings pane.
Providers return raw results; validation stays in the pipeline.

## Style

- Match the surrounding code. Comments explain why, not what.
- Plain hyphens in prose and comments. No tables in Markdown files; use lists.
- User-facing strings are short, calm and specific.

## Pull requests

Keep them focused, describe the behaviour change and how you tested it, and
update `CHANGELOG.md` under "Unreleased".
