#!/bin/bash
# ════════════════════════════════════════════════════════════
#  MiniRemote 一鍵安裝(在「留在家的那台 Mac」上執行)
#  用法:打開「終端機」,貼上下面這行按 Enter
#      bash ~/Downloads/MiniRemote/setup-mini.command
# ════════════════════════════════════════════════════════════
set -e
GREEN=$'\033[32m'; RED=$'\033[31m'; YEL=$'\033[33m'; BOLD=$'\033[1m'; OFF=$'\033[0m'
say()  { echo "${GREEN}✓${OFF} $*"; }
warn() { echo "${YEL}!${OFF} $*"; }
die()  { echo "${RED}✗ $*${OFF}"; exit 1; }
step() { echo; echo "${BOLD}── $* ──${OFF}"; }

SRC="$(cd "$(dirname "$0")" && pwd)"
DEST="$HOME/MiniRemote"

echo "${BOLD}MiniRemote 安裝程式${OFF}"
echo "把這台 Mac 變成可以從外面遠端操控的主機。"

step "1/6 檢查這台電腦"
VER=$(sw_vers -productVersion); MAJOR=${VER%%.*}
[ "$MAJOR" -ge 14 ] || die "這台是 macOS $VER,需要 macOS 14(Sonoma)以上才能用。"
say "macOS $VER，$(uname -m) 架構，可以"

step "2/6 複製檔案到 $DEST"
if [ "$SRC" != "$DEST" ]; then
  if [ -d "$DEST" ]; then
    warn "已經有舊的 $DEST,先備份成 $DEST.old"
    rm -rf "$DEST.old"; mv "$DEST" "$DEST.old"
    [ -f "$DEST.old/config.json" ] && KEEP="$DEST.old/config.json"
  fi
  mkdir -p "$DEST"
  ditto "$SRC" "$DEST"
  [ -n "$KEEP" ] && cp "$KEEP" "$DEST/config.json" && say "沿用舊的密碼設定"
fi
cd "$DEST"
xattr -dr com.apple.quarantine . 2>/dev/null || true
chmod +x *.sh *.command 2>/dev/null || true
[ -x MiniRemote.app/Contents/MacOS/MiniRemote ] || die "找不到 MiniRemote.app,檔案沒複製完整"
say "檔案就緒"

step "3/6 產生連線密碼"
if [ ! -f config.json ]; then
  PW=$(LC_ALL=C tr -dc 'A-Za-z2-9' </dev/urandom | tr -d 'IlO01' | head -c 10)
  printf '{\n  "port": 8800,\n  "password": "%s",\n  "fps": 30,\n  "bitrateKbps": 12000,\n  "autoBitrate": true,\n  "jpegQuality": 0.6,\n  "maxHeight": 0,\n  "allowLAN": false,\n  "allowedTailscaleLogins": [],\n  "fileRoots": ["~", "/Volumes"],\n  "sessionDays": 30,\n  "idleStopSeconds": 60\n}\n' "$PW" > config.json
  say "新密碼已產生"
else
  say "沿用現有 config.json"
fi
PW=$(python3 -c "import json;print(json.load(open('config.json'))['password'])")

step "4/6 安裝成背景服務(開機自動啟動)"
mkdir -p ~/Library/LaunchAgents ~/Library/Logs
sed "s#__HOME__#$HOME#g" com.john.miniremote.plist > ~/Library/LaunchAgents/com.john.miniremote.plist
launchctl bootout gui/$(id -u)/com.john.miniremote 2>/dev/null || true
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.john.miniremote.plist
sleep 2
say "服務已啟動"

step "5/6 Tailscale(讓你在外面連得回來)"
if ! command -v tailscale >/dev/null 2>&1 && [ ! -x /Applications/Tailscale.app/Contents/MacOS/Tailscale ]; then
  warn "這台還沒裝 Tailscale。"
  echo "   請去 https://tailscale.com/download/mac 下載安裝,用同一個帳號登入,再跑一次這個安裝程式。"
  TS_OK=0
else
  TS="$(command -v tailscale || echo /usr/local/bin/tailscale)"
  if "$TS" ip -4 >/dev/null 2>&1; then
    say "Tailscale 已連線"
    "$TS" serve reset >/dev/null 2>&1 || true
    "$TS" serve --bg "http://127.0.0.1:8800" >/dev/null 2>&1 || true
    TS_OK=1
  else
    warn "Tailscale 有裝但沒登入。請打開 Tailscale App 登入(帳號要跟筆電同一個),再跑一次這個安裝程式。"
    TS_OK=0
  fi
fi

step "6/6 開權限(需要你動手點)"
echo "接下來會自動打開「系統設定」兩次,請照著做:"
echo
echo "  ${BOLD}第一次${OFF} → 螢幕錄製與系統錄音 → 找到 ${BOLD}MiniRemote${OFF} → 開關打開"
echo "  ${BOLD}第二次${OFF} → 輔助使用 → 找到 ${BOLD}MiniRemote${OFF} → 開關打開"
echo
read -r -p "看完了按 Enter 打開第一個設定頁… " _
open "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
read -r -p "開好「螢幕錄製」了嗎?按 Enter 打開第二個設定頁… " _
open "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
read -r -p "兩個都開好了就按 Enter 檢查結果… " _

launchctl kickstart -k gui/$(id -u)/com.john.miniremote 2>/dev/null || true
sleep 3
echo
echo "════════════════════════════════════════════"
LOG=~/Library/Logs/MiniRemote.log
grep -q "螢幕錄製權限:已允許" "$LOG" 2>/dev/null && say "螢幕錄製:已允許" || warn "螢幕錄製:${RED}還沒開${OFF}"
grep -q "輔助使用權限:已允許" "$LOG" 2>/dev/null && say "輔助使用:已允許" || warn "輔助使用:${RED}還沒開${OFF}"
tail -20 "$LOG" 2>/dev/null | grep -q "開始擷取 顯示器" && say "螢幕擷取:正常運作" || warn "螢幕擷取:還沒開始(權限開好後等 30 秒會自動重試)"
echo "════════════════════════════════════════════"
echo
echo "${BOLD}連線密碼:${OFF} $PW"
echo "${BOLD}連線網址:${OFF}"
if [ "$TS_OK" = "1" ]; then
  DNS=$("$TS" status --json 2>/dev/null | python3 -c "import sys,json;print(json.load(sys.stdin)['Self']['DNSName'].rstrip('.'))" 2>/dev/null)
  IP=$("$TS" ip -4 2>/dev/null | head -1)
  [ -n "$DNS" ] && echo "  出門在外(推薦):https://$DNS/"
  [ -n "$IP" ]  && echo "  出門在外(備用):http://$IP:8800/"
fi
echo "  (為了安全,只接受 Tailscale 連線;家裡同網路也請用上面的網址)"
echo
echo "以後查狀態:${BOLD}~/MiniRemote/status.sh${OFF}"
echo "說明書:    ${BOLD}~/MiniRemote/README.md${OFF}"
echo
