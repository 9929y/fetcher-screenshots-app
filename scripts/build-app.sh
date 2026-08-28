#!/bin/bash
# Assembles Fetcher.app. No Xcode required — SPM builds the binary, and the
# bundle is assembled and ad-hoc signed with the command line tools.
#
# The bundle is not cosmetic: Screen Recording permission is granted to a
# *signed bundle identity*, so a bare executable can never hold the grant.
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
APP="$ROOT/dist/Fetcher.app"
CONFIG="${1:-release}"

echo "==> building ($CONFIG)"
swift build -c "$CONFIG"
BIN="$ROOT/.build/$CONFIG/Fetcher"

echo "==> assembling bundle"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Fetcher"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# Ad-hoc signature. Enough for TCC to have a stable identity to attach the
# Screen Recording grant to, but the designated requirement includes the code
# hash — so a rebuild can invalidate the grant and need a re-approve. A real
# Developer ID certificate makes the grant survive rebuilds; see README.
echo "==> signing (ad-hoc)"
codesign --force --sign - --identifier com.fetcher.Fetcher "$APP" 2>&1 | sed 's/^/    /'
codesign --verify --verbose=1 "$APP" 2>&1 | sed 's/^/    /'

echo "==> $APP"
