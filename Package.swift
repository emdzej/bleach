// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "bleach",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "bleach", targets: ["bleach"]),
        .library(name: "BleachCore", targets: ["BleachCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0"),
        .package(url: "https://github.com/jpsim/Yams", from: "5.1.0"),
    ],
    targets: [
        .target(
            name: "BleachCore",
            dependencies: [.product(name: "Yams", package: "Yams")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .target(
            name: "BleachTUI",
            dependencies: ["BleachCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "bleach",
            dependencies: [
                "BleachCore",
                "BleachTUI",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "BleachCoreTests",
            dependencies: ["BleachCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
