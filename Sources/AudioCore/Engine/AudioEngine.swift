import Combine
import CoreAudio
import Foundation

/// 音訊引擎的對外介面。所有公開方法都必須在主執行緒呼叫。
///
/// 引擎管理一組 `OutputPipeline`，每個使用中的輸出裝置一條：
/// - **主管線**：接在系統預設輸出上，只要引擎啟用就存在。
/// - **次管線**：有 App 被指定到其他裝置時才建立，沒有 App 用到時拆除。
public final class AudioEngine: ObservableObject {
    public enum Status: Equatable {
        case stopped
        case starting
        case running(PipelineInfo)
        case failed(String)
    }

    /// 主管線的狀態。
    @Published public private(set) var status: Status = .stopped

    /// 使用者是否要求啟用。裝置切換時依此決定要不要重建管線。
    @Published public private(set) var isEnabled = false

    /// 混音器的槽位數：槽位 0 是「系統音效與其他」，其餘各給一個 App。
    public static let slotCount = 13

    /// 系統休眠期間為 true：管線暫時拆除，但不改變使用者的啟用設定。
    private var isSuspended = false

    /// 建立與拆除管線可能會短暫阻塞，放在專用的序列佇列上，不卡 UI。
    private let workQueue = DispatchQueue(label: "local.sounddeck.engine")

    // 以下由 lock 保護。
    private let lock = NSLock()
    private var pipelines: [String: OutputPipeline] = [:] // 以輸出裝置 UID 為鍵
    private var primaryUID: String?
    private var routing = MixerRouting.empty(slotCount: AudioEngine.slotCount)
    private var equalizers: [String: EQSettings] = [:]
    private var fallbackEqualizer = EQSettings.flat
    private var spectrumEnabled = false

    /// 每次從外部要求重建就加一，用來作廢過期的延遲重建與重試。
    private var generation = 0
    private static let retryDelays: [TimeInterval] = [1, 2, 4]

    private var watchdog: Timer?
    private var lastCallbackCount: UInt64?
    private var stalledTicks = 0
    private static let watchdogInterval: TimeInterval = 0.25
    /// 管線回報啟動成功後，IOProc 連續這麼久沒被呼叫就視為沒有真的在運作。
    private static let stallTimeout: TimeInterval = 20
    private static let permissionRetryInterval: TimeInterval = 5
    private var deviceListenersInstalled = false

    public init() {}

    public func start() {
        isEnabled = true
        installDeviceListenersIfNeeded()
        startWatchdog()
        rebuild()
    }

    public func stop() {
        isEnabled = false
        stopWatchdog()
        rebuild()
    }

    /// 同步停止，給 App 結束前使用。
    public func shutdown() {
        isEnabled = false
        generation += 1
        stopWatchdog()
        workQueue.sync { self.takeAllPipelines().forEach { $0.stop() } }
    }

    /// 系統即將休眠：主動拆除管線。喚醒後裝置重新初始化的時序很亂，留著舊管線容易無聲或爆音。
    public func suspendForSleep() {
        guard !isSuspended else { return }
        isSuspended = true
        Log.info("系統即將休眠，拆除管線")
        rebuild()
    }

    /// 系統喚醒：稍等裝置回來再重建，失敗會自動重試。
    public func resumeAfterWake() {
        guard isSuspended else { return }
        isSuspended = false
        Log.info("系統喚醒，稍後重建管線")
        rebuild(after: 1)
    }

    // MARK: - 讀取

    /// 讀取主管線的診斷數值；沒有管線時回傳 nil。
    public func readStats() -> PipelineStats? {
        lock.lock()
        defer { lock.unlock() }
        return primaryUID.flatMap { pipelines[$0] }?.readStats()
    }

