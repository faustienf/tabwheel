// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CmdTabWheel",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "CmdTabWheel",
            path: "Sources/CmdTabWheel"
        ),
        // `swift test`. Tests reach into the app itself (`@testable import CmdTabWheel`).
        .testTarget(
            name: "CmdTabWheelTests",
            dependencies: ["CmdTabWheel"],
            path: "Tests/CmdTabWheelTests"
        ),
    ]
)
