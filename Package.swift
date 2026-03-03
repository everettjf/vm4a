// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "EasyVMCLI",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "EasyVMCore", targets: ["EasyVMCore"]),
        .executable(name: "easyvm", targets: ["easyvm"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0")
    ],
    targets: [
        .target(
            name: "EasyVMCore",
            path: "Sources/EasyVMCore"
        ),
        .executableTarget(
            name: "easyvm",
            dependencies: [
                "EasyVMCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser")
            ],
            path: "Sources/EasyVMCLI"
        ),
        .testTarget(
            name: "EasyVMCoreTests",
            dependencies: ["EasyVMCore"],
            path: "Tests/EasyVMCoreTests"
        )
    ]
)
