// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "NewAPIAccountMonitor",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(
            name: "NewAPIAccountMonitor",
            targets: ["NewAPIAccountMonitor"]
        )
    ],
    targets: [
        .executableTarget(
            name: "NewAPIAccountMonitor",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("Security")
            ]
        )
    ]
)
