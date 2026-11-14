// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SoundDeck",
    defaultLocalization: "zh-Hant",
    platforms: [.macOS("14.2")],
    targets: [
        // 不依賴 UI 的音訊核心
        .target(
            name: "AudioCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // 選單列 App
        .executableTarget(
            name: "SoundDeck",
            dependencies: ["AudioCore"],
            path: "Sources/App",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