    /// 讀取各槽位的峰值（給電平表用）；沒有管線時回傳 nil。
    /// 一個槽位同一時間只會在一條管線裡有聲音，所以各管線取最大值即可。
    public func readSlotPeaks() -> [Float]? {
        lock.lock()
        defer { lock.unlock() }
        guard !pipelines.isEmpty else { return nil }
        var peaks = [Float](repeating: 0, count: Self.slotCount)
        for pipeline in pipelines.values {
            for (slot, peak) in pipeline.readSlotPeaks().enumerated() where slot < peaks.count {
                peaks[slot] = max(peaks[slot], peak)
            }
        }
        return peaks
    }

    /// 各條管線各自的槽位峰值，主管線排第一個。診斷用，會把峰值歸零。
    public func readSlotPeaksByDevice() -> [(device: String, peaks: [Float])] {
        lock.lock()
        defer { lock.unlock() }
        return pipelines
            .sorted { lhs, rhs in
                if lhs.key == primaryUID { return true }
                if rhs.key == primaryUID { return false }
                return lhs.value.info.deviceName < rhs.value.info.deviceName
            }
            .map { ($0.value.info.deviceName, $0.value.readSlotPeaks()) }
    }

    /// 開始或停止收集頻譜資料。只有畫面上真的顯示頻譜時才開，平常不多花運算。
    public func setSpectrumEnabled(_ enabled: Bool) {
        lock.lock()
        defer { lock.unlock() }
        spectrumEnabled = enabled
        pipelines.values.forEach { $0.setSpectrumEnabled(enabled) }
    }

    /// 某個輸出裝置最近播出的聲音（處理後、左右平均）；`uid` 為 nil 表示系統預設輸出。
    /// 該裝置目前沒有管線時回傳 nil。
    public func readSpectrumSamples(deviceUID uid: String?, count: Int) -> [Float]? {
        lock.lock()
        defer { lock.unlock() }
        guard let key = uid ?? primaryUID, let pipeline = pipelines[key] else { return nil }
        return pipeline.readSpectrumSamples(count: count)
    }

    // MARK: - 設定

    /// 設定軟體音量的增益。該裝置目前沒有管線時不做事（管線建立時會自己讀取記住的音量）。
    func setBalance(_ balance: Float, forDeviceUID uid: String) {
        lock.lock()
        defer { lock.unlock() }
        pipelines[uid]?.setBalance(balance)
    }

    func setSoftwareGain(_ gain: Float, forDeviceUID uid: String) {
        lock.lock()
        defer { lock.unlock() }
        pipelines[uid]?.setGain(gain)
    }

    /// 套用某個裝置的 EQ 設定；`uid` 為 nil 表示設定「沒有自己設定的裝置」所用的那一組。
    func setEqualizer(_ settings: EQSettings, forDeviceUID uid: String?) {
        lock.lock()
        defer { lock.unlock() }
        if let uid {
            equalizers[uid] = settings
        } else {
            fallbackEqualizer = settings
        }
        for (pipelineUID, pipeline) in pipelines {
            pipeline.setEqualizer(equalizers[pipelineUID] ?? fallbackEqualizer)
        }
    }

    /// 套用混音器的路由。沒有管線時先記著，管線建立時會帶進去。
    func setRouting(_ newRouting: MixerRouting) {
        lock.lock()
        guard newRouting != routing else {
            lock.unlock()
            return
        }
        routing = newRouting
        // 現有的管線先套用：音量這類變動要立刻生效，不能等管線增減。
        // 指定的裝置還沒有管線的 App 會暫時留在主管線。
        applyRoutingLocked()
        let needsReconcile = primaryUID != nil && neededSecondaryUIDsLocked() != secondaryUIDsLocked()
        lock.unlock()

        if needsReconcile {
            scheduleReconcile()
        }
    }

    // MARK: - 路由計算（呼叫時必須持有 lock）

    private func secondaryUIDsLocked() -> Set<String> {
        Set(pipelines.keys).subtracting(primaryUID.map { [$0] } ?? [])
    }

