import Foundation
import Network
import CryptoKit

struct HTTPRequest {
    let method: String
    let path: String
    let query: [String: String]
    let headers: [String: String]   // key 全部小寫

    var cookies: [String: String] {
        var out: [String: String] = [:]
        for part in (headers["cookie"] ?? "").components(separatedBy: ";") {
            let kv = part.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if kv.count == 2 { out[kv[0]] = kv[1] }
        }
        return out
    }
}

enum HTTPResponse {
    case content(status: String, contentType: String, body: Data, headers: [String: String] = [:])
    /// 串流送出檔案(不會整個讀進記憶體);deleteAfter 用於暫存 zip
    case file(path: String, downloadName: String?, deleteAfter: Bool)
    /// 接收上傳內容寫到 destination,完成後呼叫 then 產生回應
    case upload(destination: String, then: (Bool) -> HTTPResponse)

    static func json(_ obj: Any, status: String = "200 OK") -> HTTPResponse {
        let data = (try? JSONSerialization.data(withJSONObject: obj)) ?? Data("{}".utf8)
        return .content(status: status, contentType: "application/json; charset=utf-8", body: data)
    }
    static func text(_ s: String, status: String) -> HTTPResponse {
        .content(status: status, contentType: "text/plain; charset=utf-8", body: Data(s.utf8))
    }
}

/// 一條 TCP 連線:先當 HTTP 處理,遇到 WebSocket 升級就切成 WebSocket 模式
final class ClientConnection {
    let id = UUID()
    let remote: String
    let remoteIsLoopback: Bool
    let remoteIsTailscale: Bool
    private let conn: NWConnection
    private let queue: DispatchQueue
    private var buffer = [UInt8]()
    private var fragmentBuffer = [UInt8]()
    private var fragmentOpcode: UInt8 = 0

    private enum Mode { case http, websocket, uploading(FileHandle, remaining: Int, then: (Bool) -> HTTPResponse), closing }
    private var mode = Mode.http

    private(set) var closed = false
    var authenticated = false
    /// 由 tailscale serve 帶進來的帳號(只在本機連線時可信)
    private(set) var tailscaleLogin: String?
    /// 這個客戶端想要的影像編碎:"hevc"、"h264" 或 "jpeg"
    var codec = "hevc"
    var paused = false
    var needsKeyframe = true
    private(set) var pendingBytes = 0
    private(set) var pendingFrames = 0
    var droppedFrames = 0
    var sessionToken: String?

    var onText: ((ClientConnection, String) -> Void)?
    var onClose: ((ClientConnection) -> Void)?
    var httpHandler: ((ClientConnection, HTTPRequest, @escaping (HTTPResponse) -> Void) -> Void)?

    init(conn: NWConnection, queue: DispatchQueue) {
        self.conn = conn
        self.queue = queue
        var host = "?"
        if case let .hostPort(h, _) = conn.endpoint { host = "\(h)".components(separatedBy: "%").first ?? "\(h)" }
        remote = host
        remoteIsLoopback = host == "127.0.0.1" || host == "::1" || host.hasPrefix("::ffff:127.")
        remoteIsTailscale = Self.isTailscaleAddress(host)
    }

    /// Tailscale 位址:100.64.0.0/10 或 fd7a:115c:a1e0::/48
    static func isTailscaleAddress(_ host: String) -> Bool {
        var h = host
        if h.hasPrefix("::ffff:") { h = String(h.dropFirst(7)) }
        let v4 = h.split(separator: ".").compactMap { Int($0) }
        if v4.count == 4 { return v4[0] == 100 && (64...127).contains(v4[1]) }
        return h.lowercased().hasPrefix("fd7a:115c:a1e0:")
    }

