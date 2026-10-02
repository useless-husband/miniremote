#!/bin/bash
# 編譯並打包成 MiniRemote.app(只需要 Xcode Command Line Tools,不用完整 Xcode)
# 預設編出 Intel + Apple 晶片都能跑的通用版。加上 --fast 只編目前這台的架構(比較快)。
set -e
cd "$(dirname "$0")"
SDK=$(xcrun --show-sdk-path)
SRC=$(ls Sources/MiniRemote/*.swift)
OUT=.build/bin
mkdir -p "$OUT"

if [ "$1" = "--fast" ]; then
  ARCHS=$(uname -m)
else
  ARCHS="arm64 x86_64"
fi

for A in $ARCHS; do
  echo "▶ 編譯 $A …"
  swiftc -O -target $A-apple-macos14.0 -sdk "$SDK" -o "$OUT/MiniRemote-$A" $SRC
done

if [ "$ARCHS" = "arm64 x86_64" ]; then
  lipo -create -output "$OUT/MiniRemote" "$OUT/MiniRemote-arm64" "$OUT/MiniRemote-x86_64"
else
  cp "$OUT/MiniRemote-$ARCHS" "$OUT/MiniRemote"
fi
echo "▶ 架構:$(lipo -archs "$OUT/MiniRemote")"

APP=MiniRemote.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$OUT/MiniRemote" "$APP/Contents/MacOS/MiniRemote"
cp Client/index.html "$APP/Contents/Resources/index.html"
cp Info.plist "$APP/Contents/Info.plist"

# 簽章:優先用自簽的固定憑證(重新編譯後不用重開權限),沒有就用 ad-hoc
IDENTITY="MiniRemote Dev"
KEYCHAIN="$HOME/Library/Keychains/miniremote-build.keychain-db"
SHA=$( [ -f "$KEYCHAIN" ] && security find-identity -p codesigning "$KEYCHAIN" 2>/dev/null | grep "$IDENTITY" | head -1 | awk '{print $2}' )
if [ -n "$SHA" ]; then
  security unlock-keychain -p miniremote "$KEYCHAIN" 2>/dev/null || true
  codesign --force --deep --keychain "$KEYCHAIN" --sign "$SHA" "$APP" 2>&1 | grep -v -E "unable to build chain|replacing existing" || true
  echo "✓ 已用固定憑證簽章(重新編譯後權限不用重開)"
else
  codesign --force --deep --sign - "$APP"
  echo "✓ 已用 ad-hoc 簽章(執行 ./make-cert.sh 可建立固定憑證)"
fi
echo "✓ 完成:$PWD/$APP"
