#!/bin/bash
cd "$(dirname "$0")"
if launchctl print gui/$(id -u)/com.john.miniremote >/dev/null 2>&1; then
  launchctl kickstart -k gui/$(id -u)/com.john.miniremote && echo "✓ 已(重新)啟動"
else
  launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.john.miniremote.plist && echo "✓ 已啟動"
fi
sleep 1; ./status.sh
