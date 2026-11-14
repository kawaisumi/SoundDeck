import Combine
import Foundation

/// EQ 設定的唯一來源：UI 透過它修改，它負責存檔並送進音訊引擎。所有方法都必須在主執行緒呼叫。
public final class EqualizerController: ObservableObject {
    @Published public private(set) var settings: EQSettings

    private let engine: AudioEngine
    private static let defaultsKey = "equalizerSettings"

    public init(engine: AudioEngine) {
        self.engine = engine
        if let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
           let saved = try? JSONDecoder().decode(EQSettings.self, from: data) {
            settings = Self.sanitized(saved)
        } else {
            settings = .flat
        }
        engine.setEqualizer(settings)
    }

    /// 目前的頻段若與某個內建預設組完全相同，回傳它。
    public var matchingPreset: EQPreset? {
        EQPreset.builtIn.first { Self.sameShape($0.bands, settings.bands) }
    }

    public var canAddBand: Bool { settings.bands.count < EQSettings.maxBands }

    // MARK: - 修改

    public func update(_ change: (inout EQSettings) -> Void) {
        var next = settings
        change(&next)
        next = Self.sanitized(next)
        guard next != settings else { return }
        settings = next
        engine.setEqualizer(next)
        if let data = try? JSONEncoder().encode(next) {
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        }
    }

    public func updateBand(_ id: EQBand.ID, _ change: (inout EQBand) -> Void) {
        update { settings in
            guard let index = settings.bands.firstIndex(where: { $0.id == id }) else { return }
            change(&settings.bands[index])
        }
    }

    public func removeBand(_ id: EQBand.ID) {
        update { $0.bands.removeAll { $0.id == id } }
    }

    /// 新增一個頻段，放在現有頻段之間最大的空隙中央（對數刻度）。
    @discardableResult
    public func addBand() -> EQBand.ID? {
        guard canAddBand else { return nil }
        let edges = [EQBand.frequencyRange.lowerBound]
            + settings.bands.map(\.frequency).sorted()
            + [EQBand.frequencyRange.upperBound]
        var best = (ratio: 0.0, frequency: 1000.0)
        for (low, high) in zip(edges, edges.dropFirst()) where high / low > best.ratio {
            best = (high / low, (low * high).squareRoot())
        }
        let band = EQBand(kind: .peak, frequency: best.frequency.rounded())
        update { $0.bands.append(band) }
        return band.id
    }

    public func apply(_ preset: EQPreset) {
        update { settings in
            // 給新的 id，讓介面把它們當成全新的頻段。
            settings.bands = preset.bands.map {
                EQBand(kind: $0.kind, frequency: $0.frequency, gainDB: $0.gainDB, q: $0.q, isEnabled: $0.isEnabled)
            }
        }
    }

    // MARK: - 輔助

    private static func sanitized(_ settings: EQSettings) -> EQSettings {
        var result = settings
        result.bands = Array(settings.bands.prefix(EQSettings.maxBands)).map(\.clamped)
        result.preampDB = settings.preampDB.clamped(to: EQSettings.preampRange)
        return result
    }

    private static func sameShape(_ a: [EQBand], _ b: [EQBand]) -> Bool {
        guard a.count == b.count else { return false }
        return zip(a, b).allSatisfy { x, y in
            x.kind == y.kind && x.isEnabled == y.isEnabled
                && abs(x.frequency - y.frequency) < 0.5
                && abs(x.gainDB - y.gainDB) < 0.05
                && abs(x.q - y.q) < 0.005
        }
    }
}
