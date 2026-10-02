# 註銷所有已登入裝置的 token(例如筆電掉了)。之後每台都要重新輸入密碼。
$Dest = Join-Path $env:USERPROFILE "MiniRemote"
Remove-Item (Join-Path $Dest "sessions.json") -ErrorAction SilentlyContinue
Write-Host "✓ 已註銷所有登入;正在重啟…"
& (Join-Path $Dest "start.ps1")
