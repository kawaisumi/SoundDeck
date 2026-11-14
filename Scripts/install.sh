#!/bin/bash
# 建置 SoundDeck 並安裝到 /Applications，然後啟動它。
# 「開機時自動啟動」記的是 App 的位置，所以日常使用建議跑安裝好的版本，而不是 build/ 裡的。
set -euo pipefail
cd "$(dirname "$0")/.."

DEST="/Applications/SoundDeck.app"

./Scripts/bundle.sh release

# 先結束正在執行的 SoundDeck（不論是從哪裡啟動的），聲音會暫時恢復成系統原本的輸出。
pkill -x SoundDeck 2>/dev/null || true
sleep 1

rm -rf "$DEST"
cp -R build/SoundDeck.app "$DEST"
open "$DEST"

echo "已安裝到 $DEST 並啟動。"
