#!/bin/bash
# Runs the automated test suite.
#
#   scripts/test.sh                 offline unit tests (no network, no Claude)
#   scripts/test.sh --live          also run the live correction-quality tests
#                                   against your real Claude setup (sends the
#                                   fixed sample sentences in the test file)
#   scripts/test.sh --filter Name   pass-through to `swift test --filter`
#
# The tests use Swift Testing. On a Mac with only the Command Line Tools
# (no Xcode.app) Testing.framework exists but is not on the default search
# path, so it is added here. With full Xcode, plain `swift test` also works.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

ARGS=()
while [ $# -gt 0 ]; do
    case "$1" in
        --live) export GRAMMARAI_LIVE_TESTS=1 ;;
        *) ARGS+=("$1") ;;
    esac
    shift
done

CLT_FRAMEWORKS="/Library/Developer/CommandLineTools/Library/Developer/Frameworks"
CLT_TESTLIB="/Library/Developer/CommandLineTools/Library/Developer/usr/lib"

FLAGS=()
if ! xcode-select -p 2>/dev/null | grep -q "Xcode.*\.app" && [ -d "$CLT_FRAMEWORKS/Testing.framework" ]; then
    FLAGS+=(
        -Xswiftc "-F$CLT_FRAMEWORKS"
        -Xlinker -rpath -Xlinker "$CLT_FRAMEWORKS"
        -Xlinker -rpath -Xlinker "$CLT_TESTLIB"
    )
fi

echo "==> swift test"
swift test "${FLAGS[@]+"${FLAGS[@]}"}" "${ARGS[@]+"${ARGS[@]}"}"
