#!/bin/bash
cd "$(dirname "$0")"
PORT=$(python3 -c "import json;print(json.load(open('config.json'))['port'])" 2>/dev/null || echo 8800)
PW=$(python3 -c "import json;print(json.load(open('config.json'))['password'])" 2>/dev/null)
echo "──────── MiniRemote 狀態 ────────"
if launchctl print gui/$(id -u)/com.john.miniremote 2>/dev/null | grep -q "state = running"; then
  echo "服務:🟢 執行中"
else
  echo "服務:🔴 沒有在跑(執行 ./start.sh)"
fi
if curl -s -m 2 "http://127.0.0.1:$PORT/health" | grep -q ok; then echo "網頁伺服器:🟢 port $PORT 正常"; else echo "網頁伺服器:🔴 port $PORT 沒有回應"; fi
echo "密碼:$PW"
N=$(python3 -c "import json;print(len(json.load(open('sessions.json'))))" 2>/dev/null || echo 0); echo "已登入裝置(token):$N 個(./logout-all.sh 可全部登出)"
echo
echo "可用網址:"
LAN=$(python3 -c "import json;print(str(json.load(open('config.json')).get('allowLAN',False)).lower())" 2>/dev/null)
if [ "$LAN" = "true" ]; then
  for ip in $(ipconfig getifaddr en0 2>/dev/null) $(ipconfig getifaddr en1 2>/dev/null); do echo "  家裡同網路:http://$ip:$PORT/   (JPEG 模式;allowLAN 已開)"; done
else
  echo "  (只接受 Tailscale 連線;要開放家裡區網請在 config.json 設 allowLAN: true)"
fi
if command -v tailscale >/dev/null 2>&1; then
  TSIP=$(tailscale ip -4 2>/dev/null | head -1)
  if [ -n "$TSIP" ]; then
    echo "  Tailscale:  http://$TSIP:$PORT/   (JPEG 模式,外出可用)"
    DNS=$(tailscale status --json 2>/dev/null | python3 -c "import sys,json;print(json.load(sys.stdin)['Self']['DNSName'].rstrip('.'))" 2>/dev/null)
    if tailscale serve status 2>/dev/null | grep -q "$PORT"; then
      echo "  Tailscale HTTPS:https://$DNS/   (H.264 模式,推薦)"
    else
      echo "  (執行 ./tailscale-https.sh 可開啟 https://$DNS/,才能用省流量的 H.264)"
    fi
  else
    echo "  Tailscale:  🔴 沒連線 → 打開 Tailscale App 登入"
  fi
else
  echo "  (沒安裝 Tailscale,外出無法連回來)"
fi
echo
echo "最近的紀錄(~/Library/Logs/MiniRemote.log):"
tail -n 6 ~/Library/Logs/MiniRemote.log 2>/dev/null | sed 's/^/  /'
