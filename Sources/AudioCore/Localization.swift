import Foundation

// 介面文字的翻譯。
//
// 原始碼裡寫的是繁體中文，它同時是翻譯的 key；英文翻譯放在 Resources/en.lproj/Localizable.strings。
// SwiftUI 的 Text("…")、Button("…") 等直接寫中文的地方，系統會自動拿去查表；
// 帶有變數、或是在程式邏輯裡組出來的字串，則要經過 L(…)。
// 新增或修改中文字串後，執行 `python3 Scripts/check-localization.py` 檢查有沒有漏翻。

/// 查翻譯。找不到就回傳原文。
public func L(_ key: String) -> String {
    Bundle.main.localizedString(forKey: key, value: key, table: nil)
}

/// 查翻譯後填入參數，格式符號與 `String(format:)` 相同（%@、%d、%.1f…）。
public func L(_ key: String, _ arguments: CVarArg...) -> String {
    String(format: L(key), locale: Locale.current, arguments: arguments)
}

/// 目前介面使用的語言。只有少數需要整段換掉（而不是逐句翻譯）的內容會用到，例如給 AI 的範本。
public enum AppLanguage: Sendable {
    case chinese
    case english

    public static var current: AppLanguage {
        Bundle.main.preferredLocalizations.first?.hasPrefix("en") == true ? .english : .chinese
    }
}
