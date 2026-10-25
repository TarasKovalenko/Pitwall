#!/usr/bin/env bash
# Regenerates every icon artifact from scripts/make-icon.swift:
#   Resources/Assets.xcassets/AppIcon.appiconset  (Xcode build)
#   Resources/AppIcon.icns                        (scripts/build-app.sh)
set -euo pipefail
cd "$(dirname "$0")/.."

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
MASTER="$WORK/icon-1024.png"
swift scripts/make-icon.swift "$MASTER"

SET="Resources/Assets.xcassets/AppIcon.appiconset"
ICONSET="$WORK/AppIcon.iconset"
mkdir -p "$SET" "$ICONSET"

images=""
for pt in 16 32 128 256 512; do
  for scale in 1 2; do
    px=$((pt * scale))
    suffix=""
    if [ "$scale" = 2 ]; then suffix="@2x"; fi
    name="icon_${pt}x${pt}${suffix}.png"
    sips -z $px $px "$MASTER" --out "$SET/$name" >/dev/null
    command cp -f "$SET/$name" "$ICONSET/$name"
    images+="{\"idiom\":\"mac\",\"size\":\"${pt}x${pt}\",\"scale\":\"${scale}x\",\"filename\":\"$name\"},"
  done
done
printf '{"images":[%s],"info":{"author":"xcode","version":1}}\n' "${images%,}" | python3 -m json.tool > "$SET/Contents.json"
printf '{"info":{"author":"xcode","version":1}}\n' > Resources/Assets.xcassets/Contents.json

iconutil -c icns "$ICONSET" -o Resources/AppIcon.icns
echo "Icon assets updated"
