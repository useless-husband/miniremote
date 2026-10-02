#!/bin/bash
# 安裝成「登入就自動啟動、掛掉會自動重開」的背景服務(LaunchAgent)
set -e
cd "$(dirname "$0")"
DIR="$PWD"
if [ "$DIR" != "$HOME/MiniRemote" ]; then
  echo "✗ 請把整個資料夾放在 ~/MiniRemote 再執行(目前在 $DIR)"; exit 1
fi
[ -d MiniRemote.app ] || ./build.sh
xattr -dr com.apple.quarantine MiniRemote.app 2>/dev/null || true
if [ ! -f config.json ]; then
  PW=$(LC_ALL=C tr -dc 'A-Za-z2-9' </dev/urandom | tr -d 'IlO01' | head -c 10)
  printf '{\n  "port": 8800,\n  "password": "%s",\n  "fps": 30,\n  "bitrateKbps": 12000,\n  "autoBitrate": true,\n  "jpegQuality": 0.6,\n  "maxHeight": 0,\n  "allowLAN": false,\n  "allowedTailscaleLogins": [],\n  "fileRoots": ["~", "/Volumes"],\n  "sessionDays": 30,\n  "idleStopSeconds": 60\n}\n' "$PW" > config.json
  echo "✓ 已產生新密碼,寫在 config.json"
fi
mkdir -p ~/Library/LaunchAgents ~/Library/Logs
sed "s#__HOME__#$HOME#g" com.john.miniremote.plist > ~/Library/LaunchAgents/com.john.miniremote.plist
launchctl bootout gui/$(id -u)/com.john.miniremote 2>/dev/null || true
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.john.miniremote.plist
echo "✓ 服務已安裝並啟動"
sleep 1
./status.sh
