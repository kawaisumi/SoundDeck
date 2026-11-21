#!/bin/bash
# 建置 Tonefleur 並打包成 .dmg：打開後把 Tonefleur 拖到「應用程式」即可安裝。
# 產出：build/Tonefleur-<版本>.dmg
set -euo pipefail
cd "$(dirname "$0")/.."

./Scripts/bundle.sh release

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
DMG="build/Tonefleur-${VERSION}.dmg"

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

cp -R build/Tonefleur.app "$STAGE/Tonefleur.app"
# 放一個指向「應用程式」的捷徑，讓使用者可以直接拖過去。
ln -s /Applications "$STAGE/Applications"

rm -f "$DMG"
hdiutil create -volname "Tonefleur" -srcfolder "$STAGE" -format UDZO -quiet "$DMG"

echo "已產生 $DMG"
