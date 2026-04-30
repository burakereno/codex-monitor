// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "CodexStatus",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "CodexStatus", targets: ["CodexStatus"])
    ],
    targets: [
        .executableTarget(
            name: "CodexStatus",
            path: "Sources/CodexStatus",
            resources: [
                .process("Resources")
            ]
        )
    ]
)
