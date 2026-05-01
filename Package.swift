// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "CodexMonitor",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "CodexMonitor", targets: ["CodexMonitor"])
    ],
    targets: [
        .executableTarget(
            name: "CodexMonitor",
            path: "Sources/CodexMonitor",
            resources: [
                .process("Resources")
            ]
        ),
        .testTarget(
            name: "CodexMonitorTests",
            dependencies: ["CodexMonitor"],
            path: "Tests/CodexMonitorTests"
        )
    ]
)
