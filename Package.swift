// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MiniRemote",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "MiniRemote",
            path: "Sources/MiniRemote",
            swiftSettings: [.unsafeFlags(["-Ounchecked"])],
            linkerSettings: [
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("VideoToolbox"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("CoreImage"),
                .linkedFramework("Network"),
                .linkedFramework("IOKit"),
                .linkedFramework("ApplicationServices"),
            ]
        )
    ]
)
