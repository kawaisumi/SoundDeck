#!/bin/bash
# 重新產生 App 圖示 Resources/AppIcon.icns。只有改了 make-icon.swift 的圖案時才需要執行。
set -euo pipefail
cd "$(dirname "$0")/.."

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

swift Scripts/make-icon.swift "$WORK/icon-1024.png"

SET="$WORK/AppIcon.iconset"
mkdir "$SET"
for SIZE in 16 32 128 256 512; do
    sips -z "$SIZE" "$SIZE" "$WORK/icon-1024.png" --out "$SET/icon_${SIZE}x${SIZE}.png" >/dev/null
    DOUBLE=$((SIZE * 2))
    sips -z "$DOUBLE" "$DOUBLE" "$WORK/icon-1024.png" --out "$SET/icon_${SIZE}x${SIZE}@2x.png" >/dev/null
done
iconutil -c icns "$SET" -o Resources/AppIcon.icns

# 另外留一張預覽圖，方便不用打開 .icns 就能看到圖案。
cp "$WORK/icon-1024.png" Resources/AppIcon-preview.png

echo "已產生 Resources/AppIcon.icns"
