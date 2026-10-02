#!/bin/bash
launchctl bootout gui/$(id -u)/com.john.miniremote 2>/dev/null || true
rm -f ~/Library/LaunchAgents/com.john.miniremote.plist
echo "✓ 已移除自動啟動。程式資料夾 ~/MiniRemote 保留,不需要可自行刪除。"
