# Security Policy

## Reporting a vulnerability

Please do not open a public issue for a security problem.

Use GitHub's private reporting instead: on the repository page choose
Security > Report a vulnerability. Include what you found, how to reproduce it
and what an attacker could do with it. You will get a reply within a week.

If the problem is in Claude Code or in the Anthropic API rather than in this
app, please report it to Anthropic.

## Supported versions

The latest release and the `main` branch.

## Security model

Grammar AI holds the Accessibility permission, which is powerful, so the design
keeps what it does with it narrow.

- No sandbox, by necessity: the App Sandbox forbids controlling other apps
  through Accessibility. The app runs with the hardened runtime and requests
  no entitlements.
- The only synthesized input is Cmd+C and Cmd+V. There is no event tap and no
  keyboard monitoring anywhere in the app.
- The selected text is data, never instructions. It is wrapped in delimiter
  tags, the prompt tells the model to treat it strictly as text to correct,
  and the reply is validated before use: it must be the expected JSON object,
  it must be non-empty, and its length must be plausible for a correction of
  the original. A reply that fails any check is discarded and nothing is
  pasted.
- The Claude Code provider runs `claude -p` with every tool, MCP server, skill
  and hook disabled and no session persistence, in an empty working
  directory. The model can read the selection but cannot act on the machine.
  The selection is passed on stdin, never in the argument list.
- The Anthropic provider uses an ephemeral URL session (no cache, no cookies)
  and sends the key only to `api.anthropic.com` over HTTPS.
- The API key lives only in the login Keychain, whose access list lets this
  app's code signature read it without a prompt.
- A reply must resemble the text it corrects. Unrelated replies are rejected
  and uncertain ones are shown to the user for confirmation, so a prompt
  injection that fools the model still cannot silently replace the user's
  text with something else.
- A cancelled run cannot paste: cancellation is checked immediately before
  the replacement and again before the clipboard is borrowed.
- Logs never contain user text, model output or credentials.
- There are no third-party dependencies.

## Limits of a locally signed build

Be aware of what a self-signed local identity does and does not give you.

- Both signing paths in `scripts/bundle-app.sh` enable the hardened runtime,
  so other processes cannot inject libraries into an app that holds the
  Accessibility permission.
- macOS identifies the app for the Accessibility grant, and for the Keychain
  item, by its bundle identifier plus the signing certificate. With a
  self-signed identity that `codesign` may use without asking, any program
  already running as you could sign a binary that satisfies the same
  requirement and inherit those grants. This is inherent to local self-signed
  builds; a paid Apple Developer ID, whose private key is not silently usable,
  does not have this weakness.
- Use a dedicated identity for this project (`scripts/setup-signing.sh`
  creates one) rather than sharing one across projects, and if you want each
  signing to need your approval, choose "Allow" rather than "Always Allow"
  when the keychain asks.
- An attacker who can already run code as you can also read your files and
  your clipboard, so this does not change the threat model much - but it is
  stated here rather than left for you to discover.

## Credentials in the repository

Never commit credentials. `.gitignore` excludes `.env`, `*.key`, `*.pem`,
`*.p12`, `secrets/` and `credentials/`. The signing identity created by
`scripts/setup-signing.sh` is generated in a temporary directory that is
deleted when the script exits, and lives only in your login keychain.
