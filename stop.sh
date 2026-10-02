#!/bin/bash
launchctl bootout gui/$(id -u)/com.john.miniremote 2>/dev/null && echo "✓ 已停止(重開機或執行 start.sh 才會再啟動)" || echo "(本來就沒在跑)"
