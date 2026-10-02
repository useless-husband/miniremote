# ════════════════════════════════════════════════════════════
#  MiniRemote 一鍵安裝(Windows 版)
#  用法:在這個資料夾上按右鍵 → 「在終端機中開啟」,然後貼上:
#      powershell -ExecutionPolicy Bypass -File .\setup-windows.ps1
# ════════════════════════════════════════════════════════════
$ErrorActionPreference = "Stop"
function Say($m)  { Write-Host "✓ $m" -ForegroundColor Green }
function Warn($m) { Write-Host "! $m" -ForegroundColor Yellow }
function Step($m) { Write-Host ""; Write-Host "── $m ──" -ForegroundColor Cyan }

$Src  = Split-Path -Parent $MyInvocation.MyCommand.Path
$Dest = Join-Path $env:USERPROFILE "MiniRemote"
Write-Host "MiniRemote 安裝程式(Windows)" -ForegroundColor White
Write-Host "把這台 Windows 變成可以從外面遠端操控的主機。"

Step "1/6 檢查系統"
$os = [System.Environment]::OSVersion.Version
if ($os.Major -lt 10) { throw "需要 Windows 10 以上" }
$arch = if ([System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture -eq "Arm64") { "arm64" } else { "amd64" }
Say "Windows $($os.Major).$($os.Build),$arch"

Step "2/6 複製檔案到 $Dest"
New-Item -ItemType Directory -Force -Path $Dest | Out-Null
$exe = "MiniRemote-$arch.exe"
if (-not (Test-Path (Join-Path $Src $exe))) { throw "找不到 $exe" }
Copy-Item (Join-Path $Src $exe) (Join-Path $Dest "MiniRemote.exe") -Force
Copy-Item (Join-Path $Src "index.html") $Dest -Force
foreach ($f in @("start.ps1","stop.ps1","status.ps1","logout-all.ps1","README.md")) {
  if (Test-Path (Join-Path $Src $f)) { Copy-Item (Join-Path $Src $f) $Dest -Force }
}
Unblock-File (Join-Path $Dest "MiniRemote.exe") -ErrorAction SilentlyContinue
Say "檔案就緒"

Step "3/6 ffmpeg(負責抓畫面與硬體編碼)"
$ff = Join-Path $Dest "ffmpeg.exe"
if (-not (Test-Path $ff)) {
  $zipName = if ($arch -eq "arm64") { "ffmpeg-master-latest-winarm64-gpl.zip" } else { "ffmpeg-master-latest-win64-gpl.zip" }
  $url = "https://github.com/BtbN/FFmpeg-Builds/releases/latest/download/$zipName"
  $zip = Join-Path $env:TEMP $zipName
  Write-Host "  下載 ffmpeg(約 100 MB,請稍等)…"
  [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
  Invoke-WebRequest -Uri $url -OutFile $zip -UseBasicParsing
  $tmp = Join-Path $env:TEMP "miniremote-ffmpeg"
  if (Test-Path $tmp) { Remove-Item $tmp -Recurse -Force }
  Expand-Archive -Path $zip -DestinationPath $tmp -Force
  $found = Get-ChildItem -Path $tmp -Recurse -Filter "ffmpeg.exe" | Select-Object -First 1
  if (-not $found) { throw "ffmpeg 壓縮檔裡找不到 ffmpeg.exe" }
  Copy-Item $found.FullName $ff -Force
  Remove-Item $tmp -Recurse -Force; Remove-Item $zip -Force
  Say "ffmpeg 已就位"
} else { Say "ffmpeg 已存在" }

Step "4/6 產生連線密碼與設定"
$cfgPath = Join-Path $Dest "config.json"
if (-not (Test-Path $cfgPath)) {
  $chars = "ABCDEFGHJKMNPQRSTUVWXYZabcdefghjkmnpqrstuvwxyz23456789".ToCharArray()
  $pw = -join (1..10 | ForEach-Object { $chars | Get-Random })
  $cfg = [ordered]@{
    port = 8800; password = $pw; name = "Windows"; fps = 30; bitrateKbps = 12000; autoBitrate = $true
    jpegQuality = 0.6; maxHeight = 0; allowLAN = $false; allowedTailscaleLogins = @()
    fileRoots = @("~", "*drives"); sessionDays = 30; idleStopSeconds = 60
    encoder = "auto"; capture = "auto"; cmdAsCtrl = $true; peers = @()
  }
  ($cfg | ConvertTo-Json -Depth 3) | Set-Content -Path $cfgPath -Encoding UTF8
  Say "新密碼已產生"
} else { Say "沿用現有 config.json" }
$pw = (Get-Content $cfgPath -Raw | ConvertFrom-Json).password

Step "5/6 設定開機自動啟動並啟動"
$startup = [Environment]::GetFolderPath("Startup")
$lnk = Join-Path $startup "MiniRemote.lnk"
$ws = New-Object -ComObject WScript.Shell
$sc = $ws.CreateShortcut($lnk)
$sc.TargetPath = Join-Path $Dest "MiniRemote.exe"
$sc.WorkingDirectory = $Dest
$sc.Description = "MiniRemote 遠端控制"
$sc.Save()
Get-Process -Name "MiniRemote" -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep -Milliseconds 500
Start-Process -FilePath (Join-Path $Dest "MiniRemote.exe") -WorkingDirectory $Dest
Start-Sleep -Seconds 3
Say "已啟動,並設定登入時自動執行"

Step "6/6 Tailscale(讓你在外面連得回來)"
$ts = "C:\Program Files\Tailscale\tailscale.exe"
$tsOK = $false; $dns = ""; $ip = ""
if (Test-Path $ts) {
  $ip = (& $ts ip -4 2>$null | Select-Object -First 1)
  if ($ip) {
    & $ts serve reset 2>$null | Out-Null
    & $ts serve --bg "http://127.0.0.1:8800" 2>$null | Out-Null
    $status = & $ts status --json 2>$null | ConvertFrom-Json
    $dns = $status.Self.DNSName.TrimEnd(".")
    $tsOK = $true
    Say "Tailscale 已連線:$dns"
  } else { Warn "Tailscale 有裝但沒登入。請打開 Tailscale 登入(帳號要跟筆電同一個),再跑一次這個腳本。" }
} else { Warn "還沒裝 Tailscale。請到 https://tailscale.com/download/windows 下載安裝、登入,再跑一次這個腳本。" }

Write-Host ""
Write-Host "════════════════════════════════════════════" -ForegroundColor White
$log = Join-Path $Dest "MiniRemote.log"
if (Test-Path $log) { Get-Content $log -Tail 4 | ForEach-Object { Write-Host "  $_" -ForegroundColor DarkGray } }
Write-Host "════════════════════════════════════════════" -ForegroundColor White
Write-Host ""
Write-Host "連線密碼:" -NoNewline; Write-Host " $pw" -ForegroundColor Yellow
Write-Host "連線網址:"
if ($tsOK) {
  Write-Host "  出門在外(推薦):https://$dns/" -ForegroundColor Yellow
  Write-Host "  出門在外(備用):http://$ip`:8800/"
}
Write-Host "  (為了安全,只接受 Tailscale 連線)"
Write-Host ""
Write-Host "以後查狀態:在這個資料夾按右鍵 → 在終端機中開啟 → powershell -ExecutionPolicy Bypass -File .\status.ps1"
Write-Host "說明書:$Dest\README.md"
Write-Host ""
Read-Host "按 Enter 結束"
