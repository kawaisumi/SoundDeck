#!/bin/bash
# 建置 Tonefleur 並安裝到 /Applications，然後啟動它。
# 「開機時自動啟動」記的是 App 的位置，所以日常使用建議跑安裝好的版本，而不是 build/ 裡的。
set -euo pipefail
cd "$(dirname "$0")/.."

DEST="/Applications/Tonefleur.app"

./Scripts/bundle.sh release

# 先結束正在執行的 Tonefleur（不論是從哪裡啟動的），聲音會暫時恢復成系統原本的輸出。
pkill -x Tonefleur 2>/dev/null || true
pkill -x SoundDeck 2>/dev/null || true
sleep 1

# 改名前（SoundDeck）安裝的版本：它和 Tonefleur 是同一個 App，留著會有兩份。設定與權限不受影響。
if [ -d "/Applications/SoundDeck.app" ]; then
    rm -rf "/Applications/SoundDeck.app"
    echo "已移除改名前的 /Applications/SoundDeck.app。"
fi

rm -rf "$DEST"
cp -R build/Tonefleur.app "$DEST"
open "$DEST"

echo "已安裝到 $DEST 並啟動。"
