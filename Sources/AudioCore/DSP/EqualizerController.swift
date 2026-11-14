import Combine
import Foundation

/// EQ 設定的唯一來源：UI 透過它修改，它負責存檔並送進音訊引擎。所有方法都必須在主執行緒呼叫。
///
/// 每個輸出裝置各有一組設定（耳機與喇叭需要的 EQ 不同）。還沒有自己設定的裝置使用「共用設定」；
/// 第一次在某個裝置上調整時，會從共用設定複製一份成為那個裝置自己的。
public final class EqualizerController: ObservableObject {
    /// 目前正在檢視／編輯的那個裝置的設定。
    @Published public private(set) var settings: EQSettings
    /// 目前正在檢視／編輯的裝置 UID；nil 表示還沒有選定裝置，此時編輯的是共用設定。
    @Published public private(set) var deviceUID: String?

    private let engine: AudioEngine
    private var byDevice: [String: EQSettings]
    private var shared: EQSettings

    private static let sharedKey = "equalizerSettings"
    private static let byDeviceKey = "equalizerSettingsByDevice"

    public init(engine: AudioEngine) {
        self.engine = engine
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: Self.sharedKey),
           let saved = try? JSONDecoder().decode(EQSettings.self, from: data) {
            shared = Self.sanitized(saved)
        } else {
            shared = .flat
        }
        if let data = defaults.data(forKey: Self.byDeviceKey),
           let saved = try? JSONDecoder().decode([String: EQSettings].self, from: data) {
            byDevice = saved.mapValues(Self.sanitized)
        } else {
            byDevice = [:]
        }
        settings = shared

        engine.setEqualizer(shared, forDeviceUID: nil)
        for (uid, deviceSettings) in byDevice {
            engine.setEqualizer(deviceSettings, forDeviceUID: uid)
        }
    }

    /// 切換要檢視／編輯哪個裝置的設定。
    public func select(deviceUID: String?) {
        guard deviceUID != self.deviceUID else { return }
        self.deviceUID = deviceUID
        settings = deviceUID.flatMap { byDevice[$0] } ?? shared
    }

    /// 這個裝置是否已經有自己的設定（而不是沿用共用設定）。
    public func hasOwnSettings(deviceUID: String) -> Bool {
        byDevice[deviceUID] != nil
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

        if let deviceUID {
            byDevice[deviceUID] = next
            engine.setEqualizer(next, forDeviceUID: deviceUID)
            if let data = try? JSONEncoder().encode(byDevice) {
                UserDefaults.standard.set(data, forKey: Self.byDeviceKey)
            }
        } else {
            shared = next
            engine.setEqualizer(next, forDeviceUID: nil)
            if let data = try? JSONEncoder().encode(next) {
                UserDefaults.standard.set(data, forKey: Self.sharedKey)
            }
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
