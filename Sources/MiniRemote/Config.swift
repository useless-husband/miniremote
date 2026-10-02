import Foundation

struct PeerConfig: Codable {
    var name: String
    var url: String
}

/// 設定檔(~/MiniRemote/config.json)。缺少的欄位會用預設值。
struct AppConfig: Codable {
    var port: UInt16 = 8800
    var password: String = ""
    var fps: Int = 30
    var bitrateKbps: Int = 12000
    var autoBitrate: Bool = true
    var jpegQuality: Double = 0.6
    /// 0 = 原生像素(Retina 全解析度);例如 1080 = 啟動時挑高度不超過 1080 的預設檔
    var maxHeight: Int = 0
    /// false = 只接受 Tailscale(100.64.0.0/10、fd7a:115c:a1e0::/48)與本機的連線
    var allowLAN: Bool = false
    /// 非空時,經由 tailscale serve 進來的連線必須是這些帳號之一
    var allowedTailscaleLogins: [String] = []
    /// 檔案瀏覽器可以看的根目錄
    var fileRoots: [String] = ["~", "/Volumes"]
    /// 登入 token 幾天後失效
    var sessionDays: Int = 30
    /// 沒有人連線多少秒後停止擷取螢幕(省電);0 = 一直擷取
    var idleStopSeconds: Int = 60
    /// 這台在網頁上顯示的名字
    var name: String = "Mac mini"
    /// 其他可切換的電腦 [{"name": "...", "url": "https://..."}]
    var peers: [PeerConfig] = []

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        port = try c.decodeIfPresent(UInt16.self, forKey: .port) ?? 8800
        password = try c.decodeIfPresent(String.self, forKey: .password) ?? ""
        fps = try c.decodeIfPresent(Int.self, forKey: .fps) ?? 30
        bitrateKbps = try c.decodeIfPresent(Int.self, forKey: .bitrateKbps) ?? 12000
        autoBitrate = try c.decodeIfPresent(Bool.self, forKey: .autoBitrate) ?? true
        jpegQuality = try c.decodeIfPresent(Double.self, forKey: .jpegQuality) ?? 0.6
        maxHeight = try c.decodeIfPresent(Int.self, forKey: .maxHeight) ?? 0
        allowLAN = try c.decodeIfPresent(Bool.self, forKey: .allowLAN) ?? false
        allowedTailscaleLogins = try c.decodeIfPresent([String].self, forKey: .allowedTailscaleLogins) ?? []
        fileRoots = try c.decodeIfPresent([String].self, forKey: .fileRoots) ?? ["~", "/Volumes"]
        sessionDays = try c.decodeIfPresent(Int.self, forKey: .sessionDays) ?? 30
        idleStopSeconds = try c.decodeIfPresent(Int.self, forKey: .idleStopSeconds) ?? 60
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Mac mini"
        peers = try c.decodeIfPresent([PeerConfig].self, forKey: .peers) ?? []
    }

    static func load(from path: String) -> AppConfig {
        let url = URL(fileURLWithPath: path)
        guard let data = try? Data(contentsOf: url) else {
            log("找不到設定檔 \(path),使用預設值(沒有密碼!)")
            return AppConfig()
        }
        do {
            return try JSONDecoder().decode(AppConfig.self, from: data)
        } catch {
            log("設定檔格式錯誤 \(path):\(error),使用預設值")
            return AppConfig()
        }
    }
}
