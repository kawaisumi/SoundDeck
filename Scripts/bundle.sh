#!/bin/bash
# 建置並組裝 build/SoundDeck.app
# 用法：./Scripts/bundle.sh [release|debug]
#
# 簽章：鑰匙圈裡若有名為「SoundDeck Dev」的程式碼簽章憑證就用它，否則用 ad-hoc。
# ad-hoc 簽章每次重新建置後，系統可能會要求重新授權「系統音訊錄製」。
# 也可以用環境變數 SOUNDDECK_SIGN_IDENTITY 指定憑證。
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
APP="build/SoundDeck.app"

swift build -c "$CONFIG"
BIN="$(swift build -c "$CONFIG" --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/SoundDeck" "$APP/Contents/MacOS/SoundDeck"
cp Resources/Info.plist "$APP/Contents/Info.plist"

IDENTITY="${SOUNDDECK_SIGN_IDENTITY:-}"
if [ -z "$IDENTITY" ]; then
    if security find-identity -v -p codesigning 2>/dev/null | grep -q '"SoundDeck Dev"'; then
        IDENTITY="SoundDeck Dev"
    else
        IDENTITY="-"
    fi
fi
codesign --force --sign "$IDENTITY" "$APP"

echo "已產生 $APP（簽章：$IDENTITY）"
