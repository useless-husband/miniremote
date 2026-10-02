# MiniRemote — 從外面用筆電操控家裡的 Mac 與 Windows

> *English:* MiniRemote is a self-hosted browser-based remote desktop. A small server runs on your home Mac (Swift, ScreenCaptureKit + VideoToolbox HEVC/H.264) or Windows PC (Go + ffmpeg), both speaking the same protocol; connect over Tailscale from any browser to view the screen, control mouse/keyboard, and transfer files. Documentation below is in Traditional Chinese.

自製的遠端桌面:家裡的 Mac 跑一個小伺服器,外面用**瀏覽器**打開網址就能看到畫面、操作滑鼠鍵盤、
瀏覽與下載/上傳檔案。工具列可以**即時調整幀率(fps)、解析度、位元率、編碎方式**,
也有「高畫質 / 平衡 / 省流量」一鍵模式,位元率預設自動調整(網路塞就降、順了再升)。

**版本 2.0 重點**
- 畫質:預設抓 **Retina 原生像素**,用 **HEVC(H.265)硬體編碼**,同流量下比 H.264 更清楚
- 資安:只接受 Tailscale 連線、登入後改用 token(筆電不存密碼)、密碼錯 8 次鎖 15 分鐘、
  防跨站 WebSocket、安全標頭、記錄 Tailscale 帳號
- 檔案:網頁內建檔案瀏覽器,可下載單檔、整個資料夾打包 zip、拖拉上傳
- 輕量:沒人連線 60 秒就停止擷取;分頁切到背景自動暫停傳輸

```
 MacBook Air(外面)                                 家裡的 Mac
 ┌──────────────────┐   Tailscale(加密隧道)   ┌───────────────────────────────┐
 │ Chrome 開網頁    │ ───── https/wss ──────▶ │ MiniRemote.app(背景服務)      │
 │  ‧ 看畫面 H.264  │ ◀──── 影像串流 ──────── │  ‧ ScreenCaptureKit 擷取螢幕   │
 │  ‧ 滑鼠/鍵盤     │ ───── JSON 事件 ──────▶ │  ‧ VideoToolbox 硬體編碼 H.264 │
 │  ‧ 調 fps/解析度 │                          │  ‧ CGEvent 注入滑鼠鍵盤        │
 └──────────────────┘                          └───────────────────────────────┘
```

## 零、支援哪些電腦

| 家裡那台 | 安裝包 | 安裝方式 |
|---|---|---|
| Mac(mini / 任何 Mac,macOS 14+) | 桌面 **MiniRemote** 資料夾 | 終端機 `bash ~/Downloads/MiniRemote/setup-mini.command` |
| Windows 10/11 | 桌面 **MiniRemote-Windows** 資料夾 | 終端機 `powershell -ExecutionPolicy Bypass -File .\setup-windows.ps1` |

兩邊用同一套網頁端與協定,筆電上的操作方式完全一樣。
筆電桌面的 **選擇電腦.html** 打開就會列出所有電腦、顯示在不在線,點一下就連。
連進去之後工具列左邊也有「電腦」下拉選單可以直接切換。

## 一、家裡的 Mac mini(留在家那台)要做的事

### 0. 安裝(在 Mac mini 上做,只要做一次)
1. 先在 Mac mini 裝好 **Tailscale** 並用同一個帳號登入
2. 把筆電桌面上的 **MiniRemote 資料夾**傳到 Mac mini(AirDrop 最快,或用隨身碟)
3. 在 Mac mini 打開「終端機」,貼上這行按 Enter:
   ```
   bash ~/Downloads/MiniRemote/setup-mini.command
   ```
4. 照著畫面指示做,它會自己裝好並帶你開權限,最後印出密碼和網址

### 1. 開兩個權限(安裝程式會帶你做)
1. 打開 **系統設定** → **隱私權與安全性**
2. 點 **螢幕錄製與系統錄音** → 找到 **MiniRemote** → 開關打開
   (程式偵測到權限打開後會自己重啟,不用做別的)
3. 回到 **隱私權與安全性** → 點 **輔助使用** → 找到 **MiniRemote** → 開關打開
   (這個是讓遠端能操控滑鼠鍵盤)
4. 執行 `~/MiniRemote/status.sh`,看到 log 出現「開始擷取 顯示器…」就成功了

如果清單裡沒有 MiniRemote:執行 `~/MiniRemote/start.sh` 讓它再要求一次權限。

### 2. Tailscale 要保持登入、開著
確認選單列的 Tailscale 圖示是連線狀態。安裝程式會印出這台正確的網址。

