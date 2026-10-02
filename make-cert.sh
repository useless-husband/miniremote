#!/bin/bash
# 建立一張自簽的程式碼簽章憑證,放在獨立 keychain 裡(不會跳視窗問密碼)。
# 用固定憑證簽章的好處:重新編譯後,「螢幕錄製」「輔助使用」權限不用重新打開。
set -e
IDENTITY="MiniRemote Dev"
KEYCHAIN="$HOME/Library/Keychains/miniremote-build.keychain-db"
KCPASS=miniremote
TMP=$(mktemp -d)
if [ -f "$KEYCHAIN" ] && security find-identity -p codesigning "$KEYCHAIN" 2>/dev/null | grep -q "$IDENTITY"; then
  echo "✓ 憑證已存在"; exit 0
fi
cat > "$TMP/ext.cnf" <<CNF
[req]
distinguished_name=dn
x509_extensions=ext
prompt=no
[dn]
CN=$IDENTITY
[ext]
keyUsage=critical,digitalSignature
extendedKeyUsage=critical,codeSigning
basicConstraints=critical,CA:false
CNF
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -config "$TMP/ext.cnf" 2>/dev/null
openssl pkcs12 -export -legacy -out "$TMP/dev.p12" -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -passout pass:x 2>/dev/null \
  || openssl pkcs12 -export -out "$TMP/dev.p12" -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -passout pass:x
[ -f "$KEYCHAIN" ] || security create-keychain -p "$KCPASS" "$KEYCHAIN"
security set-keychain-settings "$KEYCHAIN"   # 不自動鎖定
security unlock-keychain -p "$KCPASS" "$KEYCHAIN"
security import "$TMP/dev.p12" -k "$KEYCHAIN" -P x -T /usr/bin/codesign -T /usr/bin/security >/dev/null
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KCPASS" "$KEYCHAIN" >/dev/null
# 加進搜尋清單,codesign 才找得到
security list-keychains -d user -s "$KEYCHAIN" "$HOME/Library/Keychains/login.keychain-db"
rm -rf "$TMP"
security find-identity -p codesigning "$KEYCHAIN" | grep -q "$IDENTITY" && echo "✓ 憑證建立完成"
