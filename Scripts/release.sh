#!/bin/bash
# 準備發佈目前版本：打包 dmg、替它簽章，並在 appcast.xml 加上這個版本的更新資訊。
# 用法：./Scripts/release.sh
#
# 先用 ./Scripts/set-version.sh 設定好版本號再執行。腳本不會上傳任何東西，
# 最後會列出要手動完成的步驟（建立 GitHub Release、上傳 dmg、推送 appcast.xml）。
#
# GitHub repo 預設是 kawaisumi/SoundDeck，可以用環境變數 SOUNDDECK_GITHUB_REPO 改成別的。
set -euo pipefail
cd "$(dirname "$0")/.."

REPO="${SOUNDDECK_GITHUB_REPO:-kawaisumi/SoundDeck}"
PLIST="Resources/Info.plist"
BIN=".build/artifacts/sparkle/Sparkle/bin"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST")"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$PLIST")"
MIN_SYSTEM="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$PLIST")"
PUBLIC_KEY="$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$PLIST" 2>/dev/null || true)"

if [ -z "$PUBLIC_KEY" ]; then
    echo "還沒有設定自動更新的金鑰，請先執行 ./Scripts/setup-updates.sh。" >&2
    exit 1
fi
if grep -q "<sparkle:version>${BUILD}</sparkle:version>" appcast.xml; then
    echo "appcast.xml 裡已經有建置編號 ${BUILD}。請先用 ./Scripts/set-version.sh 設定新的版本號。" >&2
    exit 1
fi

./Scripts/make-dmg.sh

DMG="build/SoundDeck-${VERSION}.dmg"
# 輸出像：sparkle:edSignature="..." length="12345"
SIGNATURE_ATTRIBUTES="$("$BIN/sign_update" "$DMG")"
URL="https://github.com/${REPO}/releases/download/v${VERSION}/SoundDeck-${VERSION}.dmg"
NOTES="https://github.com/${REPO}/releases/tag/v${VERSION}"

VERSION="$VERSION" BUILD="$BUILD" MIN_SYSTEM="$MIN_SYSTEM" URL="$URL" NOTES="$NOTES" \
SIGNATURE_ATTRIBUTES="$SIGNATURE_ATTRIBUTES" python3 - <<'PYTHON'
import os
from email.utils import formatdate

env = os.environ
item = f"""        <item>
            <title>SoundDeck {env['VERSION']}</title>
            <pubDate>{formatdate(localtime=False, usegmt=True)}</pubDate>
            <sparkle:version>{env['BUILD']}</sparkle:version>
            <sparkle:shortVersionString>{env['VERSION']}</sparkle:shortVersionString>
            <sparkle:minimumSystemVersion>{env['MIN_SYSTEM']}</sparkle:minimumSystemVersion>
            <sparkle:releaseNotesLink>{env['NOTES']}</sparkle:releaseNotesLink>
            <enclosure url="{env['URL']}" type="application/octet-stream" {env['SIGNATURE_ATTRIBUTES'].strip()} />
        </item>
"""
with open("appcast.xml", encoding="utf-8") as f:
    text = f.read()
marker = "    </channel>"
# 新版本放在最前面。
anchor = text.find("        <item>")
if anchor == -1:
    anchor = text.index(marker)
text = text[:anchor] + item + text[anchor:]
with open("appcast.xml", "w", encoding="utf-8") as f:
    f.write(text)
PYTHON

SHA256="$(shasum -a 256 "$DMG" | cut -d' ' -f1)"

cat <<STEPS

已產生 ${DMG}，並在 appcast.xml 加入 ${VERSION}（建置 ${BUILD}）。

接下來請依序完成（順序很重要：要先讓 dmg 可以下載，再推送 appcast.xml，
否則已安裝的人會收到更新通知卻下載失敗）：

  1. commit 並加上 tag：
       git add -A && git commit -m "發佈 ${VERSION}" && git tag v${VERSION}
  2. 推送 tag：
       git push origin v${VERSION}
  3. 到 https://github.com/${REPO}/releases/new 選 tag v${VERSION}，
     上傳 ${DMG}，說明裡貼上校驗碼：
       SHA-256: ${SHA256}
  4. 發佈 Release 之後，推送 main（appcast.xml 在這時才生效）：
       git push origin main
STEPS
