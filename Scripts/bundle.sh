#!/bin/bash
# 建置並組裝 build/SoundDeck.app
# 用法：./Scripts/bundle.sh [release|debug]
#
# release 會建置同時支援 Apple 晶片與 Intel 的 universal 版本（需要安裝 Xcode）；
# 只有 Command Line Tools 時會退回只建置本機的架構。debug 一律只建置本機架構，比較快。
#
# 簽章：鑰匙圈裡若有名為「SoundDeck Dev」的程式碼簽章憑證就用它，否則用 ad-hoc。
# ad-hoc 簽章每次重新建置後，系統可能會要求重新授權「系統音訊錄製」。
# 也可以用環境變數 SOUNDDECK_SIGN_IDENTITY 指定憑證。
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
APP="build/SoundDeck.app"

ARCH_FLAGS=()
if [ "$CONFIG" = "release" ]; then
    ARCH_FLAGS=(--arch arm64 --arch x86_64)
    if ! swift build -c "$CONFIG" "${ARCH_FLAGS[@]}"; then
        echo "無法建置 universal 版本（通常是因為沒有安裝 Xcode），改為只建置本機架構。" >&2
        ARCH_FLAGS=()
    fi
fi
if [ ${#ARCH_FLAGS[@]} -eq 0 ]; then
    swift build -c "$CONFIG"
fi
BIN="$(swift build -c "$CONFIG" ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"} --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/SoundDeck" "$APP/Contents/MacOS/SoundDeck"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

IDENTITY="${SOUNDDECK_SIGN_IDENTITY:-}"
if [ -z "$IDENTITY" ]; then
    if security find-identity -v -p codesigning 2>/dev/null | grep -q '"SoundDeck Dev"'; then
        IDENTITY="SoundDeck Dev"
    else
        IDENTITY="-"
    fi
fi
codesign --force --sign "$IDENTITY" "$APP"

echo "已產生 ${APP}（架構：$(lipo -archs "$APP/Contents/MacOS/SoundDeck")，簽章：${IDENTITY}）"
