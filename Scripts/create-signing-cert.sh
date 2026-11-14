#!/bin/bash
# 建立一張自簽的程式碼簽章憑證「SoundDeck Dev」並放進登入鑰匙圈。
#
# 為什麼需要：系統的錄音權限綁定程式簽章。ad-hoc 簽章每次建置都不同，所以每次都會重新詢問；
# 用固定的憑證簽章後，授權一次就能一直沿用。
#
# 這張憑證只存在這台 Mac 上。腳本會把它設為「僅程式碼簽章用途」受信任（codesign 只接受受信任的憑證），
# 這一步系統會跳出視窗要求輸入登入密碼。它不會被信任用於網站、郵件等其他用途。
# 要移除：打開「鑰匙圈存取」，在登入鑰匙圈刪除名為 SoundDeck Dev 的憑證與專用密鑰。
# （鑰匙圈存取位於 /System/Library/CoreServices/Applications/，或用 Spotlight 搜尋。）
#
# 用法：./Scripts/create-signing-cert.sh [鑰匙圈路徑]   （預設為登入鑰匙圈）
set -euo pipefail

NAME="SoundDeck Dev"
KEYCHAIN="${1:-$HOME/Library/Keychains/login.keychain-db}"

if security find-certificate -c "${NAME}" "$KEYCHAIN" >/dev/null 2>&1; then
    echo "「${NAME}」已經存在於 $KEYCHAIN，不需要再建立。"
    exit 0
fi

# 一律用系統內建的 openssl：Homebrew 的 OpenSSL 3 產生的 .p12 格式，鑰匙圈讀不了。
OPENSSL=/usr/bin/openssl

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# 只在匯入的這一瞬間使用的一次性密碼，用來保護暫存的 .p12 檔。
P12_PASS="$("$OPENSSL" rand -hex 16)"

"$OPENSSL" req -x509 -newkey rsa:2048 -nodes \
    -keyout "$WORK/key.pem" -out "$WORK/cert.pem" \
    -days 3650 -subj "/CN=${NAME}" \
    -addext "basicConstraints=critical,CA:false" \
    -addext "keyUsage=critical,digitalSignature" \
    -addext "extendedKeyUsage=critical,codeSigning" 2>/dev/null

"$OPENSSL" pkcs12 -export -name "${NAME}" \
    -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
    -out "$WORK/identity.p12" -passout "pass:$P12_PASS"

# -T 讓 codesign 可以使用這把密鑰。
security import "$WORK/identity.p12" -k "$KEYCHAIN" -P "$P12_PASS" -T /usr/bin/codesign >/dev/null

# codesign 只會使用受信任的憑證。只針對「程式碼簽章」這個用途設為信任，寫入的是使用者層級的設定。
echo "接下來系統會要求輸入登入密碼，以便把這張憑證設為可用於程式碼簽章。"
security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$WORK/cert.pem"

if ! security find-identity -v -p codesigning "$KEYCHAIN" | grep -q "\"${NAME}\""; then
    echo "憑證已匯入，但系統仍不認為它可用於簽章。請把上面的訊息回報給開發者。" >&2
    exit 1
fi

echo "已建立「${NAME}」。之後 ./Scripts/bundle.sh 會自動用它簽章。"
echo "第一次簽章時系統可能會問是否允許 codesign 使用這把密鑰，請輸入登入密碼並選「永遠允許」。"
