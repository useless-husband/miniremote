import Foundation
import Network
import ScreenCaptureKit
import CoreMedia
import CoreGraphics
import ApplicationServices
import IOKit.pwr_mgt

final class RemoteServer {
    private let config: AppConfig
    private let configPath: String
    private let testPattern: Bool
    private let queue = DispatchQueue(label: "miniremote.server", qos: .userInteractive)

    private var listener: NWListener?
    private var clients: [UUID: ClientConnection] = [:]
    private var source: FrameSource?
    private var setupInProgress = false
    private var encoders: [VideoCodec: VideoEncoder] = [:]
    private let hevcSupported: Bool
    private let jpeg = JPEGEncoder()
    private let input = InputInjector()
    private let files: FileService
    private let sessions: SessionStore
    private var htmlPath: String?

    private var displays: [SCDisplay] = []
    private var currentDisplayID: CGDirectDisplayID = 0
    private var presets: [[Int]] = []
    private var fps: Int
    private var width = 0
    private var height = 0
    private var userChoseSize = false
    private var bitrateKbps: Int          // 使用者設定的上限
    private var currentBitrate: Int       // 自動調整後實際用的
    private var autoBitrate: Bool
    private var jpegQuality: Double

    private var lastFrame: CVPixelBuffer?
    private var lastEncodeAt = Date.distantPast
    private var lastKeyAt = Date.distantPast
    private var keyRequested = false
    private var retryScheduled = false
    private var waitingForScreenPermission = false
    private var displayAssertion: IOPMAssertionID = 0
    private var timer: DispatchSourceTimer?
    private var idleStopWork: DispatchWorkItem?

    private var statSentFrames = 0
    private var statSentBytes = 0
    private var statCaptured = 0
    private var dropsThisSecond = 0
    private var stableSeconds = 0
    private var lastEncDrops = 0

    init(config: AppConfig, configPath: String, testPattern: Bool) {
        self.config = config
        self.configPath = configPath
        self.testPattern = testPattern
        fps = max(1, min(120, config.fps))
        bitrateKbps = max(200, min(100_000, config.bitrateKbps))
        currentBitrate = bitrateKbps
        autoBitrate = config.autoBitrate
        jpegQuality = max(0.1, min(1.0, config.jpegQuality))
        let dir = URL(fileURLWithPath: configPath).deletingLastPathComponent()
        sessions = SessionStore(directory: dir, days: config.sessionDays)
        files = FileService(roots: config.fileRoots)
        hevcSupported = VideoEncoder.isSupported(.hevc)
    }

    // MARK: 啟動

    func start() {
        resolveHTML()
        log("硬體編碼:HEVC \(hevcSupported ? "可用" : "不可用(會用 H.264)")、檔案根目錄 \(files.roots)、\(config.allowLAN ? "允許區網連線" : "只接受 Tailscale/本機連線")")
        startListener()
        startTimer()
        checkPermissions()
        Task { await self.setupSource() }
    }

    private func encoder(for codec: VideoCodec) -> VideoEncoder {
        if let e = encoders[codec] { return e }
        let e = VideoEncoder(codec: codec)
        e.bitrateKbps = currentBitrate
        e.fps = fps
        e.onEncoded = { [weak self] frame in self?.queue.async { self?.broadcastVideo(frame) } }
        encoders[codec] = e
        return e
    }

    private func resolveHTML() {
        let candidates: [String] = [
            Bundle.main.resourcePath.map { $0 + "/index.html" },
            URL(fileURLWithPath: configPath).deletingLastPathComponent().appendingPathComponent("Client/index.html").path,
            URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().appendingPathComponent("index.html").path,
        ].compactMap { $0 }
        htmlPath = candidates.first(where: { FileManager.default.fileExists(atPath: $0) })
        if htmlPath == nil { log("警告:找不到 index.html,網頁端無法載入") }
    }

