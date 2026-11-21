#!/bin/bash
# 建置並組裝 build/Tonefleur.app
# 用法：./Scripts/bundle.sh [release|debug]
#
# release 會建置同時支援 Apple 晶片與 Intel 的 universal 版本（需要安裝 Xcode）；
# 只有 Command Line Tools 時會退回只建置本機的架構。debug 一律只建置本機架構，比較快。
#
# 簽章：鑰匙圈裡若有名為「SoundDeck Dev」的程式碼簽章憑證就用它，否則用 ad-hoc。
# （憑證名稱沿用改名前的 SoundDeck：換憑證會讓已安裝的版本拒絕自動更新，也要重新允許錄音權限。）
# ad-hoc 簽章每次重新建置後，系統可能會要求重新授權「系統音訊錄製」。
# 也可以用環境變數 TONEFLEUR_SIGN_IDENTITY 指定憑證。
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
APP="build/Tonefleur.app"

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
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BIN/Tonefleur" "$APP/Contents/MacOS/Tonefleur"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# 介面翻譯（en.lproj、zh-Hant.lproj）
for LPROJ in Resources/*.lproj; do
    [ -d "$LPROJ" ] && cp -R "$LPROJ" "$APP/Contents/Resources/"
done

# 授權條款：Tonefleur 本身與內含的 Sparkle（MIT 授權要求散布時附上原文）。
mkdir -p "$APP/Contents/Resources/Licenses"
cp LICENSE "$APP/Contents/Resources/Licenses/Tonefleur-LICENSE.txt"
SPARKLE_LICENSE=".build/artifacts/sparkle/Sparkle/LICENSE"
if [ -f "$SPARKLE_LICENSE" ]; then
    cp "$SPARKLE_LICENSE" "$APP/Contents/Resources/Licenses/Sparkle-LICENSE.txt"
fi

# 自動更新用的 Sparkle.framework。執行檔預設只會在自己旁邊找框架，要另外告訴它去 Frameworks 找。
cp -R "$BIN/Sparkle.framework" "$APP/Contents/Frameworks/"
install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/Tonefleur" 2>/dev/null || true

IDENTITY="${TONEFLEUR_SIGN_IDENTITY:-}"
if [ -z "$IDENTITY" ]; then
    if security find-identity -v -p codesigning 2>/dev/null | grep -q '"SoundDeck Dev"'; then
        IDENTITY="SoundDeck Dev"
    else
        IDENTITY="-"
    fi
fi
# 由內而外簽章：Sparkle 內部的元件 → Sparkle.framework → App 本身。
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
for ITEM in "$SPARKLE/XPCServices/Installer.xpc" "$SPARKLE/XPCServices/Downloader.xpc" \
            "$SPARKLE/Autoupdate" "$SPARKLE/Updater.app"; do
    if [ -e "$ITEM" ]; then
        codesign --force --sign "$IDENTITY" --preserve-metadata=entitlements "$ITEM"
    fi
done
codesign --force --sign "$IDENTITY" "$APP/Contents/Frameworks/Sparkle.framework"
codesign --force --sign "$IDENTITY" "$APP"

echo "已產生 ${APP}（架構：$(lipo -archs "$APP/Contents/MacOS/Tonefleur")，簽章：${IDENTITY}）"
