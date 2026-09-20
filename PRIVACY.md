# Privacy

Grammar AI is built so that the honest answer to "what does it do with my
text?" is short. Every statement below describes how the code behaves, and
the code is open for you to check.

## What is sent, and when

- Only the text you have selected.
- Only at the moment you ask for a correction: the keyboard shortcut, the
  menu bar item, or right-click > Services > Correct with Grammar AI.
- Together with the correction instructions (the mode, language and options
  you chose in Settings, including your custom instruction if you wrote one).
- Nothing is ever sent in the background. There is no automatic mode in this
  version.

## Where it goes

- With the default provider, the text is handed to the Claude Code program on
  your Mac, which sends it to Anthropic using the account you signed in with.
- With the API key provider, the text is sent directly to
  `https://api.anthropic.com` over HTTPS.
- In both cases Anthropic's terms and privacy policy for your account apply
  to that text, including their data retention and training settings. Grammar
  AI has no server of its own and the author never receives your text.
- For its own calls, Grammar AI switches off Claude Code's telemetry, error
  reporting and update checks, so a correction makes exactly one request.

## What is stored

- No history. The original text and the correction live in memory for about a
  second and are then discarded.
- Nothing about your corrections is written to disk. Claude Code is run with
  session saving turned off.
- Preferences (mode, language, shortcut and so on) are stored in the standard
  macOS preferences for the app. They contain no text you corrected.
- The optional Anthropic API key is stored only in your macOS login Keychain,
  where only Grammar AI can read it without asking you. It never appears in
  the interface, in preferences or in logs. Like everything in your login
  Keychain, it is included in your own Time Machine backups.

## What is never done

- No keystroke logging. Grammar AI does not observe what you type. It
  registers one global shortcut with macOS, and macOS notifies the app only
  when that exact combination is pressed.
- No screen recording and no screenshots.
- Password fields are never read, and the app stays inactive while macOS
  secure input is on.
- No analytics, no crash reporting service, no network requests other than the
  correction itself.

## Your clipboard

Some apps (Chrome, Electron apps, Google Docs) do not expose their text to the
macOS Accessibility API. There, and whenever a correction is pasted, Grammar AI
uses the clipboard for a moment:

- your current clipboard contents (all formats, including images and files)
  are saved in memory first and restored right after;
- the temporary text is tagged with the nspasteboard.org markers so clipboard
  managers do not record it;
- if you copy something yourself during that moment, your copy is kept.

When a correction cannot be pasted safely (you switched apps, the selection
changed, or you are in a terminal) the corrected text is deliberately left on
your clipboard, and the app tells you so.

## Logs

Diagnostic logs go to the macOS unified log. They contain event names, error
types and status codes. They never contain your text, Claude's reply or your
API key.

## Permissions

Accessibility is the only permission requested. It is used to read the
selected text of the app you are working in and to post the paste that
replaces it. It is not used for anything else.

## Questions

Open an issue at https://github.com/KaspiDoron/grammar-ai/issues, or see
[SECURITY.md](SECURITY.md) to report a problem privately.
