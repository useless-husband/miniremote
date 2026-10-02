#!/bin/bash
# 讓這台 Mac 產生全新的 Tailscale 機器身分(解決兩台 Mac 共用同一個身分互搶的問題)
# 需要管理員權限:sudo ~/MiniRemote/fix-tailscale-identity.sh
[ "$(id -u)" = "0" ] || { echo "請用 sudo 執行"; exit 1; }
TS=/usr/local/bin/tailscale
STATE=/Library/Tailscale/profile-data
BEFORE=$($TS status --json 2>/dev/null | python3 -c "import sys,json; print(json.load(sys.stdin)['Self']['ID'])" 2>/dev/null)
echo "目前節點 ID:${BEFORE:-無}"
echo "1) 斷線…"; $TS down 2>/dev/null; sleep 1
# 關鍵:用 kill -9 讓擴充功能來不及把舊身分寫回磁碟
PID=$(pgrep -f io.tailscale.ipn.macsys.network-extension | head -1)
[ -n "$PID" ] && kill -9 "$PID" && echo "2) 已強制停止 Tailscale 擴充功能(PID $PID)"
sleep 1
if [ -d "$STATE" ]; then
  BAK="$STATE.old-$(date +%m%d-%H%M%S)"; mv "$STATE" "$BAK"; echo "3) 舊身分已備份到 $BAK"
fi
echo "4) 等 Tailscale 擴充功能自己重新啟動…"
for i in $(seq 1 20); do sleep 1; pgrep -f io.tailscale.ipn.macsys.network-extension >/dev/null && break; done
sleep 3
STATE_NOW=$($TS status 2>&1 | head -1)
echo "5) 目前狀態:$STATE_NOW"
if echo "$STATE_NOW" | grep -qi "logged out\|NeedsLogin\|stopped\|Log in"; then
  echo "✓ 身分已清除。接下來:點右上角 Tailscale 圖示 → Log in → 用 Google 帳號登入。"
else
  AFTER=$($TS status --json 2>/dev/null | python3 -c "import sys,json; print(json.load(sys.stdin)['Self']['ID'])" 2>/dev/null)
  echo "節點 ID 現在:${AFTER:-無}(之前 $BEFORE)"
  [ "$AFTER" != "$BEFORE" ] && echo "✓ 已是新身分" || echo "✗ 身分沒變,請把這段輸出拍給 Claude"
fi