### 3. 不要讓電腦睡著(Mac mini 上做)
- 系統設定 → **能源** → 「防止自動進入睡眠」打開
- 系統設定 → **鎖定畫面** → 「螢幕保護程式啟動後要求密碼」設「永不」,
  「顯示器關閉時要求密碼」也設「永不」。
  **這很重要**:一旦鎖定畫面出現,遠端就送不進滑鼠鍵盤,只能等你回家
- 系統設定 → **使用者與群組** → 自動登入 選你的帳號(停電重開才會自己回來)
- Mac mini 如果沒接螢幕:買一個 **HDMI 假負載(dummy plug)**插著,
  不然 macOS 沒有螢幕可以擷取,會一直失敗。
  要用 60fps 模式的話,買標示 **4K@60Hz** 的假負載(有些 4K 假負載只有 30Hz,那樣最多只能 30fps);
  要 120fps 就要 mini 接 **120Hz 螢幕**(或標示 1440p@120Hz / 4K@120Hz 的假負載,HDMI 2.1 或 DisplayPort);
  在 mini 的 系統設定 → 顯示器 → 更新率 可以確認目前是幾 Hz;
  想要 Retina 畫質就在系統設定 → 顯示器 選「看起來像 1920×1080」的縮放模式,實際會以 3840×2160 擷取
- 如果 Mac mini 開了 **FileVault**:停電重開機會卡在解鎖畫面,遠端就進不去。
  用 `fdesetup status` 查;要嘛關掉,要嘛接 UPS 不斷電系統

## 二、帶出門那台筆電要做的事

1. 安裝 **Tailscale**(App Store 或 tailscale.com),用同一個帳號(you@example.com)登入,確認是連線狀態
2. 打開 **Chrome**(建議;Safari 也能用但全螢幕時鍵盤快捷鍵會被瀏覽器吃掉)
3. 網址輸入 **安裝程式在 Mac mini 上印出來的 https 網址**
   - https 網址才能用省流量的 **H.264**
   - 備用的 `http://100.x.x.x:8800/` 只能 JPEG 模式,流量大 3~10 倍
4. 輸入安裝時產生的密碼,勾「記住密碼」

出門前建議先在家裡用 Air 連一次確認 OK。

## 三、操作說明(網頁上方工具列)

| 項目 | 說明 |
|---|---|
| 模式 | **高畫質**=原生 30fps;**極致 60fps**=原生 60fps(上限 30 Mbps);**120fps(實驗)**=1440p 120fps;**平衡**=1080p 30fps;**省流量**=720p 15fps。動任何細項會變「自訂」 |
| 幀率 | 5~120 fps。網路差選 10~15;一般選 30;60 很順但流量約兩倍;90/120 是實驗性的,mini 的螢幕要是 120Hz 才有意義 |
| 解析度 | 「原生」最清楚但最耗流量;手機熱點建議 1280×720 或以下 |
| 編碼 | 自動 = 優先 HEVC,再 H.264,最後 JPEG(http 網址只能 JPEG)。HEVC 最省流量畫質最好 |
| 位元率 | 上限。勾「自動」會在網路塞的時候自己往下降,順了再慢慢升回上限。手機熱點上限設 2~4 Mbps,家裡光纖 12 以上 |
| 檔案 | 打開右側檔案面板:點資料夾進入、點檔案下載、「下載整個資料夾」會打包成 zip、可拖檔案進來上傳 |
| 登出 | 註銷這台瀏覧器的登入;下次要重新輸入密碼 |
| 畫質 | JPEG 模式:壓縮品質,越低越模糊越省 |
| 顯示器 | 家裡接多個螢幕時切換要看哪一個 |
| 打字框 | 中文請打在這裡按 Enter,整句送過去(畫面上直接打字只能英數) |
| 全螢幕 | Chrome 全螢幕會鎖住鍵盤,Cmd+Tab、Cmd+W 等會送到遠端;按住 Esc 幾秒離開 |
| 隱藏 | 收起工具列;滑鼠移到最上緣或點上方小標籤會再出現 |
| 右下角數字 | 實際畫出的 fps、目前流量 Mbps、延遲 ms、目前解析度與編碼、位元率、接收端螢幕更新率(Hz) |

滑鼠:左鍵/右鍵/中鍵/拖曳/滾輪都可以,連點兩下會變雙擊。
鍵盤:一般按鍵與 Shift/Ctrl/Option/Cmd 組合都會傳過去。

