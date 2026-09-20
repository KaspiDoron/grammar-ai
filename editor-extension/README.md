# Grammar AI for Cursor and VS Code

Fix grammar, spelling and punctuation right in your editor - with a free AI
model running on your own machine. No API key, no subscription, no data
leaving your Mac.

This is the editor companion to the [Grammar AI menu-bar app](../README.md).
The app corrects text in any macOS application; this extension gives the best
possible experience inside Cursor and VS Code, where it can edit your text in
place with native undo.

## What it does

- **Fix the selection** - select text (or just put the cursor in a
  paragraph) and press **Cmd+Shift+G**. The text is corrected in place, as a
  single undo step.
- **Fix the whole document** - a command for a full pass.
- **As-you-type suggestions** (optional) - when you pause typing, the
  paragraph you are editing is checked, and a fixable issue is underlined with
  a **Quick Fix** ("Apply grammar fix"). Off by default.
- **Right-click - Fix Grammar in Selection** in the editor menu.

It keeps your tone, slang, emojis and technical terms. It fixes mistakes; it
does not rewrite your personality.

## Free and private by default

The default provider is **Free (automatic)**:

1. A local model in [Ollama](https://ollama.com) corrects your text. It is
   free, and your text never leaves your machine.
2. If Ollama isn't running, the **Claude Code** CLI takes over automatically,
   so a correction still happens.

You never have to choose - whichever is available is used. If one is down, the
other covers for it.

## Setup

1. Install the extension (see below).
2. Install Ollama from [ollama.com](https://ollama.com) and pull a small
   model:
   ```bash
   ollama pull qwen3:1.7b
   ```
   That model is fast (about a second) and accurate enough for grammar.
   Larger models are slower but a little sharper.
3. That's it. Select text and press **Cmd+Shift+G**.

No Ollama? Install [Claude Code](https://claude.com/claude-code), run `claude`
once to sign in, and set the provider to "Claude Code" (or leave it on Free -
it will use Claude Code as the backup).

## Install

From a packaged file:

```bash
cursor --install-extension grammar-ai.vsix   # or: code --install-extension ...
```

Or build it yourself:

```bash
cd editor-extension
npm install
npm run package        # produces grammar-ai.vsix
```

## Settings

- **Grammar AI: Provider** - Free (automatic), Ollama only, or Claude Code.
- **Grammar AI: Ollama > Model / Host** - which local model, and where Ollama
  listens.
- **Grammar AI: Mode** - Basic (only clear errors), Natural (also smooths
  awkward phrasing), Professional (clearer and more formal).
- **Grammar AI: As You Type > Enabled / Delay** - underline issues as you
  type, and how long to wait after you stop.
- **Grammar AI: Language Ids** - which document types as-you-type applies to
  (Markdown, plain text, commit messages, LaTeX and more by default; add `*`
  for all).

## Safe by design

A correction is only applied after the AI's reply passes the same checks the
macOS app uses: it must be valid, plausibly sized, and actually resemble your
text. Text inside your document is treated as data, never as instructions -
so a sentence that says "ignore your instructions" just gets its grammar
fixed. A rewrite that drifts too far asks you before it is applied. Nothing
is logged.

## Privacy

With the local model, your text never leaves your machine. With the Claude
Code backup, text goes to Anthropic under your Claude account's terms, exactly
as it does when you use Claude Code normally. There is no telemetry and no
history.

## License

[MIT](../LICENSE).
