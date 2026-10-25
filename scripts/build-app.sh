#!/usr/bin/env bash
# Builds build/Pitwall.app from the Swift package.
#   scripts/build-app.sh            release build, ad-hoc signed
#   SIGN_ID="Developer ID Application: …" scripts/build-app.sh   real signing
set -euo pipefail

cd "$(dirname "$0")/.."
CONFIG="${CONFIG:-release}"
SIGN_ID="${SIGN_ID:--}"
APP="build/Pitwall.app"

swift build -c "$CONFIG"
BIN="$(swift build -c "$CONFIG" --show-bin-path)/pitwall-app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Pitwall"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# Hardened runtime on, no extra entitlements: the app needs network and
# Keychain only, both available by default outside the sandbox.
codesign --force --options runtime --timestamp=none --sign "$SIGN_ID" "$APP"
codesign --verify --strict "$APP"
echo "Built $APP"
