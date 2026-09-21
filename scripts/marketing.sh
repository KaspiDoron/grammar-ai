#!/bin/bash
# One command to launch the Typfix growth pushes. It opens each platform's
# post box already filled in - you just read it and click Post. No copy-paste.
#
#   scripts/marketing.sh            # opens all of them
#   scripts/marketing.sh x hn       # only the ones you name
#
# Platforms: x (Twitter), bluesky, reddit, hn (Hacker News), producthunt.
#
# Note: this cannot post FOR you. Every platform requires you to be logged in
# and to press Post yourself - that is a rule of theirs (and a good one). This
# just removes the copy-paste so it is one click on your end. It is free.
set -euo pipefail

SITE="https://typfix.com"
REPO="https://github.com/KaspiDoron/grammar-ai"
# Fall back to the live GitHub Pages URL until the custom domain is set up.
if ! curl -sI "$SITE" 2>/dev/null | head -1 | grep -q "200"; then
    SITE="https://kaspidoron.github.io/grammar-ai/"
fi

enc() { python3 -c 'import sys,urllib.parse;print(urllib.parse.quote(sys.argv[1]))' "$1"; }
open_url() { echo "==> Opening $1"; open "$2"; sleep 1; }

X_TEXT="I made Typfix: fix your grammar in ANY Mac app with one keystroke.
Select text -> Cmd+Shift+G -> corrected in place, keeping your tone.
Free, private (runs on your Mac via a local model), open source.
$REPO"

BSKY_TEXT="$X_TEXT"

REDDIT_TITLE="[Free/Open Source] Typfix - one-keystroke grammar correction in any Mac app, runs locally"
REDDIT_TEXT="Typfix corrects the text you select in any app - press Cmd+Shift+G and it's fixed in place, keeping your tone and slang. It runs a small AI model locally via Ollama, so your text never leaves your Mac (with a Claude Code fallback). There's also a Cursor/VS Code extension. Open source (MIT): $REPO

Site: $SITE"

HN_TITLE="Show HN: Typfix - fix grammar in any Mac app with one keystroke, runs locally"

want() { [ "$#" -eq 1 ] && return 0; shift; for a in "$@"; do [ "$a" = "$TARGET" ] && return 0; done; return 1; }

run_one() {
    case "$1" in
        x)
            open_url "X (Twitter)" "https://twitter.com/intent/tweet?text=$(enc "$X_TEXT")" ;;
        bluesky)
            open_url "Bluesky" "https://bsky.app/intent/compose?text=$(enc "$BSKY_TEXT")" ;;
        reddit)
            open_url "Reddit r/macapps" "https://www.reddit.com/r/macapps/submit?title=$(enc "$REDDIT_TITLE")&text=$(enc "$REDDIT_TEXT")" ;;
        hn)
            open_url "Hacker News (Show HN)" "https://news.ycombinator.com/submitlink?u=$(enc "$SITE")&t=$(enc "$HN_TITLE")" ;;
        producthunt)
            echo "==> Product Hunt can't be pre-filled by URL. Opening the submit page;"
            echo "    the ready-to-paste text is in docs/MARKETING.md (Product Hunt section)."
            open "https://www.producthunt.com/posts/new" ; sleep 1 ;;
        *) echo "unknown platform: $1 (use: x bluesky reddit hn producthunt)" ;;
    esac
}

PLATFORMS=(x bluesky reddit hn producthunt)
if [ "$#" -gt 0 ]; then PLATFORMS=("$@"); fi

echo "Site being shared: $SITE"
echo
for p in "${PLATFORMS[@]}"; do run_one "$p"; done
echo
echo "==> Review each post and click Post. That's it."
echo "    Longer write-ups (HN body, Product Hunt) are in docs/MARKETING.md."
