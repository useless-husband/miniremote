$Dest = Join-Path $env:USERPROFILE "MiniRemote"
Get-Process -Name "MiniRemote" -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep -Milliseconds 500
Start-Process -FilePath (Join-Path $Dest "MiniRemote.exe") -WorkingDirectory $Dest
Write-Host "✓ 已(重新)啟動"
Start-Sleep -Seconds 2
& (Join-Path $Dest "status.ps1")
