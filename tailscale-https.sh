#!/bin/bash
# 讓 Tailscale 幫 MiniRemote 加上正式 https 憑證(瀏覽器才准用 H.264 硬解)
cd "$(dirname "$0")"
PORT=$(python3 -c "import json;print(json.load(open('config.json'))['port'])" 2>/dev/null || echo 8800)
command -v tailscale >/dev/null || { echo "✗ 找不到 tailscale 指令,請先安裝 Tailscale"; exit 1; }
tailscale ip -4 >/dev/null 2>&1 || { echo "✗ Tailscale 沒連線,請先打開 Tailscale App 登入"; exit 1; }
if tailscale serve --bg "http://127.0.0.1:$PORT" 2>&1 | tee /tmp/ts-serve.log | grep -q -i "https"; then
  echo "✓ 完成,網址:"; grep -o 'https://[^ ]*' /tmp/ts-serve.log | head -1
else
  cat /tmp/ts-serve.log
  echo
  echo "如果上面說 HTTPS 沒開:到 https://login.tailscale.com/admin/dns → 「HTTPS Certificates」按 Enable,然後再跑一次這個腳本。"
fi
