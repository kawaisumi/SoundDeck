import AppKit
import Combine
import Sparkle

/// 自動更新（Sparkle）。檢查 Info.plist 的 `SUFeedURL` 指向的 appcast，有新版時提示下載安裝。
///
/// Tonefleur 唯一會連網的地方就是這裡：檢查更新時下載 appcast.xml，有新版時下載 dmg。
/// 不會傳送任何系統資訊（Info.plist 的 SUEnableSystemProfiling 為 false）。
/// 使用者關掉「自動檢查更新」後，除非手動按「檢查更新…」，Tonefleur 完全不會連網。
///
/// 更新檔用 EdDSA 金鑰簽章，Info.plist 的 `SUPublicEDKey` 是對應的公鑰。還沒設定金鑰時
/// （開發中、或自己建置的版本）不啟動更新器，避免 Sparkle 一啟動就跳出錯誤視窗。
final class Updater: ObservableObject {
    /// 這個版本有沒有設定好自動更新。
    let isConfigured: Bool
    @Published private(set) var canCheckForUpdates = false

    /// 是否每天自動檢查一次更新。由 Sparkle 自己存在 UserDefaults。
    var automaticallyChecksForUpdates: Bool {
        get { isConfigured && controller.updater.automaticallyChecksForUpdates }
        set {
            guard isConfigured else { return }
            objectWillChange.send()
            controller.updater.automaticallyChecksForUpdates = newValue
        }
    }

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
