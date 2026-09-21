# Manual Testing

Everything that can be automated is in `scripts/test.sh`. What cannot is how
other apps' text fields behave, because that needs real apps, a granted
Accessibility permission and real key events. This document is the procedure
for that. Run the relevant part when you change capture or replacement, and
the whole thing before a release.

## Setup

1. `scripts/bundle-app.sh --run`
2. Grant Accessibility access (System Settings > Privacy & Security >
   Accessibility > Typfix).
3. Settings > AI Provider shows "Connected". Click **Test Correction**.
4. Copy a recognisable sentinel to the clipboard first, for example
   `CLIPBOARD-SENTINEL`. After every test below, paste somewhere harmless and
   confirm the sentinel is still what comes out. A test only passes if the
   clipboard survived.

Test sentence (type it, do not paste it, so the app's own text handling is
exercised):

```text
hey john, i wanted to ask if you can send me the files tommorow because i didnt recieved them yet
```

## The core check, per app

For each app: type the sentence, select it, press Cmd+Shift+G.

Pass means all of:

- the HUD shows "Correcting..." and then "Corrected" within about 2 seconds;
- only the selected text changed, and it is the corrected sentence;
- Cmd+Z restores the original;
- the clipboard still holds the sentinel;
- focus never left the app.

Also do one partial selection per app (select only `tommorow because i didnt
recieved`) and confirm the text around it is untouched, including spaces.

Apps and what to expect:

- TextEdit (rich and plain text) - Accessibility capture. Reference case.
- Notes - Accessibility capture.
- Mail, new message body and subject field - Accessibility capture.
- Messages, compose field - Accessibility capture.
- Safari, a `textarea` (any web form) and a rich editor (Gmail compose) -
  Accessibility capture through WebKit.
- Chrome and Arc, the same two pages - usually the clipboard fallback. Confirm
  the sentinel survives.
- Slack and Discord, message field - clipboard fallback. Confirm the message
  is not sent and formatting is sane.
- VS Code and Cursor, editor - clipboard fallback. Also run the "nothing
  selected" check below: these editors copy the whole line when nothing is
  selected, which must be treated as no selection.
- Notion, a text block - clipboard fallback.
- Microsoft Word - either path. Check that the font of the replaced text
  matches its surroundings.
- Google Docs in Chrome and in Safari - clipboard fallback (the document is a
  canvas). Confirm the correction lands in place.
- Terminal and iTerm2, selected scrollback - must NOT paste. Expect the HUD
  "Terminals can't be edited in place. Correction copied." and the correction
  on the clipboard (the one case where the sentinel is replaced on purpose).

How to tell which path was used:

```bash
/usr/bin/log stream --predicate 'subsystem == "com.kaspidoron.grammarai"' --info
```

prints "captured via accessibility" or "captured via clipboard".

## Failure cases

Each must leave the document exactly as it was.

- Nothing selected: click into a text field with no selection, press the
  shortcut. Expect "Select some text first." Repeat in VS Code.
- Password field: select text in a password field (Safari login form, System
  Settings). Expect "Typfix never reads password fields." or "Select some
  text first." and no network request.
- Accessibility denied: switch the permission off, press the shortcut. Expect
  "Typfix needs Accessibility access." and a "Grant Accessibility
  Access..." item in the menu. Switch it back on; it must work again without
  relaunching.
- Claude unavailable: turn Wi-Fi off, press the shortcut. Expect "Couldn't
  connect to Claude." or "Claude took too long to respond."
- Claude Code missing: set Settings > AI Provider > Path to claude to
  `/nonexistent`. Status shows a warning and the shortcut reports that Claude
  Code is not installed. Clear the field afterwards.
- Bad API key: choose the API key provider, save `sk-ant-invalid`. Expect
  "Anthropic rejected the API key." Remove the key afterwards.
- Switching apps mid-correction: press the shortcut and immediately Cmd+Tab
  away. Expect "You switched apps, so the correction was copied instead." and
  no change in either app.
