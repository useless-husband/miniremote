Get-Process -Name "MiniRemote" -ErrorAction SilentlyContinue | Stop-Process -Force
Write-Host "✓ 已停止(重開機後會再自動啟動;要完全移除自動啟動請刪掉「啟動」資料夾裡的 MiniRemote 捷徑)"