## 四、常用指令(在家裡那台的終端機)

```bash
~/MiniRemote/status.sh      # 看狀態、密碼、網址、最近 log
~/MiniRemote/start.sh       # 啟動 / 重新啟動
~/MiniRemote/stop.sh        # 停止(重開機後不會自動啟動,除非再 start)
~/MiniRemote/install.sh     # 重新安裝背景服務(換電腦時用)
~/MiniRemote/uninstall.sh   # 移除自動啟動
~/MiniRemote/build.sh       # 改了程式碼後重新編譯打包
~/MiniRemote/tailscale-https.sh   # 重新設定 Tailscale https 轉接
~/MiniRemote/logout-all.sh  # 註銷所有已登入裝置(筆電掉了用這個)
tail -f ~/Library/Logs/MiniRemote.log   # 即時看 log
```

改密碼或 port:編輯 `~/MiniRemote/config.json`,然後 `./start.sh`。

`config.json` 其他欄位:
- `allowLAN`:預設 false,只接受 Tailscale 與本機連線。想讓家裡區網其他裝置直接連才改 true
- `allowedTailscaleLogins`:例如 `["you@example.com"]`,只允許這些 Tailscale 帳號(經由 https 網址進來時檢查)
- `fileRoots`:檔案面板可以看的範圲,預設家目錄與 /Volumes(外接硬碟)
- `sessionDays`:登入 token 幾天後失效(預設 30)
- `idleStopSeconds`:沒人連線多久後停止擷取(預設 60;0 = 不停)
- `bitrateKbps` / `autoBitrate`:預設位元率上限與是否自動調整
- `name`:這台在網頁上顯示的名字
- `peers`:其他電腦,例如 `[{"name": "Windows", "url": "https://desktop-xxx.tailxxxx.ts.net/"}]`,
  填了之後工具列會出現「電腦」下拉選單可以直接切換(兩台都填對方就能互跳)

## 四點五、Windows 端說明

Windows 版是用 Go 寫的伺服器 + ffmpeg:畫面用 Desktop Duplication(ddagrab,GPU 直接抓)或 GDI 擷取,
編碼自動挑 NVIDIA NVENC / Intel QSV / AMD AMF 硬體編碼(HEVC 或 H.264),都沒有就用 CPU 的 x264。
滑鼠鍵盤用 SendInput 注入。功能與 Mac 版相同(token 登入、只收 Tailscale、檔案面板、自動位元率、閒置停止)。