- Changing the selection mid-correction: press the shortcut, then click
  elsewhere in the same document before it finishes. Expect "The selection
  changed. Correction copied." and no inserted text.
- Cancel: with a long selection, open the menu during "Correcting..." and
  choose Cancel Correction. Nothing changes and no error is shown.
- Cancel during review: with Confirm before replacing on, trigger a
  correction and, while the panel is open, choose Cancel Correction from the
  menu. The panel closes and nothing is pasted.
- Line-copy editors (Sublime Text, a JetBrains IDE, Zed): put the caret in a
  line with NOTHING selected and press the shortcut. The line must not be
  duplicated; expect "Couldn't confirm the selection in this editor.
  Correction copied." Then select part of a line and confirm that is replaced
  normally.
- Big rewrite: mode Professional on `hey can u send the report asap thx` with
  Confirm before replacing OFF. If the rewrite is far from the original the
  review panel must still open.
- Double trigger: press the shortcut twice quickly. Exactly one correction
  happens.
- Very large selection: select more than 10,000 characters. Expect
  "Selection is too long" and no request.
- Already correct text: select a correct sentence. Expect "Already looks good"
  and no change.

## Language and tone

- `hey bro can u send me that thing lol` stays casual and keeps "lol".
- `omg this are so good 😂🔥 cant wait` keeps both emojis.
- A Hebrew sentence is corrected in Hebrew, right-to-left intact, in TextEdit
  and in a browser field.
- Switch the macOS input source to Hebrew and press the shortcut in a Chrome
  field: the copy and paste key codes must still work.
- If you use a non-QWERTY layout (Dvorak, AZERTY, Colemak), repeat the Chrome
  test with it active.
- Mode Professional turns `hey can u send the report asap thx` into a
  professional sentence; mode Basic Grammar leaves the wording alone.

## Other entry points

- Menu bar > Correct Selected Text does the same as the shortcut.
- Right-click > Services > Correct with Typfix in TextEdit, Notes and
  Mail replaces the selection and is undoable. Try it with Typfix not
  running: macOS launches it.
- Confirm before replacing (Settings > General): the panel shows both
  versions; Return replaces, Cmd+C copies, Esc cancels. The target app must
  keep its selection while the panel is open.

## Suggest as I type (automatic mode)

Turn on Settings > General > "Suggest as I type" (needs Ollama running and
Accessibility granted).

- In TextEdit or Notes, type a wrong sentence and end it with a period, e.g.
  "i dont think this is workin properly." Pause. Within about a second a small
  pill appears near the caret with the corrected sentence and "<shortcut> to
  fix".
- Press the shortcut (Cmd+Shift+G): the sentence is replaced in place.
- Keep typing instead: the pill disappears without changing anything.
- Move focus to another field or app: the pill disappears.
- Confirm it never changes text on its own - it only ever suggests.
- Confirm it does nothing in a password field.
- Chrome/Electron apps may not expose the field to Accessibility; there the
  pill will not appear (use the shortcut on a selection instead). This is an
  expected limitation.

## Settings and lifecycle

- Record a new shortcut; the old one stops working at once and the new one
  works. Esc cancels recording, Delete clears the shortcut.
- Recording Cmd+C shows the "common shortcut" warning; recording a shortcut
  macOS uses (for example the Spotlight one) shows the system warning.
- Enabled off, or Pause for 1 Hour: the icon dims and Cmd+Shift+G reaches the
  frontmost app again (Find Previous works in Safari).
- Launch at login: switch it on, confirm Typfix appears in System
  Settings > General > Login Items, log out and in, confirm it is running.
- Quit and relaunch: every setting persisted; onboarding does not reappear.
- Open the app a second time from Finder: no second menu bar icon; Settings
  opens instead.
- Activity Monitor: about 0 percent CPU when idle.
- VoiceOver: the HUD messages are announced; every Settings control has a
  label.
- Light and dark appearance, and a full-screen app: the HUD is readable and
  appears over the full-screen space.

## Recording results

Note the macOS version, the app versions and the keyboard layout in the pull
request, and list anything that did not pass as a known limitation in the
README rather than leaving it undocumented.
