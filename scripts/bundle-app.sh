#!/bin/bash
# Builds "Grammar AI.app" from the SwiftPM executable - no Xcode required.
#
#   scripts/bundle-app.sh             build build/Grammar AI.app (release)
#   scripts/bundle-app.sh --install   also install to /Applications (or
#                                     ~/Applications if that is not writable),
#                                     register with LaunchServices and refresh
#                                     the Services menu
#   scripts/bundle-app.sh --run       install, then (re)launch the app
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="Typfix"
EXECUTABLE="GrammarAI"
BUNDLE_ID="com.kaspidoron.grammarai"
# Signing identity, first match wins:
#   1. $GRAMMARAI_SIGN_IDENTITY
#   2. the first line of .signing-identity (git-ignored, per machine)
#   3. "Grammar AI Local Dev" (created by scripts/setup-signing.sh)
if [ -n "${GRAMMARAI_SIGN_IDENTITY:-}" ]; then
    SIGN_IDENTITY="$GRAMMARAI_SIGN_IDENTITY"
elif [ -f "$ROOT/.signing-identity" ]; then
    SIGN_IDENTITY="$(head -n 1 "$ROOT/.signing-identity")"
else
    SIGN_IDENTITY="Grammar AI Local Dev"
fi
BUILD_DIR="$ROOT/build"
APP="$BUILD_DIR/$APP_NAME.app"
SUPPORT="$ROOT/Sources/GrammarAI/Support"

MODE="${1:-}"

echo "==> Building $EXECUTABLE (release)"
(cd "$ROOT" && swift build -c release --product "$EXECUTABLE")

BIN="$ROOT/.build/release/$EXECUTABLE"
[ -f "$BIN" ] || { echo "error: binary not found at $BIN" >&2; exit 1; }

if [ ! -f "$SUPPORT/AppIcon.icns" ]; then
    echo "==> Generating app icon"
    swift "$ROOT/scripts/make-icon.swift" "$SUPPORT"
fi

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$EXECUTABLE"
cp "$SUPPORT/Info.plist" "$APP/Contents/Info.plist"
cp "$SUPPORT/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# A stable signing identity matters more than it looks: macOS ties the
# Accessibility grant to the app's code signature. An ad-hoc signature
# changes on every build, which silently invalidates the grant (the toggle
# stays ON in System Settings while the app is no longer trusted). A free,
# local self-signed identity keeps it stable. See scripts/setup-signing.sh.
if security find-identity -v -p codesigning 2>/dev/null | grep -q "\"$SIGN_IDENTITY\""; then
    echo "==> Signing with '$SIGN_IDENTITY'"
    codesign --force --options runtime --sign "$SIGN_IDENTITY" --identifier "$BUNDLE_ID" "$APP"
else
    echo "note: no '$SIGN_IDENTITY' identity found - using ad-hoc signing."
    echo "      The Accessibility permission will need re-granting after each rebuild."
    echo "      Run scripts/setup-signing.sh once to fix that."
    # Hardened runtime here too: without it any process could inject a library
    # into an app that holds the Accessibility permission.
    codesign --force --options runtime --sign - --identifier "$BUNDLE_ID" "$APP"
fi
codesign --verify --strict "$APP"

echo "==> Built $APP"

if [ "$MODE" = "--install" ] || [ "$MODE" = "--run" ]; then
    if [ -w "/Applications" ]; then DEST_DIR="/Applications"; else DEST_DIR="$HOME/Applications"; fi
    DEST="$DEST_DIR/$APP_NAME.app"
    mkdir -p "$DEST_DIR"

    # Quit a running copy first so the binary is not replaced under it.
    if pgrep -x "$EXECUTABLE" >/dev/null 2>&1; then
        echo "==> Quitting the running copy"
        osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
        for _ in 1 2 3 4 5 6 7 8 9 10; do
            pgrep -x "$EXECUTABLE" >/dev/null 2>&1 || break
            sleep 0.3
        done
        pkill -x "$EXECUTABLE" >/dev/null 2>&1 || true
    fi

    echo "==> Installing to $DEST"
    rm -rf "$DEST"
    # Clean up the pre-rename bundle if it is still around.
    rm -rf "$DEST_DIR/Grammar AI.app"
    cp -R "$APP" "$DEST"

    LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
    "$LSREGISTER" -f "$DEST" || true
    # Refresh the Services cache so "Correct with Grammar AI" shows up in
    # right-click menus without logging out.
    /System/Library/CoreServices/pbs -update || true

    echo "==> Installed."
    if [ "$MODE" = "--run" ]; then
        echo "==> Launching"
        open "$DEST"
    fi
fi
