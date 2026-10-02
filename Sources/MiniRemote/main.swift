import Foundation

setvbuf(stdout, nil, _IOLBF, 0)

var configPath = NSString(string: "~/MiniRemote/config.json").expandingTildeInPath
var testPattern = false
var args = Array(CommandLine.arguments.dropFirst())
while !args.isEmpty {
    let a = args.removeFirst()
    switch a {
    case "--config":
        if !args.isEmpty { configPath = args.removeFirst() }
    case "--test-pattern":
        testPattern = true
    case "-h", "--help":
        print("用法:MiniRemote [--config 路徑] [--test-pattern]")
        exit(0)
    default:
        break
    }
}

let config = AppConfig.load(from: configPath)
log("MiniRemote 啟動,設定檔 \(configPath),port \(config.port)\(config.password.isEmpty ? ",⚠️ 沒有設定密碼" : "")\(testPattern ? ",測試圖樣模式" : "")")
let server = RemoteServer(config: config, configPath: configPath, testPattern: testPattern)
server.start()
dispatchMain()
