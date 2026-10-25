#!/usr/bin/env bash
# Installs the latest Pitwall release:
#   curl -fsSL https://raw.githubusercontent.com/TarasKovalenko/Pitwall/main/scripts/install.sh | bash
# Pin a version with PITWALL_VERSION=v0.2.0, pick a folder with PITWALL_DIR=~/Applications.
set -euo pipefail

REPO="TarasKovalenko/Pitwall"
VERSION="${PITWALL_VERSION:-latest}"

if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "Pitwall runs on macOS only." >&2
    exit 1
fi
if [[ "$(uname -m)" != "arm64" ]]; then
    echo "Pitwall release builds are for Apple silicon only." >&2
    exit 1
fi

if [[ -n "${PITWALL_DIR:-}" ]]; then
    DEST="$PITWALL_DIR"
elif [[ -w /Applications ]]; then
    DEST="/Applications"
else
    DEST="$HOME/Applications"
fi

if [[ "$VERSION" == "latest" ]]; then
    BASE="https://github.com/$REPO/releases/latest/download"
else
    BASE="https://github.com/$REPO/releases/download/$VERSION"
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "Downloading Pitwall ($VERSION)…"
curl -fsSL "$BASE/Pitwall.zip" -o "$TMP/Pitwall.zip"
curl -fsSL "$BASE/Pitwall.zip.sha256" -o "$TMP/Pitwall.zip.sha256"

echo "Verifying checksum…"
(cd "$TMP" && shasum -a 256 -c Pitwall.zip.sha256 >/dev/null)

ditto -x -k "$TMP/Pitwall.zip" "$TMP"
codesign --verify --strict "$TMP/Pitwall.app"

if pgrep -xq Pitwall; then
    echo "Quitting running Pitwall…"
    osascript -e 'quit app id "dev.pitwall.Pitwall"' >/dev/null 2>&1 || pkill -x Pitwall || true
    sleep 1
fi

mkdir -p "$DEST"
rm -rf "$DEST/Pitwall.app"
ditto "$TMP/Pitwall.app" "$DEST/Pitwall.app"
# The release is ad-hoc signed, not notarized. Clear quarantine so
# Gatekeeper doesn't refuse to open it.
xattr -dr com.apple.quarantine "$DEST/Pitwall.app" 2>/dev/null || true

echo "Installed $DEST/Pitwall.app"
open "$DEST/Pitwall.app"