    func start() {
        conn.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: self?.finish()
            default: break
            }
        }
        conn.start(queue: queue)
        receive()
    }

    private func receive() {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { [weak self] data, _, isComplete, error in
            guard let self = self, !self.closed else { return }
            if let d = data, !d.isEmpty {
                self.buffer.append(contentsOf: d)
                self.process()
            }
            if error != nil || isComplete { self.finish(); return }
            if !self.closed { self.receive() }
        }
    }

    private func process() {
        switch mode {
        case .http: handleHTTP()
        case .websocket: parseFrames()
        case .uploading: consumeUpload()
        case .closing: buffer.removeAll()
        }
    }

    // MARK: HTTP

    private func handleHTTP() {
        guard let end = findHeaderEnd() else {
            if buffer.count > 65536 { finish() }
            return
        }
        let header = String(decoding: buffer[0..<end], as: UTF8.self)
        buffer.removeFirst(end + 4)
        let lines = header.components(separatedBy: "\r\n")
        let parts = lines.first?.split(separator: " ") ?? []
        guard parts.count >= 2 else { finish(); return }
        let method = String(parts[0]).uppercased()
        let target = String(parts[1])
        var headers = [String: String]()
        for line in lines.dropFirst() {
            guard let idx = line.firstIndex(of: ":") else { continue }
            headers[line[..<idx].trimmingCharacters(in: .whitespaces).lowercased()] =
                line[line.index(after: idx)...].trimmingCharacters(in: .whitespaces)
        }
        if remoteIsLoopback, let login = headers["tailscale-user-login"], !login.isEmpty { tailscaleLogin = login }

        var path = target
        var query: [String: String] = [:]
        if let q = target.firstIndex(of: "?") {
            path = String(target[..<q])
            for pair in target[target.index(after: q)...].split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1).map(String.init)
                let k = kv[0].removingPercentEncoding ?? kv[0]
                let v = kv.count > 1 ? (kv[1].replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? kv[1]) : ""
                query[k] = v
            }
        }
        let request = HTTPRequest(method: method, path: path, query: query, headers: headers)
        rememberLength(headers)

        if headers["upgrade"]?.lowercased() == "websocket", let key = headers["sec-websocket-key"] {
            // 防止其他網站的網頁偷偷連我們的 WebSocket
            if let origin = headers["origin"], let host = headers["host"],
               let originHost = URL(string: origin)?.host, !host.lowercased().hasPrefix(originHost.lowercased()) {
                respond(.text("forbidden origin", status: "403 Forbidden"))
                return
            }
            let accept = Data(Insecure.SHA1.hash(data: Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8))).base64EncodedString()
            let resp = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: \(accept)\r\n\r\n"
            mode = .websocket
            conn.send(content: Data(resp.utf8), completion: .contentProcessed({ _ in }))
            if !buffer.isEmpty { parseFrames() }
            return
        }

        mode = .closing
        guard let handler = httpHandler else { respond(.text("not found", status: "404 Not Found")); return }
        handler(self, request) { [weak self] response in
            self?.queue.async { self?.respond(response) }
        }
    }

    func respond(_ response: HTTPResponse) {
        guard !closed else { return }
        switch response {
        case let .content(status, contentType, body, extra):
            var head = "HTTP/1.1 \(status)\r\nContent-Type: \(contentType)\r\nContent-Length: \(body.count)\r\n"
            head += "Cache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\nConnection: close\r\n"
            for (k, v) in extra { head += "\(k): \(v)\r\n" }
            head += "\r\n"
            var data = Data(head.utf8)
            data.append(body)
            conn.send(content: data, completion: .contentProcessed({ [weak self] _ in self?.finish() }))
        case let .file(path, downloadName, deleteAfter):
            streamFile(path: path, downloadName: downloadName, deleteAfter: deleteAfter)
        case let .upload(destination, then):
            beginUpload(destination: destination, then: then)
        }
    }

    private func streamFile(path: String, downloadName: String?, deleteAfter: Bool) {
        guard let fh = FileHandle(forReadingAtPath: path),
              let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attrs[.size] as? Int else {
            respond(.text("not found", status: "404 Not Found")); return
        }
        let mime = downloadName == nil ? "application/octet-stream" : "application/octet-stream"
        var head = "HTTP/1.1 200 OK\r\nContent-Type: \(mime)\r\nContent-Length: \(size)\r\n"
        head += "Cache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\nConnection: close\r\n"
        if let name = downloadName {
            let enc = name.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "file"
            head += "Content-Disposition: attachment; filename*=UTF-8''\(enc)\r\n"
        }
        head += "\r\n"
        conn.send(content: Data(head.utf8), completion: .contentProcessed({ [weak self] err in
            if err != nil { self?.finish(); Self.cleanup(fh, path, deleteAfter); return }
            self?.sendChunk(fh, path: path, deleteAfter: deleteAfter)
        }))
    }

    private func sendChunk(_ fh: FileHandle, path: String, deleteAfter: Bool) {
        guard !closed else { Self.cleanup(fh, path, deleteAfter); return }
        let chunk = fh.readData(ofLength: 1 << 19)
        if chunk.isEmpty {
            Self.cleanup(fh, path, deleteAfter)
            conn.send(content: nil, contentContext: .finalMessage, isComplete: true,
                      completion: .contentProcessed({ [weak self] _ in self?.finish() }))
            return
        }
        conn.send(content: chunk, completion: .contentProcessed({ [weak self] err in
            if err != nil { self?.finish(); Self.cleanup(fh, path, deleteAfter); return }
            self?.sendChunk(fh, path: path, deleteAfter: deleteAfter)
        }))
    }

    private static func cleanup(_ fh: FileHandle, _ path: String, _ delete: Bool) {
        try? fh.close()
        if delete { try? FileManager.default.removeItem(atPath: path) }
    }

    private var pendingRequestLength: Int?

    private func beginUpload(destination: String, then: @escaping (Bool) -> HTTPResponse) {
        guard let len = pendingRequestLength else { respond(.text("length required", status: "411 Length Required")); return }
        FileManager.default.createFile(atPath: destination, contents: nil)
        guard let fh = FileHandle(forWritingAtPath: destination) else {
            respond(.text("cannot write", status: "500 Internal Server Error")); return
        }
        mode = .uploading(fh, remaining: len, then: then)
        consumeUpload()
    }

    private func consumeUpload() {
        guard case let .uploading(fh, remaining, then) = mode else { return }
        var left = remaining
        if !buffer.isEmpty {
            let take = min(left, buffer.count)
            fh.write(Data(buffer[0..<take]))
            buffer.removeFirst(take)
            left -= take
            mode = .uploading(fh, remaining: left, then: then)
        }
        if left <= 0 {
            try? fh.close()
            mode = .closing
            respond(then(true))
        }
    }

    /// handleHTTP 呼叫 handler 前先記下 Content-Length,給上傳用
    private func rememberLength(_ headers: [String: String]) {
        pendingRequestLength = headers["content-length"].flatMap { Int($0) }
    }

    private func findHeaderEnd() -> Int? {
        guard buffer.count >= 4 else { return nil }
        var i = 0
        while i + 3 < buffer.count {
            if buffer[i] == 13, buffer[i + 1] == 10, buffer[i + 2] == 13, buffer[i + 3] == 10 { return i }
            i += 1
        }
        return nil
    }

    // MARK: WebSocket 解析(RFC 6455)

    private func parseFrames() {
        while !closed {
            guard buffer.count >= 2 else { return }
            let b0 = buffer[0], b1 = buffer[1]
            let fin = (b0 & 0x80) != 0
            let opcode = b0 & 0x0F
            let masked = (b1 & 0x80) != 0
            var length = Int(b1 & 0x7F)
            var offset = 2
            if length == 126 {
                guard buffer.count >= 4 else { return }
                length = Int(buffer[2]) << 8 | Int(buffer[3])
                offset = 4
            } else if length == 127 {
                guard buffer.count >= 10 else { return }
                var l: UInt64 = 0
                for i in 2..<10 { l = (l << 8) | UInt64(buffer[i]) }
                guard l < 8_000_000 else { finish(); return }
                length = Int(l)
                offset = 10
            }
            var mask: [UInt8] = []
            if masked {
                guard buffer.count >= offset + 4 else { return }
                mask = Array(buffer[offset..<offset + 4])
                offset += 4
            }
            guard buffer.count >= offset + length else { return }
            var payload = Array(buffer[offset..<offset + length])
            if masked { for i in 0..<payload.count { payload[i] ^= mask[i & 3] } }
            buffer.removeFirst(offset + length)

            switch opcode {
            case 0x0:
                fragmentBuffer.append(contentsOf: payload)
                if fin { deliver(fragmentOpcode, fragmentBuffer); fragmentBuffer = [] }
            case 0x1, 0x2:
                if fin { deliver(opcode, payload) } else { fragmentOpcode = opcode; fragmentBuffer = payload }
            case 0x8:
                sendRaw(opcode: 0x8, payload: Data())
                finish()
                return
            case 0x9:
                sendRaw(opcode: 0xA, payload: Data(payload))
            default:
                break
            }
        }
    }

    private func deliver(_ opcode: UInt8, _ payload: [UInt8]) {
        guard opcode == 0x1 else { return }
        onText?(self, String(decoding: payload, as: UTF8.self))
    }

    // MARK: 送出

    func sendText(_ text: String) { sendRaw(opcode: 0x1, payload: Data(text.utf8)) }
    /// 送出最後一則訊息後再關閉(確保對方收得到,例如「密碼錯誤」)
    func sendTextThenClose(_ text: String) { sendRaw(opcode: 0x1, payload: Data(text.utf8), thenClose: true) }
    func sendBinary(_ data: Data) { sendRaw(opcode: 0x2, payload: data) }

    private func sendRaw(opcode: UInt8, payload: Data, thenClose: Bool = false) {
        guard !closed, case .websocket = mode else { return }
        var frame = Data(capacity: payload.count + 10)
        frame.append(0x80 | opcode)
        let n = payload.count
        if n < 126 {
            frame.append(UInt8(n))
        } else if n < 65536 {
            frame.append(126)
            frame.append(UInt8(n >> 8)); frame.append(UInt8(n & 0xFF))
        } else {
            frame.append(127)
            for i in (0..<8).reversed() { frame.append(UInt8((UInt64(n) >> (UInt64(i) * 8)) & 0xFF)) }
        }
        frame.append(payload)
        let size = frame.count
        pendingBytes += size
        pendingFrames += 1
        conn.send(content: frame, completion: .contentProcessed({ [weak self] error in
            guard let self = self else { return }
            self.pendingBytes -= size
            self.pendingFrames -= 1
            if error != nil || thenClose { self.finish() }
        }))
    }

    func finish() {
        guard !closed else { return }
        closed = true
        if case let .uploading(fh, _, then) = mode { try? fh.close(); _ = then(false) }
        conn.cancel()
        onClose?(self)
    }
}