    /// 依目前的路由，除了主管線之外還需要哪些裝置的管線。
    private func neededSecondaryUIDsLocked() -> Set<String> {
        var needed = Set<String>()
        for slot in 1..<Self.slotCount where !routing.processes[slot].isEmpty {
            if let uid = routing.devices[slot], uid != primaryUID {
                needed.insert(uid)
            }
        }
        guard !needed.isEmpty else { return needed }
        let available = Set(HAL.outputDeviceIDs().compactMap { try? HAL.deviceUID($0) })
        return needed.intersection(available)
    }

    /// 每個槽位實際由哪條管線負責：指定的裝置有管線就用它，否則退回主管線。
    private func slotProcessesLocked(forPipeline uid: String) -> [[AudioObjectID]] {
        var result: [[AudioObjectID]] = Array(repeating: [], count: Self.slotCount)
        for slot in 1..<Self.slotCount {
            let target = routing.devices[slot].flatMap { pipelines[$0] != nil ? $0 : nil } ?? primaryUID
            if target == uid {
                result[slot] = routing.processes[slot]
            }
        }
        return result
    }

    private func applyRoutingLocked() {
        let excluded = routing.processes.dropFirst().flatMap { $0 }
        let plans = pipelines.map { uid, pipeline in (pipeline, slotProcessesLocked(forPipeline: uid)) }
        for (pipeline, slotProcesses) in plans {
            pipeline.beginRouting(slotProcesses: slotProcesses, excluded: excluded, slotGains: routing.gains)
        }
        for (pipeline, slotProcesses) in plans {
            pipeline.finishRouting(slotProcesses: slotProcesses)
        }
    }

    // MARK: - 管線生命週期

    private func takeAllPipelines() -> [OutputPipeline] {
        lock.lock()
        defer { lock.unlock() }
        let all = Array(pipelines.values)
        pipelines = [:]
        primaryUID = nil
        return all
    }

    /// 建立一條管線。會短暫阻塞，只能在 workQueue 上呼叫，且不可持有 lock。
    private func makePipeline(outputDevice: AudioObjectID, sourceUID: String) throws -> OutputPipeline {
        let uid = try HAL.deviceUID(outputDevice)
        guard let ownProcess = HAL.processObject(pid: getpid()) else {
            throw CoreAudioError(status: kAudioHardwareUnspecifiedError, operation: "取得自身的音訊 process 物件")
        }
        // 裝置有硬體音量就不在軟體端衰減；沒有的話套用記住的軟體音量。
        let gain = HAL.hasHardwareVolume(outputDevice) ? 1 : SoftwareVolumeStore.gain(forUID: uid)

        lock.lock()
        let equalizer = equalizers[uid] ?? fallbackEqualizer
        let excluded = routing.processes.dropFirst().flatMap { $0 }
        let gains = routing.gains
        lock.unlock()

        // 一開始所有 App 槽位都是空的；管線加入之後由 applyRoutingLocked 統一分配，
        // 這樣搬移的順序（先接手、後放掉）才會一致。
        return try OutputPipeline(
            outputDevice: outputDevice, sourceDeviceUID: sourceUID, ownProcess: ownProcess,
            slotProcesses: Array(repeating: [], count: Self.slotCount),
            excluded: excluded, slotGains: gains,
            initialGain: gain, initialBalance: BalanceStore.balance(forUID: uid), equalizer: equalizer
        )
    }

    /// 依目前的設定重建（或拆除）所有管線。
    /// - Parameters:
    ///   - delay: 延遲多久才動手；期間若又有新的重建要求，這一次會被作廢。
    ///   - failure: 若這次是因為錯誤而停用，要顯示給使用者的原因。
    private func rebuild(after delay: TimeInterval = 0, stoppedBecause failure: String? = nil) {
        generation += 1
        perform(generation: generation, attempt: 0, after: delay, failure: failure)
    }

