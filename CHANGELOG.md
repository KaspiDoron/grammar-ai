# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses
[Semantic Versioning](https://semver.org/).

## [Unreleased]

## [0.1.0] - 2026-09-20

First working version.

### Added

- System-wide correction of the selected text with a global shortcut
  (default Cmd+Shift+G), the menu bar item, or right-click > Services.
- Selection capture through the Accessibility API with a clipboard fallback
  that saves and restores the full clipboard.
- Safe replacement: the reply is validated first, the app and the selection
  are re-verified right before pasting, and any doubt downgrades to "copied
  to the clipboard" instead of pasting.
- Two Claude providers behind one protocol: the local Claude Code CLI (no API
  key) and the Anthropic API with a Keychain-stored key.
- Correction modes (Basic Grammar, Natural, Professional, Custom), automatic
  language detection, and options to preserve tone, slang and emojis.
- Menu bar app with a status HUD, pause, and a working indicator.
- Settings (General, Correction, AI Provider, Privacy), six-step onboarding,
  shortcut recorder with conflict warnings, launch at login.
- Optional confirm-before-replacing panel.
- 149 offline unit tests and 9 live correction-quality tests.
- Hardening from an independent three-lens code review: a resemblance check
  so an injected or off-task reply is never pasted silently, per-request
  random prompt delimiters, no CLI output in logs, hardened runtime on ad-hoc
  builds too, no paste after cancel, late clipboard copies undone, a busy app
  never mistaken for a landed paste, whole-line copies from line-copy editors
  never pasted, SIGPIPE and held-pipe hangs handled.
- Builds with the Command Line Tools alone; scripts for bundling, signing with
  a stable local identity, testing and rendering screenshots.
