import Foundation

/// EQ 設定的文字格式：Equalizer APO 的參數式 EQ 格式，也是 AutoEQ `ParametricEQ.txt` 使用的格式。
///
///     # 名稱: 樂團
///     Preamp: -4.0 dB
///     Filter 1: ON LSC Fc 90 Hz Gain 3.0 dB Q 0.71
///     Filter 2: ON PK Fc 250 Hz Gain -1.5 dB Q 1.40
///
/// 用同一種格式處理三件事：匯入 AutoEQ 的耳機校正檔、匯入 AI 依範本產生的參數、匯出目前的設定。
/// 解析時只看認得的行，其他文字（AI 的說明、Markdown 的程式碼區塊標記）一律略過，
/// 所以 AI 的整段回覆可以直接貼進來。
public enum EQTextFormat {
    public struct Parsed: Equatable, Sendable {
        /// `# 名稱:` 或 `# Name:` 行指定的名稱。
        public var name: String?
        /// 檔案裡寫的前級增益（dB）。只供參考，匯入後改由自動補償計算。
        public var preampDB: Double?
        public var bands: [EQBand]
        /// 解析時做過的調整（數值超出範圍、不支援的類型、頻段太多等），要讓使用者知道。
        public var warnings: [String]
    }

    public enum ParseError: Error, Equatable, CustomStringConvertible {
        case noFilters

        public var description: String {
            switch self {
            case .noFilters:
                return L("找不到任何濾波器設定。內容需要有像「Filter 1: ON PK Fc 1000 Hz Gain 2.0 dB Q 1.0」這樣的行。")
            }
        }
    }

    // MARK: - 解析

    public static func parse(_ text: String) throws -> Parsed {
        var result = Parsed(name: nil, preampDB: nil, bands: [], warnings: [])
        var skippedForLimit = 0

        for rawLine in text.components(separatedBy: .newlines) {
            // 全形冒號、全形空白、全形減號都當成一般符號處理，AI 有時會寫成全形。
            let line = rawLine
                .replacingOccurrences(of: "：", with: ":")
                .replacingOccurrences(of: "\u{3000}", with: " ")
                .replacingOccurrences(of: "−", with: "-")
                .trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }

            if let name = firstMatch(#"^#+\s*(?:名稱|名称|Name)\s*:\s*(.+)$"#, in: line) {
                if result.name == nil {
                    result.name = name.trimmingCharacters(in: .whitespaces)
                }
                continue
            }

            if let preamp = firstMatch(#"^Preamp\s*:\s*([-+]?[0-9]*\.?[0-9]+)\s*dB"#, in: line) {
                result.preampDB = Double(preamp)
                continue
            }

            guard line.range(of: #"^Filter\s*\d*\s*:"#, options: [.regularExpression, .caseInsensitive]) != nil else {
                continue
            }
            switch parseFilter(line) {
            case .band(let band, let warnings):
                if result.bands.count < EQSettings.maxBands {
                    result.bands.append(band)
                    result.warnings += warnings
                } else {
                    skippedForLimit += 1
                }
            case .skipped(let warning):
                result.warnings.append(warning)
            }
        }

