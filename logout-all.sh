#!/bin/bash
# 註銷所有已登入裝置的 token(例如筆電掉了)。之後每台都要重新輸入密碼。
cd "$(dirname "$0")"
rm -f sessions.json && echo "✓ 已註銷所有登入;正在重啟服務…"
launchctl kickstart -k gui/$(id -u)/com.john.miniremote 2>/dev/null || true
