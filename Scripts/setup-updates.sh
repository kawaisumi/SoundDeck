#!/bin/bash
# 設定自動更新：建立（或讀出已有的）EdDSA 簽章金鑰，並把公鑰寫進 Resources/Info.plist。
# 只需要在這台電腦上執行一次。
#
# 私鑰存在登入鑰匙圈裡，之後每次用 Scripts/release.sh 發佈時用來替更新檔簽章；
# 已安裝的 SoundDeck 只會接受用同一把私鑰簽過的更新。
# **私鑰遺失就再也無法推送更新給已安裝的使用者**，請務必依照最後的提示備份。
set -euo pipefail
cd "$(dirname "$0")/.."

BIN=".build/artifacts/sparkle/Sparkle/bin"
if [ ! -x "$BIN/generate_keys" ]; then
    swift package resolve
fi

# 已經有金鑰時只會顯示既有的公鑰，不會覆蓋。
"$BIN/generate_keys"
PUBLIC_KEY="$("$BIN/generate_keys" -p)"

/usr/libexec/PlistBuddy -c "Set :SUPublicEDKey ${PUBLIC_KEY}" Resources/Info.plist

echo
echo "已把公鑰寫入 Resources/Info.plist。重新建置後，自動更新就會啟用。"
echo
echo "請備份私鑰（存到密碼管理器或隨身碟，不要放進這個 repo）："
echo "  ${BIN}/generate_keys -x ~/Desktop/SoundDeck-更新私鑰.txt"
echo "換電腦時用這個指令匯回："
echo "  ${BIN}/generate_keys -f <私鑰檔案>"
