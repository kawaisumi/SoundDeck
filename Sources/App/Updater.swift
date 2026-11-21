import AppKit
import Combine
import Sparkle

/// 自動更新（Sparkle）。檢查 Info.plist 的 `SUFeedURL` 指向的 appcast，有新版時提示下載安裝。
///
/// 更新檔用 EdDSA 金鑰簽章，Info.plist 的 `SUPublicEDKey` 是對應的公鑰。還沒設定金鑰時
/// （開發中、或自己建置的版本）不啟動更新器，避免 Sparkle 一啟動就跳出錯誤視窗。
final class Updater: ObservableObject {
    /// 這個版本有沒有設定好自動更新。
    let isConfigured: Bool
    @Published private(set) var canCheckForUpdates = false

    private let controller: SPUStandardUpdaterController
    private var observation: NSKeyValueObservation?

    init() {
        controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)

        let info = Bundle.main.infoDictionary ?? [:]
        let key = (info["SUPublicEDKey"] as? String ?? "").trimmingCharacters(in: .whitespaces)
        let feed = info["SUFeedURL"] as? String ?? ""
        isConfigured = !key.isEmpty && !feed.isEmpty

        guard isConfigured else { return }
        controller.startUpdater()
        observation = controller.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] updater, _ in
            DispatchQueue.main.async { self?.canCheckForUpdates = updater.canCheckForUpdates }
        }
    }

    func checkForUpdates() {
        // 選單列 App 不會自己成為前景，先拉到前面，更新視窗才不會被別的視窗蓋住。
        NSApplication.shared.activate(ignoringOtherApps: true)
        controller.checkForUpdates(nil)
    }
}
