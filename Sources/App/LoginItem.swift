import AudioCore
import Combine
import Foundation
import ServiceManagement

/// 「開機時自動啟動」的狀態。實際的登入項目由系統管理，
/// 使用者也可以在「系統設定 → 一般 → 登入項目與延伸功能」裡看到並關閉它。
final class LoginItem: ObservableObject {
    @Published private(set) var isEnabled = false
    /// 需要讓使用者知道的事（設定失敗、需要到系統設定核准等）。
    @Published private(set) var message: String?

    init() {
        refresh()
    }

    func refresh() {
        switch SMAppService.mainApp.status {
        case .enabled:
            isEnabled = true
            message = nil
        case .requiresApproval:
            isEnabled = false
            message = L("需要到「系統設定 → 一般 → 登入項目與延伸功能」允許 Tonefleur。")
        default:
            isEnabled = false
        }
    }

    func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            message = nil
        } catch {
            message = L("無法變更登入項目：%@", error.localizedDescription)
        }
        let failure = message
        refresh()
        if let failure, message == nil { message = failure }

        // 登入項目記的是 App 目前的位置；從建置資料夾執行時，重新建置或搬動後可能失效。
        if isEnabled, !Bundle.main.bundlePath.hasPrefix("/Applications/") {
            message = L("目前是從建置資料夾執行。建議先用 Scripts/install.sh 安裝到「應用程式」再開啟這個選項，否則重新建置後可能失效。")
        }
    }
}
