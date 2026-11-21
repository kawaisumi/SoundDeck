#!/bin/bash
# 設定 Tonefleur 的版本號，並把內部建置編號加一。
# 用法：./Scripts/set-version.sh 1.2.0
#
# 版本號採「主版本.次版本.修正版本」：
#   修正 bug → 1.0.0 → 1.0.1；新增功能 → 1.0.1 → 1.1.0；大幅改版 → 1.1.0 → 2.0.0
set -euo pipefail
cd "$(dirname "$0")/.."

PLIST="Resources/Info.plist"
VERSION="${1:-}"

if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    CURRENT="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST")"
    echo "用法：./Scripts/set-version.sh <版本號>，例如 ./Scripts/set-version.sh 1.2.0" >&2
    echo "目前的版本是 ${CURRENT}。" >&2
    exit 1
fi

BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$PLIST")"
NEXT_BUILD=$((BUILD + 1))

/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${VERSION}" "$PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${NEXT_BUILD}" "$PLIST"

echo "版本已設為 ${VERSION}（建置編號 ${NEXT_BUILD}）。"
