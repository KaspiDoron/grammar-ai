#!/bin/bash
# Builds the Typfix editor extension and installs it into Cursor and/or
# VS Code - whichever are on this Mac. One command, nothing to figure out.
#
#   scripts/install-editor-extension.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
EXT="$ROOT/editor-extension"

echo "==> Building the Typfix extension"
cd "$EXT"
if [ ! -d node_modules ]; then
    npm install --no-audit --no-fund
fi
npm run build -- --minify >/dev/null
npx --yes @vscode/vsce@latest package --no-dependencies --skip-license -o grammar-ai.vsix >/dev/null
echo "    packaged grammar-ai.vsix"

VSIX="$EXT/grammar-ai.vsix"
installed=0

install_into() {
    local name="$1" bin="$2"
    if [ -x "$bin" ] || command -v "$bin" >/dev/null 2>&1; then
        echo "==> Installing into $name"
        "$bin" --install-extension "$VSIX" --force >/dev/null 2>&1 && {
            echo "    done"
            installed=1
        } || echo "    (couldn't install into $name)"
    fi
}

install_into "Cursor" "/Applications/Cursor.app/Contents/Resources/app/bin/cursor"
install_into "VS Code" "/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code"
# Fall back to whatever `cursor` / `code` are on PATH.
command -v cursor >/dev/null 2>&1 && install_into "Cursor (PATH)" "$(command -v cursor)"
command -v code   >/dev/null 2>&1 && install_into "VS Code (PATH)" "$(command -v code)"

echo
if [ "$installed" = "1" ]; then
    cat <<'DONE'
==> Typfix is installed. To use it:

    1. Fully quit and reopen Cursor / VS Code (so the extension loads).
    2. Open any file, select some text.
    3. Press  Cmd+Shift+G  (or run "Typfix: Fix Grammar in Selection"
       from the Command Palette:  Cmd+Shift+P  then type "Typfix").

    For the best (free, private) experience, install Ollama from ollama.com
    and run:  ollama pull qwen3:1.7b

    Find its settings under:  Settings  ->  search "Typfix".
DONE
else
    echo "==> No Cursor or VS Code found to install into."
    echo "    Install one, or run: <editor> --install-extension \"$VSIX\""
fi
