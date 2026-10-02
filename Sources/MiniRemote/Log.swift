import Foundation

private let logFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd HH:mm:ss"
    return f
}()

func log(_ message: String) {
    print("[\(logFormatter.string(from: Date()))] \(message)")
}
