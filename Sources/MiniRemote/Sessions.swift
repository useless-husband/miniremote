import Foundation
import CryptoKit

/// 登入 token 與密碼錯誤鎖定。token 只存 SHA-256 雜湊,檔案被讀走也無法直接使用。
final class SessionStore {
    private let fileURL: URL
    private let days: Int
    private var sessions: [[String: Any]] = []
    private var failures: [String: (count: Int, lockedUntil: Date)] = [:]

    static let maxFailures = 8
    static let lockMinutes = 15.0

    init(directory: URL, days: Int) {
        fileURL = directory.appendingPathComponent("sessions.json")
        self.days = days
        load()
    }

    // MARK: token

    func issue(label: String) -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let token = bytes.map { String(format: "%02x", $0) }.joined()
        sessions.append([
            "hash": Self.sha256Hex(token),
            "created": Date().timeIntervalSince1970,
            "lastUsed": Date().timeIntervalSince1970,
            "label": label,
        ])
        save()
        return token
    }

    func validate(_ token: String) -> Bool {
        prune()
        let h = Self.sha256Hex(token)
        for i in sessions.indices where Self.constantTimeEqual(sessions[i]["hash"] as? String ?? "", h) {
            sessions[i]["lastUsed"] = Date().timeIntervalSince1970
            return true
        }
        return false
    }

    func revoke(_ token: String) {
        let h = Self.sha256Hex(token)
        sessions.removeAll { ($0["hash"] as? String) == h }
        save()
    }

    func revokeAll() { sessions = []; save() }

    var count: Int { sessions.count }

    private func prune() {
        let cutoff = Date().timeIntervalSince1970 - Double(days) * 86400
        let before = sessions.count
        sessions.removeAll { ($0["created"] as? Double ?? 0) < cutoff }
        if sessions.count != before { save() }
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return }
        sessions = arr
    }

    private func save() {
        guard let data = try? JSONSerialization.data(withJSONObject: sessions, options: [.prettyPrinted]) else { return }
        try? data.write(to: fileURL, options: [.atomic])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }

    // MARK: 密碼

    static func passwordMatches(_ given: String, expected: String) -> Bool {
        constantTimeEqual(sha256Hex(given), sha256Hex(expected))
    }

    static func sha256Hex(_ s: String) -> String {
        SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func constantTimeEqual(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<x.count { diff |= x[i] ^ y[i] }
        return diff == 0
    }

    // MARK: 鎖定

    func lockedSeconds(for ip: String) -> Int {
        guard let f = failures[ip], f.count >= Self.maxFailures else { return 0 }
        let remain = f.lockedUntil.timeIntervalSinceNow
        if remain <= 0 { failures[ip] = nil; return 0 }
        return Int(remain.rounded(.up))
    }

    /// 回傳目前累計失敗次數
    func recordFailure(for ip: String) -> Int {
        var f = failures[ip] ?? (count: 0, lockedUntil: .distantPast)
        f.count += 1
        if f.count >= Self.maxFailures { f.lockedUntil = Date().addingTimeInterval(Self.lockMinutes * 60) }
        failures[ip] = f
        return f.count
    }

    func clearFailures(for ip: String) { failures[ip] = nil }
}
