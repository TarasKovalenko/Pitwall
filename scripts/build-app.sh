#!/usr/bin/env bash
# Builds build/Pitwall.app from the Swift package.
#   scripts/build-app.sh            release build, ad-hoc signed
#   SIGN_ID="Developer ID Application: …" scripts/build-app.sh   real signing
#   VERSION=1.2.0 BUILD_NUMBER=42 scripts/build-app.sh            stamp Info.plist
#                                   (VERSION defaults to the latest git tag)
#   ARCHS="arm64 x86_64" scripts/build-app.sh                    universal binary
set -euo pipefail

cd "$(dirname "$0")/.."
CONFIG="${CONFIG:-release}"
SIGN_ID="${SIGN_ID:--}"
ARCHS="${ARCHS:-}"
APP="build/Pitwall.app"

# SwiftPM caches absolute paths in .build. If the checkout was moved or
# renamed, it warns about "stale files outside the allowed root paths" on
# every build, so start clean whenever .build was made somewhere else.
ROOT_MARKER=".build/.pitwall-root"
if [[ -d .build && "$(cat "$ROOT_MARKER" 2>/dev/null)" != "$PWD" ]]; then
    echo "Removing .build created at a different path"
    rm -rf .build
fi
mkdir -p .build
echo "$PWD" > "$ROOT_MARKER"

BUILD_ARGS=(-c "$CONFIG")
for arch in $ARCHS; do BUILD_ARGS+=(--arch "$arch"); done

# Only the app product: the test support target isn't part of a release.
swift build "${BUILD_ARGS[@]}" --product pitwall-app
BIN="$(swift build "${BUILD_ARGS[@]}" --show-bin-path)/pitwall-app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Pitwall"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

PLIST="$APP/Contents/Info.plist"
if [[ -z "${VERSION:-}" ]]; then
    VERSION="$(git describe --tags --abbrev=0 --match 'v*' 2>/dev/null || true)"
    VERSION="${VERSION#v}"
fi
if [[ -n "${VERSION:-}" ]]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$PLIST"
fi
if [[ -n "${BUILD_NUMBER:-}" ]]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$PLIST"
fi

# Hardened runtime on, no extra entitlements: the app needs network and
# its own Application Support folder, both available outside the sandbox.
codesign --force --options runtime --timestamp=none --sign "$SIGN_ID" "$APP"
codesign --verify --strict "$APP"
echo "Built $APP"
