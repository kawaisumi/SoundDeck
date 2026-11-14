import Combine
import CoreAudio
import Foundation

/// 混音器的一列。
public struct MixerChannel: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let bundleURL: URL?
    /// 0…2，1 是原本的音量。
    public var volume: Float
    public var isMuted: Bool
    /// 這一刻是否正在發聲。
    public var isPlaying: Bool
    /// 對應的管線槽位，用來讀電平表。
    public let slot: Int
}

/// 依 App 的混音器：決定哪些 App 有自己的一列、把它們分配到管線的槽位、記住各自的音量。
/// 所有方法都必須在主執行緒呼叫。
public final class MixerController: ObservableObject {
    /// 各 App 的列，依出現的先後排列。
    @Published public private(set) var channels: [MixerChannel] = []
    /// 「系統音效與其他」：所有沒有自己一列的聲音。
    @Published public private(set) var other: MixerChannel

    public static let volumeRange: ClosedRange<Float> = 0...2
    public static let otherID = "__other__"

    /// 停止發聲後，還在清單上保留多久。
    private static let gracePeriod: TimeInterval = 30

    private struct Saved: Codable, Equatable {
        var volume: Float = 1
        var isMuted = false
        var isDefault: Bool { volume == 1 && !isMuted }
    }

    private let engine: AudioEngine
    private let monitor = AudioProcessMonitor()
    private var saved: [String: Saved]
    private var slotByApp: [String: Int] = [:]
    private var order: [String] = []
    private var lastPlayed: [String: Date] = [:]
    private var timer: Timer?
    private static let defaultsKey = "mixerSettings"

    public init(engine: AudioEngine) {
        self.engine = engine
        if let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
           let decoded = try? JSONDecoder().decode([String: Saved].self, from: data) {
            saved = decoded
        } else {
            saved = [:]
        }
        let otherSaved = saved[Self.otherID] ?? Saved()
        other = MixerChannel(
            id: Self.otherID, name: "系統音效與其他", bundleURL: nil,
            volume: otherSaved.volume, isMuted: otherSaved.isMuted, isPlaying: false, slot: 0
        )

        // 有 App 開始或停止使用音訊時立刻更新；另外每秒檢查一次，處理播放狀態與保留時間。
        var addr = HAL.address(kAudioHardwarePropertyProcessObjectList)
        AudioObjectAddPropertyListenerBlock(HAL.systemObject, &addr, .main) { [weak self] _, _ in
            self?.refresh()
        }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        refresh()
    }

    // MARK: - 操作

    public func setVolume(_ volume: Float, for id: String) {
        modify(id) { $0.volume = min(max(volume, Self.volumeRange.lowerBound), Self.volumeRange.upperBound) }
    }

    public func setMuted(_ muted: Bool, for id: String) {
        modify(id) { $0.isMuted = muted }
    }

    /// 各槽位的峰值，給電平表用。
    public func readPeaks() -> [Float] {
        engine.readSlotPeaks() ?? []
    }

    private func modify(_ id: String, _ change: (inout Saved) -> Void) {
        var entry = saved[id] ?? Saved()
        change(&entry)
        guard entry != saved[id] ?? Saved() else { return }
        saved[id] = entry.isDefault ? nil : entry
        if let data = try? JSONEncoder().encode(saved) {
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        }
        refresh()
    }

    // MARK: - 狀態同步

    private func refresh() {
        let now = Date()
        let apps = monitor.snapshot()
        let appByID = Dictionary(uniqueKeysWithValues: apps.map { ($0.id, $0) })

        for app in apps where app.isPlaying {
            lastPlayed[app.id] = now
        }
        lastPlayed = lastPlayed.filter { appByID[$0.key] != nil }

        // 哪些 App 應該有自己的一列：
        // - 正在發聲，或剛停下來不久（暫停時也能先調好音量，不會一暫停就消失）
        // - 音量或靜音被調整過的，只要還在使用音訊就一直保留。
        //   這也確保被靜音的 App 一開始發聲就已經在自己的槽位裡，不會先漏出一小段聲音。
        func shouldList(_ app: AudioAppSnapshot) -> Bool {
            if app.isPlaying { return true }
            if let last = lastPlayed[app.id], now.timeIntervalSince(last) < Self.gracePeriod { return true }
            return saved[app.id] != nil
        }

        // 釋放不再需要的槽位。
        for (id, _) in slotByApp where appByID[id].map(shouldList) != true {
            slotByApp[id] = nil
            order.removeAll { $0 == id }
        }
        // 分配槽位給新出現的 App。槽位用完時，多出來的 App 留在「其他」裡。
        var freeSlots = Set(1..<AudioEngine.slotCount).subtracting(slotByApp.values).sorted()
        for app in apps where slotByApp[app.id] == nil && shouldList(app) {
            guard !freeSlots.isEmpty else { break }
            slotByApp[app.id] = freeSlots.removeFirst()
            order.append(app.id)
        }

        // 送進引擎。
        var routing = MixerRouting.empty(slotCount: AudioEngine.slotCount)
        routing.gains[0] = Self.gain(for: saved[Self.otherID] ?? Saved())
        for (id, slot) in slotByApp {
            guard let app = appByID[id] else { continue }
            routing.processes[slot] = app.processes
            routing.gains[slot] = Self.gain(for: saved[id] ?? Saved())
        }
        engine.setRouting(routing)

        // 更新介面用的資料。
        let newChannels: [MixerChannel] = order.compactMap { id in
            guard let app = appByID[id], let slot = slotByApp[id] else { return nil }
            let entry = saved[id] ?? Saved()
            return MixerChannel(
                id: id, name: app.name, bundleURL: app.bundleURL,
                volume: entry.volume, isMuted: entry.isMuted, isPlaying: app.isPlaying, slot: slot
            )
        }
        if newChannels != channels { channels = newChannels }

        let otherSaved = saved[Self.otherID] ?? Saved()
        var newOther = other
        newOther.volume = otherSaved.volume
        newOther.isMuted = otherSaved.isMuted
        if newOther != other { other = newOther }
    }

    /// 滑桿位置 → 線性增益。100% 以下用平方曲線（手感接近聽覺上的響度），
    /// 100% 以上線性增加，200% 是兩倍振幅（+6 dB）。
    private static func gain(for entry: Saved) -> Float {
        if entry.isMuted { return 0 }
        let volume = min(max(entry.volume, volumeRange.lowerBound), volumeRange.upperBound)
        return volume <= 1 ? volume * volume : volume
    }
}
