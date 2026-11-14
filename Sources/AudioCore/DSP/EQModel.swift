import Foundation

/// 參數式 EQ 的一個頻段。
public struct EQBand: Codable, Equatable, Identifiable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Sendable {
        case peak, lowShelf, highShelf, highPass, lowPass, notch

        /// 高通、低通、陷波沒有增益參數。
        public var hasGain: Bool {
            switch self {
            case .peak, .lowShelf, .highShelf: return true
            case .highPass, .lowPass, .notch: return false
            }
        }
    }

    public static let frequencyRange: ClosedRange<Double> = 20...20_000
    public static let gainRange: ClosedRange<Double> = -18...18
    public static let qRange: ClosedRange<Double> = 0.1...18

    public var id: UUID
    public var kind: Kind
    public var frequency: Double
    public var gainDB: Double
    public var q: Double
    public var isEnabled: Bool

    public init(
        id: UUID = UUID(), kind: Kind = .peak,
        frequency: Double, gainDB: Double = 0, q: Double = 1, isEnabled: Bool = true
    ) {
        self.id = id
        self.kind = kind
        self.frequency = frequency
        self.gainDB = gainDB
        self.q = q
        self.isEnabled = isEnabled
    }

    /// 把各參數限制在合法範圍內。
    public var clamped: EQBand {
        var band = self
        band.frequency = frequency.clamped(to: Self.frequencyRange)
        band.gainDB = gainDB.clamped(to: Self.gainRange)
        band.q = q.clamped(to: Self.qRange)
        return band
    }
}

/// 整組 EQ 設定。
public struct EQSettings: Codable, Equatable, Sendable {
    public static let maxBands = 16
    public static let preampRange: ClosedRange<Double> = -18...18

    public var bands: [EQBand]
    /// 手動前級增益（dB）。`autoPreamp` 開啟時不使用。
    public var preampDB: Double
    /// 依曲線最高點自動降低前級，避免增益把訊號推過 0 dBFS。
    public var autoPreamp: Bool
    public var isBypassed: Bool

    public init(bands: [EQBand], preampDB: Double = 0, autoPreamp: Bool = true, isBypassed: Bool = false) {
        self.bands = bands
        self.preampDB = preampDB
        self.autoPreamp = autoPreamp
        self.isBypassed = isBypassed
    }

    /// 預設：5 個增益為 0 的頻段，聲音不變，等著被調整。
    public static var flat: EQSettings {
        EQSettings(bands: [
            EQBand(kind: .lowShelf, frequency: 80, q: 0.71),
            EQBand(kind: .peak, frequency: 250),
            EQBand(kind: .peak, frequency: 1000),
            EQBand(kind: .peak, frequency: 4000),
            EQBand(kind: .highShelf, frequency: 10_000, q: 0.71),
        ])
    }

    /// 所有啟用頻段在指定頻率的合計增益（dB），不含前級。
    public func responseDB(at frequency: Double, sampleRate: Double) -> Double {
        bands.reduce(0) { total, band in
            guard band.isEnabled else { return total }
            return total + Biquad(band: band, sampleRate: sampleRate).magnitudeDB(at: frequency, sampleRate: sampleRate)
        }
    }

    /// 曲線在 20 Hz–20 kHz 之間的最高點（dB）。
    public func peakResponseDB(sampleRate: Double) -> Double {
        let filters = bands.filter(\.isEnabled).map { Biquad(band: $0, sampleRate: sampleRate) }
        guard !filters.isEmpty else { return 0 }
        let steps = 240
        var peak = -Double.infinity
        for step in 0...steps {
            let frequency = 20 * pow(1000, Double(step) / Double(steps))
            let total = filters.reduce(0) { $0 + $1.magnitudeDB(at: frequency, sampleRate: sampleRate) }
            peak = max(peak, total)
        }
        return peak
    }

    /// 實際套用的前級增益（dB）。
    public func effectivePreampDB(sampleRate: Double) -> Double {
        if autoPreamp {
            return -max(0, peakResponseDB(sampleRate: sampleRate))
        }
        return preampDB.clamped(to: Self.preampRange)
    }
}

/// 內建與自訂的 EQ 預設組。
public struct EQPreset: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let bands: [EQBand]

    public static let builtIn: [EQPreset] = [
        EQPreset(id: "flat", name: "平坦", bands: EQSettings.flat.bands),
        EQPreset(id: "bass", name: "低音加強", bands: [
            EQBand(kind: .lowShelf, frequency: 100, gainDB: 6, q: 0.71),
            EQBand(kind: .peak, frequency: 250, gainDB: -1.5, q: 1),
            EQBand(kind: .peak, frequency: 1000),
            EQBand(kind: .peak, frequency: 4000),
            EQBand(kind: .highShelf, frequency: 10_000, q: 0.71),
        ]),
        EQPreset(id: "treble", name: "高音加強", bands: [
            EQBand(kind: .lowShelf, frequency: 80, q: 0.71),
            EQBand(kind: .peak, frequency: 250),
            EQBand(kind: .peak, frequency: 1000),
            EQBand(kind: .peak, frequency: 4000, gainDB: 2, q: 1),
            EQBand(kind: .highShelf, frequency: 8000, gainDB: 5, q: 0.71),
        ]),
        EQPreset(id: "vocal", name: "人聲清晰", bands: [
            EQBand(kind: .highPass, frequency: 80, q: 0.71),
            EQBand(kind: .peak, frequency: 250, gainDB: -2, q: 1.2),
            EQBand(kind: .peak, frequency: 1000),
            EQBand(kind: .peak, frequency: 3000, gainDB: 4, q: 1),
            EQBand(kind: .highShelf, frequency: 10_000, gainDB: 1.5, q: 0.71),
        ]),
        EQPreset(id: "loudness", name: "小音量補償", bands: [
            EQBand(kind: .lowShelf, frequency: 120, gainDB: 5, q: 0.71),
            EQBand(kind: .peak, frequency: 250),
            EQBand(kind: .peak, frequency: 1000, gainDB: -1, q: 0.8),
            EQBand(kind: .peak, frequency: 4000),
            EQBand(kind: .highShelf, frequency: 9000, gainDB: 4, q: 0.71),
        ]),
    ]
}

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
