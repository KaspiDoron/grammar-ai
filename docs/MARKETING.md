# Typfix - Brand and Launch Kit

Everything to launch and talk about Typfix consistently. Copy is ready to
paste; adjust the voice if you like, but keep the promises accurate.

## The one-liner

Typfix fixes your grammar, spelling and punctuation in any Mac app with one
keystroke - free, private, and running on your own machine.

## Positioning

- What it is: a macOS menu-bar utility (and a Cursor/VS Code extension) that
  corrects the text you select, in place, anywhere you type.
- Who it's for: developers, writers, non-native English speakers, and anyone
  who writes all day across Slack, Mail, docs and code.
- Why it's different: it's free and local-first (your text never leaves your
  Mac), it keeps your voice instead of making everything corporate, and it's
  open source. No account, no subscription, no server.
- The category it quietly competes with: Grammarly - but private, free, and
  everywhere, without an account or a browser extension watching you.

## Taglines (pick per surface)

- Fix your writing anywhere. (primary)
- One keystroke. Better writing. Every app.
- Grammar fixes that keep your voice.
- Private grammar correction that runs on your Mac.
- Grammarly's convenience, none of the surveillance.

## Names and voice

- Product: Typfix (one word, capital T).
- Voice: plain, confident, a little dry. Short sentences. No hype words
  ("revolutionary", "magical"). Say exactly what it does. Respect the reader's
  intelligence and privacy.
- Always true, never overclaimed: "your text never leaves your Mac" applies to
  the local model; if you mention the Claude Code backup, say the text goes to
  Anthropic under the user's own account.

## Colors and logo

- Brand blue: #1466F5 (ink #0B48C0, soft #EAF1FF).
- Success green: #17A34A.
- Ink: #0E1526. On dark: #EEF1F7.
- Logo: a rounded blue tile with three white "text lines" and a green check
  badge (see the app icon and `site/favicon.png`). The wordmark is "Typfix" in
  a bold, tight-tracking sans (system font is fine).

## 30-second demo script (for a GIF or video)

1. Open Slack (or Mail). Type: "hey john, i wanted to ask if you can send me
   the files tommorow because i didnt recieved them yet".
2. Select it. Press Cmd+Shift+G.
3. It becomes: "Hey John, I wanted to ask if you can send me the files
   tomorrow because I haven't received them yet."
4. Cut to a casual one: "hey bro can u send that thing lol" -> "Hey bro, can u
   send that thing? lol" (caption: "keeps your voice").
5. End card: "Typfix - free, private, open source. Cmd+Shift+G anywhere."

Keep the whole thing under 20 seconds. The magic is the speed and that you
never left the app.

## Product Hunt

Tagline (60 chars max):
> Fix your grammar in any Mac app with one keystroke - free

Description:
> Typfix corrects grammar, spelling and punctuation in whatever app you're
> already in. Select text, press Cmd+Shift+G, and it's fixed in place - with
> your tone, slang and emojis intact. It runs a free AI model on your own Mac
> (via Ollama), so your writing never leaves your machine. No account, no
> subscription, open source. There's also a Cursor/VS Code extension for
> inline fixes as you type.

First comment (maker):
> Hi PH! I built Typfix because I write all day across Slack, Mail and my
> editor, and I wanted Grammarly's "fix it right here" convenience without an
> account, a subscription, or a browser extension reading everything I type.
> Typfix runs a small local model on your Mac, so corrections take about a
> second and your text never leaves the machine. If the local model isn't
> running it falls back to Claude Code automatically. It's open source (MIT) -
> I'd love your feedback on the correction quality and which apps you try it
> in.

## Hacker News (Show HN)

Title:
> Show HN: Typfix - fix grammar in any Mac app with one keystroke, runs locally

Body:
> Typfix is a small macOS menu-bar app that corrects the text you select in any
> app - press Cmd+Shift+G and the selection is replaced with a corrected
> version, keeping your tone and slang. It also ships a Cursor/VS Code
> extension for inline fixes.
>
> The part I care about most: it's local-first and free. Corrections run
> through a small model in Ollama (qwen3:1.7b by default, ~1s), so your text
> never leaves your Mac. If Ollama isn't running it falls back to the Claude
> Code CLI automatically.
>
> Some implementation notes that might interest this crowd:
> - Capture is Accessibility-first (AXSelectedText) with a clipboard-copy
>   fallback for Chromium/Electron apps, and it restores your full clipboard
>   afterward.
> - Replacement is paste-based but re-verifies the frontmost app and that the
>   same text is still selected before pasting; on any doubt it copies instead
>   of pasting, so it never makes the wrong change.
> - A reply is validated with a Sorensen-Dice resemblance check against the
>   original, so a prompt injection inside the selected text can't make it
>   paste something unrelated.
> - Built with just the Command Line Tools (no Xcode), Swift 6, no third-party
>   deps.
>
> It's MIT licensed. Feedback welcome, especially on per-app capture quirks.

Expected questions to be ready for: how it compares to Grammarly (privacy,
free, everywhere, but no cloud grammar engine); model quality vs. size; Intel
support; whether a signed download is coming (yes, on the roadmap).

## X / Twitter thread

1/
> I made Typfix: fix your grammar in ANY Mac app with one keystroke.
> Select text -> Cmd+Shift+G -> corrected in place.
> Free, private, runs on your Mac. Open source. 🧵

2/
> The trick is it works everywhere - Slack, Mail, Notes, Notion, your editor -
> because it reads the selection and pastes the fix back. No copy-paste into
> some other window. You never leave the app you're in.

3/
> It keeps your voice. "hey bro can u send that lol" becomes
> "Hey bro, can u send that? lol" - not "Dear Sir". Tone, slang and emojis
> stay. It fixes mistakes, it doesn't rewrite your personality.

4/
> Private by design: a small AI model runs locally via @ollama, so your text
> never leaves your Mac. ~1 second per fix. No account, no subscription, no
> server. If the local model is off, it falls back to Claude Code.

5/
> Writing commit messages or docs? There's a Cursor/VS Code extension too, with
> inline fixes and as-you-type suggestions.

6/
> It's open source (MIT). Build it in a minute:
> github.com/KaspiDoron/grammar-ai
> Would love feedback on which apps you try it in.

## Reddit (r/macapps, r/MacOS)

Title:
> [Free/Open Source] Typfix - one-keystroke grammar correction in any Mac app,
> runs locally

Body: same substance as the HN post, slightly warmer, lead with the privacy
and free angle, and include a GIF.

## Landing page

`site/index.html` is the marketing site (self-contained, no build step). Point
GitHub Pages at the `main` branch `/site` folder, or push it to `typfix.com`.

## App Store / listing copy (if a notarized build ships later)

Subtitle: "Fix your writing anywhere"
Promotional text:
> One keystroke corrects grammar, spelling and punctuation in any app - keeping
> your tone. Runs on your Mac, so your text stays private.

## What NOT to say

- Don't call it "AI-powered" as the headline - lead with the benefit
  ("fix your writing anywhere"), not the technology.
- Don't imply it's affiliated with or endorsed by Anthropic, Grammarly, or
  Apple.
- Don't claim "100% private" without the local-model qualifier if the user
  has switched on the Claude Code backup.
- Don't promise a signed download until one exists.