    private func perform(generation: Int, attempt: Int, after delay: TimeInterval, failure: String?) {
        if delay > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.perform(generation: generation, attempt: attempt, after: 0, failure: failure)
            }
            return
        }
        guard generation == self.generation else { return }

        let shouldRun = isEnabled && !isSuspended
        if shouldRun { status = .starting }

        workQueue.async { [weak self] in
            guard let self else { return }

            // 先拆掉舊的。tap 一停止讀取，系統聲音就會恢復成原本的直接輸出。
            self.takeAllPipelines().forEach { $0.stop() }

            guard shouldRun else {
                self.publish(failure.map { .failed($0) } ?? .stopped, generation: generation)
                return
            }

            do {
                let device = try HAL.defaultOutputDevice()
                let uid = try HAL.deviceUID(device)
                let primary = try self.makePipeline(outputDevice: device, sourceUID: uid)
                try primary.start()

                self.lock.lock()
                primary.setSpectrumEnabled(self.spectrumEnabled)
                self.pipelines[uid] = primary
                self.primaryUID = uid
                self.applyRoutingLocked()
                self.lock.unlock()
                self.publish(.running(primary.info), generation: generation)

                self.reconcileSecondaryPipelines()
            } catch {
                Log.error("管線啟動失敗（第 \(attempt + 1) 次）：\(error)")
                self.publish(.failed("\(error)"), generation: generation)

                if attempt < Self.retryDelays.count {
                    let delay = Self.retryDelays[attempt]
                    DispatchQueue.main.async {
                        self.perform(generation: generation, attempt: attempt + 1, after: delay, failure: nil)
                    }
                }
            }
        }
    }

    private func publish(_ status: Status, generation: Int) {
        DispatchQueue.main.async {
            // 已經有更新的重建要求時，舊結果不再代表現況。
            guard generation == self.generation else { return }
            self.status = status
        }
    }

    private func scheduleReconcile() {
        workQueue.async { [weak self] in self?.reconcileSecondaryPipelines() }
    }

    /// 讓次管線的集合符合目前的路由：拆掉沒有 App 在用的，建立新需要的。只能在 workQueue 上呼叫。
    private func reconcileSecondaryPipelines() {
        lock.lock()
        guard let sourceUID = primaryUID else {
            lock.unlock()
            return
        }
        let needed = neededSecondaryUIDsLocked()
        let existing = secondaryUIDsLocked()

        // 拆除：先從表中移除並重新套用路由，讓上面的 App 退回主管線，之後才真的停掉。
        var removed: [OutputPipeline] = []
        for uid in existing.subtracting(needed) {
            if let pipeline = pipelines.removeValue(forKey: uid) {
                removed.append(pipeline)
            }
        }
        if !removed.isEmpty {
            applyRoutingLocked()
        }
        lock.unlock()

        for pipeline in removed {
            Log.info("拆除次管線：\(pipeline.info.deviceName)")
            pipeline.stop()
        }

        for uid in needed.subtracting(existing) {
            guard let device = HAL.outputDevice(forUID: uid) else { continue }
            do {
                let pipeline = try makePipeline(outputDevice: device, sourceUID: sourceUID)
                try pipeline.start()

                lock.lock()
                // 建立期間主管線可能已經換掉（預設裝置改變），那這條的來源就不對了，丟棄。
                if primaryUID == sourceUID, pipelines[uid] == nil {
                    pipeline.setSpectrumEnabled(spectrumEnabled)
                    pipelines[uid] = pipeline
                    applyRoutingLocked()
                    lock.unlock()
                    Log.info("建立次管線：\(pipeline.info.deviceName)")
                } else {
                    lock.unlock()
                    pipeline.stop()
                }
            } catch {
                // 建不起來時，指定到這個裝置的 App 會繼續留在主管線，聲音不會消失。
                Log.error("次管線建立失敗（\(HAL.deviceName(device))）：\(error)")
            }
        }
    }

    // MARK: - 監看

    /// 定期檢查管線是否健康。
    /// 1. 回授保護觸發：即時執行緒偵測到訊號暴衝時只會鎖住輸出，這裡負責真正拆掉管線並停用。
    /// 2. 主管線回報啟動成功，但 IOProc 一直沒被呼叫。沒有取得錄音權限時會這樣：
    ///    系統不會回報錯誤，只是音訊不流動。
    private func startWatchdog() {
        guard watchdog == nil else { return }
        watchdog = Timer.scheduledTimer(withTimeInterval: Self.watchdogInterval, repeats: true) { [weak self] _ in
            self?.checkHealth()
        }
    }

    private func stopWatchdog() {
        watchdog?.invalidate()
        watchdog = nil
        lastCallbackCount = nil
        stalledTicks = 0
    }

    private func checkHealth() {
        guard isEnabled else { return }
        lock.lock()
        let tripped = pipelines.values.contains { $0.isTripped }
        let count = primaryUID.flatMap { pipelines[$0] }?.callbackCount
        lock.unlock()

        if tripped {
            Log.error("偵測到訊號暴衝，已停用音訊處理")
            disable(because: L("偵測到音量異常暴衝（可能是與其他音訊工具形成回授），已自動停用。"))
            return
        }

        guard let count else {
            // 沒有管線（啟動中、重建中），不計入停滯。
            lastCallbackCount = nil
            stalledTicks = 0
            return
        }
        if count != lastCallbackCount {
            lastCallbackCount = count
            stalledTicks = 0
            return
        }
        stalledTicks += 1
        if Double(stalledTicks) * Self.watchdogInterval >= Self.stallTimeout {
            waitForAudioPermission()
        }
    }

    /// 音訊沒有流動時（多半是授權視窗還沒被回答）：先拆掉管線並說明原因，
    /// 然後每隔幾秒再試一次，使用者允許後就會自動開始，不必再手動開關。
    private func waitForAudioPermission() {
        Log.error("管線已啟動但音訊沒有流動，稍後重試")
        lastCallbackCount = nil
        stalledTicks = 0

        generation += 1
        let generation = self.generation
        workQueue.async { [weak self] in self?.takeAllPipelines().forEach { $0.stop() } }
        status = .failed(L("系統沒有送出任何音訊，通常是因為還沒有允許「系統音訊錄製」權限。允許後會自動開始。"))
        perform(generation: generation, attempt: 0, after: Self.permissionRetryInterval, failure: nil)
    }

    private func disable(because reason: String) {
        isEnabled = false
        stopWatchdog()
        rebuild(stoppedBecause: reason)
    }

    // MARK: - 裝置變化

    private func installDeviceListenersIfNeeded() {
        guard !deviceListenersInstalled else { return }
        deviceListenersInstalled = true

        var defaultAddr = HAL.address(kAudioHardwarePropertyDefaultOutputDevice)
        var status = AudioObjectAddPropertyListenerBlock(HAL.systemObject, &defaultAddr, .main) { [weak self] _, _ in
            self?.defaultOutputDeviceChanged()
        }
        if status != noErr {
            Log.error("無法監聽預設輸出裝置變化（OSStatus \(status)）")
        }

        var listAddr = HAL.address(kAudioHardwarePropertyDevices)
        status = AudioObjectAddPropertyListenerBlock(HAL.systemObject, &listAddr, .main) { [weak self] _, _ in
            self?.deviceListChanged()
        }
        if status != noErr {
            Log.error("無法監聽裝置清單變化（OSStatus \(status)）")
        }
    }

    private func defaultOutputDeviceChanged() {
        guard isEnabled, !isSuspended else { return }
        // 裝置切換時通知常會連續來好幾次；延遲重建，後來的要求會作廢前面的。
        Log.info("預設輸出裝置改變，重建管線")
        rebuild(after: 0.3)
    }

    /// 裝置插拔：被指定的裝置消失時，上面的 App 要退回系統預設；裝置回來時再搬回去。
    private func deviceListChanged() {
        guard isEnabled, !isSuspended else { return }
        // 我們自己建立與拆除 aggregate device 也會觸發這個通知，所以只在真的需要時才動手。
        lock.lock()
        let needsReconcile = primaryUID != nil && neededSecondaryUIDsLocked() != secondaryUIDsLocked()
        lock.unlock()
        if needsReconcile {
            scheduleReconcile()
        }
    }
}
