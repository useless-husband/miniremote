$Dest = Join-Path $env:USERPROFILE "MiniRemote"
$cfg = Get-Content (Join-Path $Dest "config.json") -Raw | ConvertFrom-Json
Write-Host "──────── MiniRemote 狀態(Windows)────────"
if (Get-Process -Name "MiniRemote" -ErrorAction SilentlyContinue) { Write-Host "服務:🟢 執行中" } else { Write-Host "服務:🔴 沒有在跑(執行 start.ps1)" }
try { $h = Invoke-WebRequest -Uri "http://127.0.0.1:$($cfg.port)/health" -UseBasicParsing -TimeoutSec 2; if ($h.Content -eq "ok") { Write-Host "網頁伺服器:🟢 port $($cfg.port) 正常" } } catch { Write-Host "網頁伺服器:🔴 port $($cfg.port) 沒有回應" }
Write-Host "密碼:$($cfg.password)"
$sess = Join-Path $Dest "sessions.json"
$n = 0; if (Test-Path $sess) { try { $n = (Get-Content $sess -Raw | ConvertFrom-Json).Count } catch {} }
Write-Host "已登入裝置(token):$n 個(logout-all.ps1 可全部登出)"
Write-Host ""
Write-Host "可用網址:"
$ts = "C:\Program Files\Tailscale\tailscale.exe"
if (Test-Path $ts) {
  $ip = (& $ts ip -4 2>$null | Select-Object -First 1)
  if ($ip) {
    $dns = ((& $ts status --json 2>$null | ConvertFrom-Json).Self.DNSName).TrimEnd(".")
    Write-Host "  Tailscale HTTPS:https://$dns/   (HEVC/H.264 模式,推薦)"
    Write-Host "  Tailscale:      http://$ip`:$($cfg.port)/   (JPEG 模式)"
  } else { Write-Host "  Tailscale:🔴 沒連線 → 打開 Tailscale 登入" }
} else { Write-Host "  (沒安裝 Tailscale,外出無法連回來)" }
Write-Host ""
Write-Host "最近的紀錄($Dest\MiniRemote.log):"
Get-Content (Join-Path $Dest "MiniRemote.log") -Tail 6 -ErrorAction SilentlyContinue | ForEach-Object { Write-Host "  $_" }