    private func checkPermissions() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        let ax = AXIsProcessTrustedWithOptions(opts)
        log(ax ? "輔助使用權限:已允許"
               : "輔助使用權限:未允許 → 系統設定 › 隱私權與安全性 › 輔助使用,把 MiniRemote 打開(否則遠端無法操控滑鼠鍵盤)")
        if !testPattern {
            if CGPreflightScreenCaptureAccess() {
                log("螢幕錄製權限:已允許")
            } else {
                CGRequestScreenCaptureAccess()
                log("螢幕錄製權限:未允許 → 系統設定 › 隱私權與安全性 › 螢幕錄製與系統錄音,把 MiniRemote 打開")
            }
        }
    }

    private func startListener() {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        let params = NWParameters(tls: nil, tcp: tcp)
        params.allowLocalEndpointReuse = true
        guard let port = NWEndpoint.Port(rawValue: config.port) else { log("port 無效"); exit(1) }
        do {
            let l = try NWListener(using: params, on: port)
            l.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready: log("伺服器已啟動,port \(self?.config.port ?? 0)")
                case .failed(let e): log("伺服器啟動失敗:\(e)"); exit(1)
                default: break
                }
            }
            l.newConnectionHandler = { [weak self] conn in self?.accept(conn) }
            l.start(queue: queue)
            listener = l
        } catch {
            log("無法建立伺服器:\(error)")
            exit(1)
        }
    }

    private func accept(_ conn: NWConnection) {
        let client = ClientConnection(conn: conn, queue: queue)
        guard client.remoteIsLoopback || client.remoteIsTailscale || config.allowLAN else {
            log("拒絕非 Tailscale 的連線:\(client.remote)")
            conn.cancel()
            return
        }
        client.httpHandler = { [weak self] c, req, done in self?.handleHTTP(c, req, done) }
        client.onText = { [weak self] c, text in self?.handleText(c, text) }
        client.onClose = { [weak self] c in
            guard let self = self else { return }
            self.clients.removeValue(forKey: c.id)
            if c.authenticated {
                log("客戶端離線 \(c.remote)(丟棄 \(c.droppedFrames) 幀)")
                self.input.releaseAll()
                self.clientsChanged()
            }
        }
        clients[client.id] = client
        client.start()
    }

    // MARK: HTTP API

    private static let htmlHeaders: [String: String] = [
        "Content-Security-Policy": "default-src 'self'; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'; img-src 'self' blob: data:; connect-src 'self' ws: wss:; frame-ancestors 'none'",
        "X-Frame-Options": "DENY",
        "Referrer-Policy": "no-referrer",
        "Permissions-Policy": "camera=(), microphone=(), geolocation=()",
    ]

    private func httpAuthorized(_ c: ClientConnection, _ req: HTTPRequest) -> Bool {
        guard tailscaleAllowed(c) else { return false }
        let token = req.cookies["mr_session"] ?? req.query["token"] ?? ""
        return !token.isEmpty && sessions.validate(token)
    }

    private func tailscaleAllowed(_ c: ClientConnection) -> Bool {
        guard !config.allowedTailscaleLogins.isEmpty, let login = c.tailscaleLogin else { return true }
        return config.allowedTailscaleLogins.contains { $0.lowercased() == login.lowercased() }
    }

    private func handleHTTP(_ c: ClientConnection, _ req: HTTPRequest, _ done: @escaping (HTTPResponse) -> Void) {
        switch (req.method, req.path) {
        case ("GET", "/"), ("GET", "/index.html"):
            if let p = htmlPath, let data = FileManager.default.contents(atPath: p) {
                done(.content(status: "200 OK", contentType: "text/html; charset=utf-8", body: data, headers: Self.htmlHeaders))
            } else {
                done(.text("找不到 index.html", status: "500 Internal Server Error"))
            }
        case ("GET", "/health"):
            done(.content(status: "200 OK", contentType: "text/plain; charset=utf-8", body: Data("ok".utf8),
                          headers: ["Access-Control-Allow-Origin": "*"]))

        case ("GET", "/api/list"):
            guard httpAuthorized(c, req) else { done(.text("unauthorized", status: "401 Unauthorized")); return }
            let showHidden = req.query["hidden"] == "1"
            if let listing = files.list(req.query["path"] ?? "", showHidden: showHidden) {
                done(.json(listing))
            } else {
                done(.json(["error": "無法讀取這個路徑"], status: "404 Not Found"))
            }

        case ("GET", "/api/download"):
            guard httpAuthorized(c, req) else { done(.text("unauthorized", status: "401 Unauthorized")); return }
            guard let path = files.resolve(req.query["path"] ?? "") else { done(.text("路徑不允許", status: "403 Forbidden")); return }
            let name = (path as NSString).lastPathComponent
            if files.isDirectory(path) {
                log("打包下載資料夾 \(path) → \(c.remote)")
                files.zipDirectory(path) { zip in
                    if let z = zip { done(.file(path: z, downloadName: name + ".zip", deleteAfter: true)) }
                    else { done(.text("壓縮失敗", status: "500 Internal Server Error")) }
                }
            } else {
                log("下載 \(path) → \(c.remote)")
                done(.file(path: path, downloadName: name, deleteAfter: false))
            }

        case ("POST", "/api/upload"):
            guard httpAuthorized(c, req) else { done(.text("unauthorized", status: "401 Unauthorized")); return }
            guard let dir = files.resolve(req.query["dir"] ?? ""), files.isDirectory(dir),
                  let dest = files.uniqueDestination(directory: dir, name: req.query["name"] ?? "") else {
                done(.text("目的地不允許", status: "403 Forbidden")); return
            }
            log("上傳 \((dest as NSString).lastPathComponent) ← \(c.remote)")
            done(.upload(destination: dest) { ok in
                if ok { return .json(["ok": true, "path": dest, "name": (dest as NSString).lastPathComponent]) }
                try? FileManager.default.removeItem(atPath: dest)
                return .text("上傳中斷", status: "500 Internal Server Error")
            })

        default:
            done(.text("not found", status: "404 Not Found"))
        }
    }

    // MARK: 擷取來源

    private func setupSource() async {
        let already: Bool = queue.sync {
            if self.setupInProgress { return true }
            self.setupInProgress = true
            self.retryScheduled = false
            return false
        }
        if already { return }
        defer { queue.async { self.setupInProgress = false } }

        if testPattern {
            let src = TestPatternSource()
            let bounds = CGDisplayBounds(CGMainDisplayID())
            let presets = Self.makePresets(pixelW: 1920, pixelH: 1080, pointW: 1920, pointH: 1080)
            await startSource(src, presets: presets, defaultSize: (1920, 1080), displayID: 0, frame: bounds, describe: "測試圖樣")
            return
        }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            let list = content.displays
            let wanted = queue.sync { self.currentDisplayID }
            guard let display = list.first(where: { $0.displayID == wanted }) ?? list.first(where: { $0.displayID == CGMainDisplayID() }) ?? list.first else {
                log("找不到任何顯示器(Mac 沒接螢幕時需要 HDMI 假負載),30 秒後重試")
                scheduleRetry(seconds: 30)
                return
            }
            queue.sync { self.displays = list }
            await startCapture(display: display)
        } catch {
            log("無法取得螢幕內容:\(error.localizedDescription)。通常是「螢幕錄製」權限沒開。30 秒後重試")
            queue.async { self.waitingForScreenPermission = !CGPreflightScreenCaptureAccess() }
            scheduleRetry(seconds: 30)
        }
    }

    private func startCapture(display: SCDisplay) async {
        let mode = CGDisplayCopyDisplayMode(display.displayID)
        let pw = mode?.pixelWidth ?? display.width
        let ph = mode?.pixelHeight ?? display.height
        let presets = Self.makePresets(pixelW: pw, pixelH: ph, pointW: display.width, pointH: display.height)
        var size = (pw & ~1, ph & ~1)   // 預設原生像素(Retina 全解析度)
        if config.maxHeight > 0, let p = presets.first(where: { $0[1] <= config.maxHeight }) { size = (p[0], p[1]) }
        let cap = ScreenCapturer(display: display)
        await startSource(cap, presets: presets, defaultSize: size, displayID: display.displayID, frame: display.frame,
                          describe: "顯示器 \(display.width)×\(display.height) 點(實際像素 \(pw)×\(ph))")
    }

    private func startSource(_ src: FrameSource, presets: [[Int]], defaultSize: (Int, Int), displayID: CGDirectDisplayID,
                             frame: CGRect, describe: String) async {
        if let old = queue.sync(execute: { self.source }) { await old.stop() }
        src.onFrame = { [weak self] pb, pts in self?.queue.async { self?.handleFrame(pb, pts: pts) } }
        src.onStopped = { [weak self] err in
            log("擷取中斷:\(err.localizedDescription),3 秒後重新開始")
            self?.queue.async { self?.source = nil }
            self?.scheduleRetry(seconds: 3)
        }
        let (w, h, f): (Int, Int, Int) = queue.sync {
            self.source = src
            self.presets = presets
            if self.currentDisplayID != displayID { self.userChoseSize = false }
            self.currentDisplayID = displayID
            if !self.userChoseSize || self.width == 0 {
                self.width = defaultSize.0
                self.height = defaultSize.1
            }
            self.input.displayFrame = frame
            self.lastFrame = nil
            for e in self.encoders.values { e.invalidate() }
            return (self.width, self.height, self.effectiveFPS)
        }
        do {
            try await src.start(width: w, height: h, fps: f)
            log("開始擷取 \(describe),輸出 \(w)×\(h) @ \(f) fps")
            queue.async { self.broadcastConfig(); self.scheduleIdleStopIfNeeded() }
        } catch {
            log("開始擷取失敗:\(error.localizedDescription),10 秒後重試")
            queue.async { self.source = nil }
            scheduleRetry(seconds: 10)
        }
    }

    private func scheduleRetry(seconds: Double) {
        queue.async {
            guard !self.retryScheduled else { return }
            self.retryScheduled = true
            self.queue.asyncAfter(deadline: .now() + seconds) { Task { await self.setupSource() } }
        }
    }

    private var activeClients: [ClientConnection] { clients.values.filter { $0.authenticated && !$0.paused } }
    private var effectiveFPS: Int { activeClients.isEmpty ? 1 : fps }

    private func updateCapture() {
        guard let src = source else { return }
        let (w, h, f) = (width, height, effectiveFPS)
        Task {
            do { try await src.update(width: w, height: h, fps: f) }
            catch { log("更新擷取設定失敗:\(error.localizedDescription)") }
        }
    }

    /// 沒人連線一段時間就停止擷取,省電
    private func scheduleIdleStopIfNeeded() {
        idleStopWork?.cancel()
        idleStopWork = nil
        guard config.idleStopSeconds > 0, clients.values.filter({ $0.authenticated }).isEmpty, source != nil else { return }
        let w = DispatchWorkItem { [weak self] in self?.stopCaptureForIdle() }
        idleStopWork = w
        queue.asyncAfter(deadline: .now() + Double(config.idleStopSeconds), execute: w)
    }

    private func stopCaptureForIdle() {
        guard clients.values.filter({ $0.authenticated }).isEmpty, let src = source else { return }
        source = nil
        lastFrame = nil
        for e in encoders.values { e.invalidate() }
        Task { await src.stop(); log("沒有人連線 \(config.idleStopSeconds) 秒,已停止擷取(省電);有人連上會自動恢復") }
    }

    static func makePresets(pixelW: Int, pixelH: Int, pointW: Int, pointH: Int) -> [[Int]] {
        let aspect = Double(pixelW) / Double(max(1, pixelH))
        var heights = Set([pixelH, pointH, 1440, 1080, 900, 720, 540].filter { $0 <= pixelH && $0 >= 360 })
        if heights.isEmpty { heights = [pixelH] }
        return heights.sorted(by: >).map { h in
            let w = Int((Double(h) * aspect / 2).rounded()) * 2
            return [w, h & ~1]
        }
    }

    // MARK: 影像處理與廣播

    private func handleFrame(_ pb: CVPixelBuffer, pts: CMTime) {
        statCaptured += 1
        lastFrame = pb
        encode(pb, pts: pts)
    }

    private func encode(_ pb: CVPixelBuffer, pts: CMTime) {
        let active = activeClients
        guard !active.isEmpty else { return }
        lastEncodeAt = Date()
        for codec in [VideoCodec.hevc, .h264] {
            let wanting = active.filter { $0.codec == codec.rawValue }
            guard !wanting.isEmpty else { continue }
            let enc = encoder(for: codec)
            if enc.failed {
                // 這台沒有這種硬體編碼器 → 這些客戶端改用 H.264
                for c in wanting { c.codec = "h264"; c.needsKeyframe = true; c.sendText(Self.json(currentConfig(for: c))) }
                continue
            }
            let needKey = keyRequested || wanting.contains { $0.needsKeyframe }
            var force = false
            if needKey, Date().timeIntervalSince(lastKeyAt) > 0.4 {
                force = true
                lastKeyAt = Date()
                keyRequested = false
            }
            enc.encode(pb, pts: pts, forceKey: force)
        }
        let jpegClients = active.filter { $0.codec == "jpeg" }
        if !jpegClients.isEmpty, let data = jpeg.encode(pb, quality: jpegQuality) {
            let msg = Self.videoMessage(type: 2, key: true, width: CVPixelBufferGetWidth(pb), height: CVPixelBufferGetHeight(pb),
                                        pts: pts, description: nil, payload: data)
            for c in jpegClients { deliver(msg, to: c, isKey: true) }
        }
    }

    private func broadcastVideo(_ frame: EncodedFrame) {
        let msg = Self.videoMessage(type: frame.codec.messageType, key: frame.isKey, width: frame.width, height: frame.height,
                                    pts: frame.pts, description: frame.description, payload: frame.data)
        for c in activeClients where c.codec == frame.codec.rawValue {
            deliver(msg, to: c, isKey: frame.isKey)
        }
    }

    private func deliver(_ msg: Data, to c: ClientConnection, isKey: Bool) {
        if c.needsKeyframe && !isKey { keyRequested = true; return }
        let congested = c.pendingBytes > 1_000_000 || c.pendingFrames > 12
        if congested && (!isKey || c.pendingBytes > 3_000_000) {
            c.needsKeyframe = true
            c.droppedFrames += 1
            dropsThisSecond += 1
            keyRequested = true
            return
        }
        c.needsKeyframe = false
        c.sendBinary(msg)
        statSentFrames += 1
        statSentBytes += msg.count
    }

    /// 二進位訊息:type(1) flags(1) width(2) height(2) pts_us(8) descLen(2) [avcC/hvcC] payload
    /// type 1 = H.264、2 = JPEG、3 = HEVC
    static func videoMessage(type: UInt8, key: Bool, width: Int, height: Int, pts: CMTime, description: Data?, payload: Data) -> Data {
        var d = Data(capacity: 16 + (description?.count ?? 0) + payload.count)
        d.append(type)
        d.append(key ? 1 : 0)
        d.append(UInt8((width >> 8) & 0xFF)); d.append(UInt8(width & 0xFF))
        d.append(UInt8((height >> 8) & 0xFF)); d.append(UInt8(height & 0xFF))
        let us = UInt64(max(0, CMTimeGetSeconds(pts) * 1_000_000))
        for i in (0..<8).reversed() { d.append(UInt8((us >> (UInt64(i) * 8)) & 0xFF)) }
        let dl = description?.count ?? 0
        d.append(UInt8((dl >> 8) & 0xFF)); d.append(UInt8(dl & 0xFF))
        if let a = description { d.append(a) }
        d.append(payload)
        return d
    }

    // MARK: 每秒工作:統計、自動位元率、閒置重送

    private func startTimer() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 1, repeating: 1.0)
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    private func tick() {
        if waitingForScreenPermission, CGPreflightScreenCaptureAccess() {
            log("偵測到「螢幕錄製」權限已打開,重新啟動程式")
            exit(0)
        }
        let active = activeClients
        if !active.isEmpty, let pb = lastFrame, Date().timeIntervalSince(lastEncodeAt) >= 1.0 {
            encode(pb, pts: CMClockGetTime(CMClockGetHostTimeClock()))
        }
        adjustBitrate(hasVideoClients: active.contains { $0.codec != "jpeg" })
        if !active.isEmpty {
            let stats: [String: Any] = [
                "type": "stats", "fps": statSentFrames, "kbps": statSentBytes * 8 / 1000, "captured": statCaptured,
                "clients": active.count, "width": width, "height": height,
                "bitrateNow": currentBitrate, "bitrateMax": bitrateKbps, "auto": autoBitrate, "drops": dropsThisSecond,
                "encDrops": encoders.values.reduce(0) { $0 + $1.droppedByEncoder } - lastEncDrops,
            ]
            lastEncDrops = encoders.values.reduce(0) { $0 + $1.droppedByEncoder }
            let text = Self.json(stats)
            for c in clients.values where c.authenticated { c.sendText(text) }
        }
        statSentFrames = 0
        statSentBytes = 0
        statCaptured = 0
        dropsThisSecond = 0
    }

    private func adjustBitrate(hasVideoClients: Bool) {
        var target = currentBitrate
        if autoBitrate && hasVideoClients {
            if dropsThisSecond > 0 {
                target = max(500, Int(Double(currentBitrate) * 0.65))
                stableSeconds = 0
            } else {
                stableSeconds += 1
                if stableSeconds >= 5, currentBitrate < bitrateKbps {
                    target = min(bitrateKbps, max(currentBitrate + 500, Int(Double(currentBitrate) * 1.25)))
                    stableSeconds = 0
                }
            }
        } else {
            target = bitrateKbps
        }
        if target != currentBitrate {
            currentBitrate = target
            for e in encoders.values { e.bitrateKbps = target }
        }
    }

    // MARK: 客戶端訊息

    private func handleText(_ c: ClientConnection, _ text: String) {
        guard let obj = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              let type = obj["type"] as? String else { return }

        if !c.authenticated {
            guard type == "auth" else { return }
            handleAuth(c, obj)
            return
        }

        switch type {
        case "config":
            applyConfig(obj, from: c)
        case "key":
            c.needsKeyframe = true
            keyRequested = true
        case "pause":
            c.paused = (obj["on"] as? Bool) ?? false
            if !c.paused { c.needsKeyframe = true; keyRequested = true }
            clientsChanged()
        case "mouse":
            let x = (obj["x"] as? Double) ?? 0, y = (obj["y"] as? Double) ?? 0
            switch obj["t"] as? String {
            case "move": input.mouseMove(nx: x, ny: y)
            case "down": input.mouseButton(button: obj["button"] as? Int ?? 0, down: true, nx: x, ny: y, clicks: obj["clicks"] as? Int ?? 1)
            case "up": input.mouseButton(button: obj["button"] as? Int ?? 0, down: false, nx: x, ny: y, clicks: obj["clicks"] as? Int ?? 1)
            default: break
            }
        case "wheel":
            input.scroll(dx: obj["dx"] as? Double ?? 0, dy: obj["dy"] as? Double ?? 0)
        case "keyev":
            input.key(code: obj["code"] as? String ?? "", key: obj["key"] as? String ?? "",
                      down: (obj["d"] as? Int ?? 0) == 1, mods: obj["m"] as? Int ?? 0)
        case "text":
            if let s = obj["text"] as? String, !s.isEmpty, s.count <= 2000 { input.typeString(s) }
        case "release":
            input.releaseAll()
        case "ping":
            c.sendText(Self.json(["type": "pong", "t": obj["t"] ?? 0]))
        case "logout":
            if let t = c.sessionToken { sessions.revoke(t) }
            log("登出並註銷 token:\(c.remote)")
            c.sendTextThenClose(#"{"type":"logout","ok":true}"#)
        default:
            break
        }
    }

    private func handleAuth(_ c: ClientConnection, _ obj: [String: Any]) {
        guard tailscaleAllowed(c) else {
            log("拒絕:Tailscale 帳號 \(c.tailscaleLogin ?? "?") 不在允許名單")
            c.sendTextThenClose(#"{"type":"auth","ok":false,"reason":"tailscale"}"#)
            return
        }
        let locked = sessions.lockedSeconds(for: c.remote)
        if locked > 0 {
            c.sendTextThenClose(Self.json(["type": "auth", "ok": false, "reason": "locked", "seconds": locked]))
            return
        }
        var ok = false
        var viaToken = false
        if let token = obj["token"] as? String, !token.isEmpty {
            ok = sessions.validate(token)
            viaToken = true
            if ok { c.sessionToken = token }
        } else if let pw = obj["password"] as? String {
            ok = config.password.isEmpty || SessionStore.passwordMatches(pw, expected: config.password)
        }
        guard ok else {
            let n = sessions.recordFailure(for: c.remote)
            log("\(viaToken ? "token 無效" : "密碼錯誤")(第 \(n) 次)來自 \(c.remote)\(n >= SessionStore.maxFailures ? ",已鎖定 \(Int(SessionStore.lockMinutes)) 分鐘" : "")")
            queue.asyncAfter(deadline: .now() + min(5, Double(n) * 0.5)) {
                c.sendTextThenClose(Self.json(["type": "auth", "ok": false, "reason": viaToken ? "token" : "password"]))
            }
            return
        }
        sessions.clearFailures(for: c.remote)
        c.authenticated = true
        if let want = obj["codec"] as? String, ["hevc", "h264", "jpeg"].contains(want) {
            c.codec = (want == "hevc" && !hevcSupported) ? "h264" : want
        } else if !hevcSupported {
            c.codec = "h264"
        }
        c.needsKeyframe = true
        var reply: [String: Any] = ["type": "auth", "ok": true]
        if !viaToken {
            let label = "\(c.remote) \(c.tailscaleLogin ?? "") \(Date().formatted(date: .abbreviated, time: .shortened))"
            let token = sessions.issue(label: label)
            c.sessionToken = token
            reply["token"] = token
        }
        c.sendText(Self.json(reply))
        log("客戶端上線 \(c.remote)\(c.tailscaleLogin.map { "(Tailscale 帳號 \($0))" } ?? ""),\(viaToken ? "token 登入" : "密碼登入"),編碼 \(c.codec)")
        sendHello(c)
        clientsChanged()
        if source == nil {
            Task { await self.setupSource() }
        } else if let pb = lastFrame {
            encode(pb, pts: CMClockGetTime(CMClockGetHostTimeClock()))
        }
    }

    private func applyConfig(_ obj: [String: Any], from c: ClientConnection) {
        var captureChanged = false
        if let f = obj["fps"] as? Int, (1...120).contains(f), f != fps {
            fps = f
            for e in encoders.values { e.fps = f }
            captureChanged = true
        }
        if let w = obj["width"] as? Int, let h = obj["height"] as? Int,
           (160...8192).contains(w), (90...8192).contains(h), (w & ~1 != width || h & ~1 != height) {
            width = w & ~1
            height = h & ~1
            userChoseSize = true
            lastFrame = nil
            captureChanged = true
        }
        if let b = obj["bitrateKbps"] as? Int, (200...100_000).contains(b) {
            bitrateKbps = b
            currentBitrate = b
            stableSeconds = 0
            for e in encoders.values { e.bitrateKbps = b }
        }
        if let a = obj["autoBitrate"] as? Bool { autoBitrate = a }
        if let q = obj["quality"] as? Double, (0.1...1.0).contains(q) { jpegQuality = q }
        if let codec = obj["codec"] as? String, ["hevc", "h264", "jpeg"].contains(codec) {
            let actual = (codec == "hevc" && !hevcSupported) ? "h264" : codec
            if actual != c.codec { c.codec = actual; c.needsKeyframe = true; keyRequested = true }
        }
        if let d = obj["display"] as? Int, CGDirectDisplayID(d) != currentDisplayID,
           let display = displays.first(where: { Int($0.displayID) == d }) {
            log("切換顯示器 → \(display.width)×\(display.height)")
            currentDisplayID = display.displayID
            userChoseSize = false
            Task { await self.startCapture(display: display) }
        }
        if captureChanged {
            log("設定變更:\(width)×\(height) @ \(fps) fps,上限 \(bitrateKbps) kbps\(autoBitrate ? "(自動)" : "")")
            updateCapture()
        }
        broadcastConfig()
    }

    private func currentConfig(for c: ClientConnection) -> [String: Any] {
        [
            "type": "config", "fps": fps, "width": width, "height": height, "bitrateKbps": bitrateKbps,
            "autoBitrate": autoBitrate, "quality": jpegQuality, "display": Int(currentDisplayID), "codec": c.codec,
        ]
    }

    private func broadcastConfig() {
        for c in clients.values where c.authenticated { c.sendText(Self.json(currentConfig(for: c))) }
    }

    private func sendHello(_ c: ClientConnection) {
        let list: [[String: Any]] = displays.map { d in
            ["id": Int(d.displayID), "name": "\(d.width)×\(d.height)\(d.displayID == CGMainDisplayID() ? "(主要)" : "")",
             "width": d.width, "height": d.height]
        }
        var codecs = ["h264", "jpeg"]
        if hevcSupported { codecs.insert("hevc", at: 0) }
        var hello: [String: Any] = [
            "type": "hello",
            "version": "2.0",
            "displays": list,
            "presets": presets,
            "fpsOptions": [5, 10, 15, 20, 24, 30, 60, 90, 120],
            "bitrateOptions": [1000, 2000, 3000, 4000, 6000, 8000, 12000, 16000, 24000, 30000, 40000],
            "codecs": codecs,
            "files": !files.roots.isEmpty,
            "testPattern": testPattern,
            "tailscaleLogin": c.tailscaleLogin ?? "",
            "os": "macos",
            "name": config.name,
            "peers": config.peers.map { ["name": $0.name, "url": $0.url] },
            "cmdAsCtrl": false,
        ]
        hello["current"] = currentConfig(for: c)
        c.sendText(Self.json(hello))
        if !testPattern {
            Task {
                if let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true) {
                    self.queue.async { self.displays = content.displays }
                }
            }
        }
    }

    private func clientsChanged() {
        let n = clients.values.filter { $0.authenticated }.count
        if n > 0 {
            var aid: IOPMAssertionID = 0
            IOPMAssertionDeclareUserActivity("MiniRemote 客戶端連線" as CFString, kIOPMUserActiveLocal, &aid)
            if displayAssertion == 0 {
                IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                                            IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                            "MiniRemote 正在串流" as CFString, &displayAssertion)
            }
            idleStopWork?.cancel()
            idleStopWork = nil
        } else {
            if displayAssertion != 0 { IOPMAssertionRelease(displayAssertion); displayAssertion = 0 }
            scheduleIdleStopIfNeeded()
        }
        updateCapture()
    }

    static func json(_ obj: [String: Any]) -> String {
        guard let d = try? JSONSerialization.data(withJSONObject: obj), let s = String(data: d, encoding: .utf8) else { return "{}" }
        return s
    }
}