        if skippedForLimit > 0 {
            result.warnings.append(L("Tonefleur 最多 %d 個頻段，後面 %d 個沒有匯入。", EQSettings.maxBands, skippedForLimit))
        }
        guard !result.bands.isEmpty else { throw ParseError.noFilters }
        return result
    }

    private enum FilterResult {
        case band(EQBand, warnings: [String])
        case skipped(String)
    }

    private static func parseFilter(_ line: String) -> FilterResult {
        let label = firstMatch(#"^(Filter\s*\d*)"#, in: line) ?? "Filter"
        guard let state = firstMatch(#":\s*(ON|OFF)\b"#, in: line)?.uppercased(),
              let code = firstMatch(#":\s*(?:ON|OFF)\s+([A-Za-z]+)"#, in: line)?.uppercased()
        else {
            return .skipped(L("%@：看不懂這一行，已略過。", label))
        }
        guard let kind = kind(forCode: code) else {
            return .skipped(L("%@：Tonefleur 不支援「%@」類型，已略過。", label, code))
        }
        guard let frequencyText = firstMatch(#"\bFc\s+([0-9]*\.?[0-9]+)\s*(?:Hz)?"#, in: line),
              let frequency = Double(frequencyText)
        else {
            return .skipped(L("%@：缺少頻率（Fc），已略過。", label))
        }

        var warnings: [String] = []
        let gain = firstMatch(#"\bGain\s+([-+]?[0-9]*\.?[0-9]+)"#, in: line).flatMap(Double.init) ?? 0
        let q: Double
        if let qText = firstMatch(#"\bQ\s+([0-9]*\.?[0-9]+)"#, in: line), let parsed = Double(qText) {
            q = parsed
        } else {
            q = kind == .lowShelf || kind == .highShelf || kind == .highPass || kind == .lowPass ? 0.71 : 1
            warnings.append(L("%@：沒有 Q 值，使用 %@。", label, format(q, decimals: 2)))
        }

        let band = EQBand(kind: kind, frequency: frequency, gainDB: kind.hasGain ? gain : 0, q: q, isEnabled: state == "ON")
        let clamped = band.clamped
        if clamped.frequency != band.frequency {
            warnings.append(L("%@：頻率超出 20–20000 Hz，已調整為 %@ Hz。", label, format(clamped.frequency, decimals: 0)))
        }
        if clamped.gainDB != band.gainDB {
            warnings.append(L("%@：增益超出 ±18 dB，已調整為 %@ dB。", label, format(clamped.gainDB, decimals: 1)))
        }
        if clamped.q != band.q {
            warnings.append(L("%@：Q 值超出 0.1–18，已調整為 %@。", label, format(clamped.q, decimals: 2)))
        }
        return .band(clamped, warnings: warnings)
    }

    private static func kind(forCode code: String) -> EQBand.Kind? {
        switch code {
        case "PK", "PEQ", "PEAK": return .peak
        case "LS", "LSC", "LSQ", "LOWSHELF": return .lowShelf
        case "HS", "HSC", "HSQ", "HIGHSHELF": return .highShelf
        case "HP", "HPQ", "HIGHPASS": return .highPass
        case "LP", "LPQ", "LOWPASS": return .lowPass
        case "NO", "NOTCH": return .notch
        default: return nil
        }
    }

    private static func code(for kind: EQBand.Kind) -> String {
        switch kind {
        case .peak: return "PK"
        case .lowShelf: return "LSC"
        case .highShelf: return "HSC"
        case .highPass: return "HP"
        case .lowPass: return "LP"
        case .notch: return "NO"
        }
    }

    private static func firstMatch(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: text)
        else { return nil }
        return String(text[range])
    }

    // MARK: - 輸出

    /// 把設定轉成文字，可以存檔、分享，或貼給 AI 請它在這個基礎上微調。
    public static func format(
        _ settings: EQSettings, name: String? = nil, sampleRate: Double = 48_000, language: AppLanguage = .chinese
    ) -> String {
        var lines: [String] = []
        if let name, !name.isEmpty {
            lines.append(language == .english ? "# Name: \(name)" : "# 名稱: \(name)") // 不翻譯
        }
        lines.append("Preamp: \(format(settings.effectivePreampDB(sampleRate: sampleRate), decimals: 1)) dB")
        for (index, band) in settings.bands.enumerated() {
            lines.append(
                "Filter \(index + 1): \(band.isEnabled ? "ON" : "OFF") \(code(for: band.kind))"
                    + " Fc \(format(band.frequency, decimals: 0)) Hz"
                    + " Gain \(format(band.kind.hasGain ? band.gainDB : 0, decimals: 1)) dB"
                    + " Q \(format(band.q, decimals: 2))"
            )
        }
        return lines.joined(separator: "\n")
    }

    private static func format(_ value: Double, decimals: Int) -> String {
        String(format: "%.\(decimals)f", locale: Locale(identifier: "en_US_POSIX"), value)
    }

    // MARK: - 給 AI 的範本

    /// 範本裡的格式示範。單元測試會確認它能被 `parse` 正確解析。
    public static func aiExample(language: AppLanguage) -> String {
        """
        \(language == .english ? "# Name: Example" : "# 名稱: 示範設定")
        Preamp: -3.0 dB
        Filter 1: ON LSC Fc 90 Hz Gain 3.0 dB Q 0.71
        Filter 2: ON PK Fc 250 Hz Gain -1.5 dB Q 1.40
        Filter 3: ON PK Fc 3000 Hz Gain 2.0 dB Q 1.00
        Filter 4: ON HSC Fc 9000 Hz Gain 2.0 dB Q 0.71
        """
    }

    /// 給 AI 的提示詞範本。使用者填好括號裡的內容後貼給 AI，再把 AI 的回覆貼回 Tonefleur 匯入。
    /// 整段依介面語言換成中文或英文版，AI 回覆的語言通常會跟著範本走。
    /// - Parameters:
    ///   - deviceName: 目前正在調的輸出裝置名稱，預先填進範本。
    ///   - current: 目前的設定。有調整過時附在範本裡，讓 AI 可以在這個基礎上微調。
    public static func aiPrompt(deviceName: String?, current: EQSettings?, language: AppLanguage = .current) -> String {
        let example = aiExample(language: language)
        let hasAdjustments = current?.bands.contains { $0.isEnabled && $0.kind.hasGain && $0.gainDB != 0 } ?? false
        let currentText = current.map { format($0, language: language) } ?? ""

        switch language {
        case .english:
            let device = deviceName.map { "\($0) (replace with the exact model if you know it)" }
                ?? "(e.g. soundbar model, headphone model, MacBook built-in speakers)"
            var prompt = """
            Act as an audio tuning engineer. Based on my listening habits, design a parametric EQ \
            for "Tonefleur", an equalizer app for macOS.

            [My listening setup]
            - Playback device: \(device)
            - Music I usually listen to: (e.g. female-fronted bands, J-pop vocalists, classical, electronic)
            - What I want: (e.g. clearer drum detail, fuller vocals, punchier bass, not harsh)
            - Usual volume: (e.g. quiet background music, normal, loud)

            [Constraints]
            - At most 16 filters; 4–8 is usually enough
            - Allowed types only: PK (peaking), LSC (low shelf), HSC (high shelf), HP (high-pass), LP (low-pass), NO (notch)
            - Frequency 20–20000 Hz; gain −18 to +18 dB (write 0 for HP, LP and NO); Q 0.1–18
            - Prefer gentle corrections; keep each band within ±6 dB if possible
            - Respect the physical limits of the playback device, e.g. don't boost sub-bass that small speakers can't reproduce
            - Set Preamp to the negative of the highest point of the overall curve to avoid clipping (Tonefleur also compensates automatically)

            [Output format]
            Put the settings in a single code block, following the example below exactly \
            (the Equalizer APO / AutoEQ ParametricEQ format). The first line is a short name for the preset. \
            Outside the code block, briefly explain what each band does.

            ```
            \(example)
            ```
            """
            if hasAdjustments {
                prompt += """


                [Current settings]
                This is what I'm using now; feel free to adjust from here:

                ```
                \(currentText)
                ```
                """
            }
            return prompt

        case .chinese:
            let device = deviceName.map { "\($0)（若知道確切型號請改成型號）" } ?? "（例如：soundbar 型號、耳機型號、MacBook 內建喇叭）" // 不翻譯
            var prompt = """
            請你擔任音響調校工程師，依照我的聆聽習慣，為 macOS 的等化器 App「Tonefleur」設計一組參數式 EQ。

            【我的聆聽環境】
            - 播放裝置：\(device)
            - 常聽的音樂：（例如：女聲主唱的樂團、唱見歌手、古典、電子）
            - 想要的效果：（例如：鼓聲細節清楚、人聲飽滿、低音更有力、不要刺耳）
            - 平常的音量：（例如：小聲背景音樂、正常音量、大聲）

            【限制】
            - 濾波器最多 16 個，建議 4–8 個就好
            - 類型只能用：PK（鐘形）、LSC（低頻擱架）、HSC（高頻擱架）、HP（高通）、LP（低通）、NO（陷波）
            - 頻率 20–20000 Hz；增益 −18 到 +18 dB（HP、LP、NO 的增益寫 0）；Q 值 0.1–18
            - 以小幅修正為主，單一頻段建議不超過 ±6 dB
            - 請考慮播放裝置的物理限制，例如小喇叭發不出的超低頻不要硬加
            - Preamp 寫成整體曲線最高點的負值，避免破音（Tonefleur 也會自動補償）

            【輸出格式】
            請把參數放在一個程式碼區塊裡，格式必須完全照下面的範例（Equalizer APO／AutoEQ 的 ParametricEQ 格式），
            第一行是這組設定的簡短名稱。程式碼區塊外面再用幾句話說明每個頻段的用意。

            ```
            \(example)
            ```
            """
            if hasAdjustments {
                prompt += """


                【目前的設定】
                這是我現在使用的設定，可以在這個基礎上調整：

                ```
                \(currentText)
                ```
                """
            }
            return prompt
        }
    }
}
