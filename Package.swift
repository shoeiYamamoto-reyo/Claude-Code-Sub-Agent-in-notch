// swift-tools-version: 6.0
// UI に依存しないロジック（AgentKit）と hook 中継 CLI（notch-hook）。
// Linux でも `swift build` / `swift test` できるように、AppKit / SwiftUI は使わない。
import PackageDescription

let package = Package(
    name: "AgentKit",
    platforms: [
        .macOS(.v15),
    ],
    products: [
        .library(name: "AgentKit", targets: ["AgentKit"]),
        .executable(name: "notch-hook", targets: ["notch-hook"]),
    ],
    targets: [
        .target(name: "AgentKit"),
        .executableTarget(
            name: "notch-hook",
            dependencies: ["AgentKit"]
        ),
        .testTarget(
            name: "AgentKitTests",
            dependencies: ["AgentKit"]
        ),
    ]
)
