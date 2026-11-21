// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Tonefleur",
    defaultLocalization: "zh-Hant",
    platforms: [.macOS(.v15)],
    dependencies: [
        // 自動更新：https://sparkle-project.org
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.4"),
    ],
    targets: [
        // 不依賴 UI 的音訊核心
        .target(
            name: "AudioCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // 選單列 App
        .executableTarget(
            name: "Tonefleur",
            dependencies: [
                "AudioCore",
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            path: "Sources/App",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "AudioCoreTests",
            dependencies: ["AudioCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
