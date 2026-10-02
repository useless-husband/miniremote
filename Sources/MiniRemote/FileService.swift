import Foundation
import UniformTypeIdentifiers

/// 檔案瀏覽/下載/上傳,只允許在設定的根目錄之內
final class FileService {
    let roots: [String]

    init(roots: [String]) {
        self.roots = roots.map { NSString(string: $0).expandingTildeInPath }
            .map { URL(fileURLWithPath: $0).standardizedFileURL.path }
            .filter { FileManager.default.fileExists(atPath: $0) }
    }

    /// 把使用者給的路徑正規化(解掉 .. 與符號連結),不在根目錄內就回 nil
    func resolve(_ raw: String) -> String? {
        guard !raw.isEmpty else { return nil }
        let expanded = NSString(string: raw).expandingTildeInPath
        let url = URL(fileURLWithPath: expanded).standardizedFileURL
        let resolved = url.resolvingSymlinksInPath().path
        for root in roots where resolved == root || resolved.hasPrefix(root + "/") { return resolved }
        return nil
    }

    func isDirectory(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }

    /// 列出目錄;path 為空字串時列出所有根目錄
    func list(_ raw: String, showHidden: Bool) -> [String: Any]? {
        if raw.isEmpty {
            let entries: [[String: Any]] = roots.map { r in
                ["name": r == NSHomeDirectory() ? "家目錄(\(NSHomeDirectory()))" : r, "path": r, "isDir": true, "size": 0, "mtime": 0]
            }
            return ["path": "", "parent": NSNull(), "entries": entries]
        }
        guard let path = resolve(raw), isDirectory(path) else { return nil }
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: path) else { return nil }
        var entries: [[String: Any]] = []
        for name in names {
            if !showHidden && name.hasPrefix(".") { continue }
            let full = (path as NSString).appendingPathComponent(name)
            guard let attrs = try? fm.attributesOfItem(atPath: full) else { continue }
            let type = attrs[.type] as? FileAttributeType
            var isDir = type == .typeDirectory
            if type == .typeSymbolicLink { isDir = isDirectory(full) }
            // .app 等套件視為檔案(下載會打包)
            let isPackage = isDir && (name.hasSuffix(".app") || name.hasSuffix(".bundle") || name.hasSuffix(".framework"))
            entries.append([
                "name": name,
                "path": full,
                "isDir": isDir && !isPackage,
                "isPackage": isPackage,
                "size": (attrs[.size] as? Int) ?? 0,
                "mtime": ((attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0),
            ])
        }
        entries.sort {
            let a = $0["isDir"] as? Bool ?? false, b = $1["isDir"] as? Bool ?? false
            if a != b { return a }
            return ($0["name"] as! String).localizedStandardCompare($1["name"] as! String) == .orderedAscending
        }
        let isRoot = roots.contains(path)
        let parent: Any = isRoot ? "" : (path as NSString).deletingLastPathComponent
        return ["path": path, "parent": parent, "entries": entries]
    }

    /// 把資料夾壓成 zip(放在暫存區),完成後回傳 zip 路徑
    func zipDirectory(_ path: String, completion: @escaping (String?) -> Void) {
        let name = (path as NSString).lastPathComponent
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("miniremote-\(UUID().uuidString)-\(name).zip").path
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        p.arguments = ["-c", "-k", "--sequesterRsrc", "--keepParent", path, tmp]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        p.terminationHandler = { proc in
            completion(proc.terminationStatus == 0 ? tmp : nil)
        }
        do { try p.run() } catch { completion(nil) }
    }

    func mimeType(for path: String) -> String {
        let ext = (path as NSString).pathExtension
        if let t = UTType(filenameExtension: ext), let mime = t.preferredMIMEType { return mime }
        return "application/octet-stream"
    }

    /// 上傳時避免覆蓋:同名就變成「名稱 (2).副檔名」
    func uniqueDestination(directory: String, name: String) -> String? {
        let safe = (name as NSString).lastPathComponent.replacingOccurrences(of: "/", with: "_")
        guard !safe.isEmpty, safe != ".", safe != ".." else { return nil }
        var candidate = (directory as NSString).appendingPathComponent(safe)
        let base = (safe as NSString).deletingPathExtension, ext = (safe as NSString).pathExtension
        var n = 2
        while FileManager.default.fileExists(atPath: candidate) {
            let newName = ext.isEmpty ? "\(base) (\(n))" : "\(base) (\(n)).\(ext)"
            candidate = (directory as NSString).appendingPathComponent(newName)
            n += 1
        }
        return candidate
    }
}