- 安裝完檔案在 `C:\Users\<你>\MiniRemote\`,設定檔 `config.json`,紀錄 `MiniRemote.log`
- 開機自動啟動:靠「啟動」資料夾裡的捷徑(shell:startup);沒有主控台視窗,背景執行
- **Cmd 當 Ctrl**:預設打開,Mac 鍵盤按 Cmd+C 到 Windows 就是 Ctrl+C。工具列可關
- 檔案面板可以看家目錄與所有磁碟(C:、D:…)
- 幀率/解析度/位元率變更會重啟 ffmpeg(約 0.3 秒黑一下),自動位元率因此調得比較保守
- 沒有硬體編碎器時 1080p30 大概吃一顆核心,建議選 720p

Windows 上要做的設定:設定 → 帳戶 → 登入選項 → 「需要登入」改**永不**;設定 → 電源 → 睡眠設**永不**。

## 五、搬到另一台 Mac

把整個資料夾傳過去,在那台終端機執行 `bash <資料夾路徑>/setup-mini.command` 就好。
`MiniRemote.app` 是 Intel + Apple 晶片通用版,不用重新編譯,那台也不用裝 Xcode。
需要 macOS 14(Sonoma)以上。

要改程式碼再重新編譯的話,那台要先裝 Xcode Command Line Tools:`xcode-select --install`,
然後 `./build.sh`(通用版)或 `./build.sh --fast`(只編目前架構,比較快)。

### 60fps 極致模式實測(MacBook Pro M5 當伺服器)

| 設定 | 結果 |
|---|---|
| HEVC 3024×1964 @ 60fps | 穩定 60 fps,伺服器 CPU 約 17%,記憶體 117 MB |
| H.264 3024×1964 @ 60fps | 穩定 60 fps,CPU 約 17% |
| 真實桌面 60fps | 擷取 55~60 fps、送出 56~61 fps,流量 2~10 Mbps 看畫面變動量 |

### 120fps 實測(發送端用 120Hz ProMotion 螢幕的 M5 測)

| 解析度 @ 120fps | 真實桌面送出幀率 | 編碼器丟幀 |
|---|---|---|
| 1662×1080 | 100~115 fps | 幾乎 0 |
| 2218×1440 | 100~119 fps | 0 |
| 3024×1964(原生) | 76~87 fps | 每秒約 30 |

結論:**120fps 請配 1440p 或 1080p**,原生 3K 解析度硬體編碼器只到約 80 fps。
編碼器跟不上時會自動丟掉多的幀(不會堆積、記憶體固定 60~120 MB),所以怎麼設都不會爆,只是實際 fps 會低於設定值。
接收端要真的畫到 120fps,必須(1)發送端 mini 的螢幕是 120Hz、(2)接收端螢幕 120Hz、(3)瀏覧器用 Chrome。
工具列右邊的「螢幕 xxHz」會顯示接收端目前的更新率,fps 數字是實際畫出來的幀率。

家裡上傳 50 Mbps,極致模式上限設 30 Mbps 留有餘裕。上傳被塞滿時延遲會飆高(這條線有 bufferbloat),
所以不要把上限拉到 40 以上。Intel 的 Mac mini 硬體編碼較弱,60fps 原生可能撐不住,請降到 1080p。

## 六、疑難排解

| 狀況 | 怎麼處理 |
|---|---|
| 網頁打不開 | 兩台的 Tailscale 都要是連線狀態;家裡那台執行 `./status.sh` 確認「服務 🟢」 |
| 連上但畫面全黑或沒畫面 | 家裡那台「螢幕錄製」權限沒開,或開了還沒重啟:`./start.sh` |
| 看得到畫面但滑鼠鍵盤沒反應 | 「輔助使用」權限沒開 |
| 頓、延遲高 | 把幀率調到 15、解析度調 1280×720、位元率調 2 Mbps |
| https 網址無法使用 | 到 https://login.tailscale.com/admin/dns 確認 HTTPS Certificates 已 Enable,再跑 `./tailscale-https.sh` |
| 網頁說只能 JPEG | 你用的是 http 網址;改用 https 的 Tailscale 網址 |
| 螢幕錄製開了還是失敗 | 系統設定裡把 MiniRemote 的開關關掉再開,然後 `./start.sh` |
| 重新編譯後權限又要重開? | 不會。已用固定憑證簽章(`make-cert.sh`),權限跟著憑證走 |

## 七、技術結構(給想改程式的人)

```
Sources/MiniRemote/
  main.swift            進入點、參數(--config、--test-pattern)
  Config.swift          config.json 讀取
  RemoteServer.swift    核心:TCP 監聯、客戶端管理、設定變更、廣播、每秒統計
  ClientConnection.swift  自己實作的 HTTP + WebSocket(RFC 6455)連線,含背壓/丟幀
  FrameSource.swift     ScreenCaptureKit 擷取器;TestPatternSource 測試圖樣
  VideoEncoder.swift    VideoToolbox 低延遲 HEVC / H.264,輸出長度前綴 NAL + hvcC / avcC
  Sessions.swift        登入 token(只存 SHA-256)、密碼錯誤鎖定
  FileService.swift     檔案列表 / 下載 / zip / 上傳,限制在 fileRoots 之內
windows/                Windows 版伺服器(Go):server.go / ws.go / capture.go(ffmpeg fMP4 解析)/ input_windows.go …
windows/dist/           給 Windows 的安裝包(MiniRemote-amd64.exe、MiniRemote-arm64.exe、setup-windows.ps1)
make-launcher.sh        產生筆電桌面的「選擇電腦.html」;mini 裝好後執行 ./make-launcher.sh --refresh
  JPEGEncoder.swift     CoreImage JPEG 備用編碼
  InputInjector.swift   CGEvent 滑鼠/鍵盤/滾輪/文字注入
  KeyMap.swift          瀏覽器 KeyboardEvent.code → macOS 鍵碼表
Client/index.html       網頁端:WebCodecs 解碼 H.264、canvas 顯示、事件回傳、工具列
```

二進位影像訊息:`type(1) flags(1) width(2) height(2) pts_us(8) descLen(2) [avcC/hvcC] payload`,
type 1 = H.264、2 = JPEG、3 = HEVC。其餘 WebSocket 訊息皆為 JSON 文字。
HTTP API(需要 cookie `mr_session`):`GET /api/list?path=`、`GET /api/download?path=`、`POST /api/upload?dir=&name=`。

不用權限的測試模式:`./MiniRemote.app/Contents/MacOS/MiniRemote --test-pattern`(先 `./stop.sh`)。
