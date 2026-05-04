// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "VM4ACLI",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "VM4ACore", targets: ["VM4ACore"]),
        .executable(name: "vm4a", targets: ["vm4a"]),
        .executable(name: "vm4a-guest", targets: ["vm4a-guest"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0")
    ],
    targets: [
        .target(
            name: "VM4ACore",
            path: "Sources/VM4ACore"
        ),
        .executableTarget(
            name: "vm4a",
            dependencies: [
                "VM4ACore",
                .product(name: "ArgumentParser", package: "swift-argument-parser")
            ],
            path: "Sources/VM4ACLI"
        ),
        .executableTarget(
            name: "vm4a-guest",
            dependencies: ["VM4ACore"],
            path: "Sources/VM4AGuest"
        ),
        .testTarget(
            name: "VM4ACoreTests",
            dependencies: ["VM4ACore"],
            path: "Tests/VM4ACoreTests"
        )
    ]
)
