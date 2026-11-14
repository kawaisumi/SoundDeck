import Combine
import CoreAudio
import Foundation

/// 音訊引擎的對外介面。所有公開方法都必須在主執行緒呼叫。
///
/// 目前只有一條管線（系統預設輸出裝置）。之後開啟「依 App 指定輸出裝置」時，
/// 這裡會改為管理多條 `OutputPipeline`，每個使用中的輸出裝置一條。
public final class AudioEngine: ObservableObject {
    public enum Status: Equatable {
        case stopped
        case starting
        case running(PipelineInfo)
        case failed(String)
    }

    @Published public private(set) var status: Status = .stopped

    /// 使用者是否要求啟用。裝置切換時依此決定要不要重建管線。
    @Published public private(set) var isEnabled = false

    /// 系統休眠期間為 true：管線暫時拆除，但不改變使用者的啟用設定。
    private var isSuspended = false

    /// 建立與拆除管線可能會短暫阻塞，放在專用的序列佇列上，不卡 UI。
    private let workQueue = DispatchQueue(label: "local.sounddeck.engine")
    private let lock = NSLock()
    private var pipeline: OutputPipeline? // 由 lock 保護
    private var equalizer = EQSettings.flat // 由 lock 保護

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
    private var deviceListenerInstalled = false

    public init() {}

    public func start() {
        isEnabled = true
        installDeviceListenerIfNeeded()
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
        workQueue.sync { self.takePipeline()?.stop() }
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

    /// 讀取目前管線的診斷數值；沒有管線時回傳 nil。
    public func readStats() -> PipelineStats? {
        lock.lock()
        defer { lock.unlock() }
        return pipeline?.readStats()
    }

    /// 設定軟體音量的增益。只有目前管線的輸出裝置就是指定裝置時才會生效。
    func setSoftwareGain(_ gain: Float, forDeviceUID uid: String) {
        lock.lock()
        defer { lock.unlock() }
        if let pipeline, pipeline.deviceUID == uid {
            pipeline.setGain(gain)
        }
    }

    /// 套用 EQ 設定。沒有管線時先記著，管線建立時會帶進去。
    func setEqualizer(_ settings: EQSettings) {
        lock.lock()
        defer { lock.unlock() }
        equalizer = settings
        pipeline?.setEqualizer(settings)
    }

    // MARK: - 管線生命週期

    private func takePipeline() -> OutputPipeline? {
        lock.lock()
        defer { lock.unlock() }
        let old = pipeline
        pipeline = nil
        return old
    }

    /// 依目前的設定重建（或拆除）管線。
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
            if let old = self.takePipeline() {
                old.stop()
            }

            guard shouldRun else {
                self.publish(failure.map { .failed($0) } ?? .stopped, generation: generation)
                return
            }

            do {
                let device = try HAL.defaultOutputDevice()
                let uid = try HAL.deviceUID(device)
                // 一定要把自己排除，否則我們送出去的聲音又會被自己攔截，形成回授。
                guard let ownProcess = HAL.processObject(pid: getpid()) else {
                    throw CoreAudioError(status: kAudioHardwareUnspecifiedError, operation: "取得自身的音訊 process 物件")
                }
                // 裝置有硬體音量就不在軟體端衰減；沒有的話套用記住的軟體音量。
                let gain = HAL.hasHardwareVolume(device) ? 1 : SoftwareVolumeStore.gain(forUID: uid)
                self.lock.lock()
                let equalizer = self.equalizer
                self.lock.unlock()
                let newPipeline = try OutputPipeline(
                    outputDevice: device, excluding: [ownProcess],
                    initialGain: gain, equalizer: equalizer
                )
                try newPipeline.start()

                self.lock.lock()
                self.pipeline = newPipeline
                // 建立期間設定可能又被改過，補套一次最新的。
                newPipeline.setEqualizer(self.equalizer)
                self.lock.unlock()
                self.publish(.running(newPipeline.info), generation: generation)
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

    // MARK: - 監看

    /// 定期檢查管線是否健康。兩種情況會自動停用並把原因顯示給使用者：
    /// 1. 回授保護觸發：即時執行緒偵測到訊號暴衝時只會鎖住輸出，這裡負責真正拆掉管線。
    /// 2. 管線回報啟動成功，但 IOProc 一直沒被呼叫。沒有取得錄音權限時會這樣：
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
        let tripped = pipeline?.isTripped ?? false
        let count = pipeline?.callbackCount
        lock.unlock()

        if tripped {
            Log.error("偵測到訊號暴衝，已停用音訊處理")
            disable(because: "偵測到音量異常暴衝（可能是與其他音訊工具形成回授），已自動停用。")
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
        workQueue.async { [weak self] in self?.takePipeline()?.stop() }
        status = .failed("系統沒有送出任何音訊，通常是因為還沒有允許「系統音訊錄製」權限。允許後會自動開始。")
        perform(generation: generation, attempt: 0, after: Self.permissionRetryInterval, failure: nil)
    }

    private func disable(because reason: String) {
        isEnabled = false
        stopWatchdog()
        rebuild(stoppedBecause: reason)
    }

    // MARK: - 裝置變化

    private func installDeviceListenerIfNeeded() {
        guard !deviceListenerInstalled else { return }
        deviceListenerInstalled = true

        var addr = HAL.address(kAudioHardwarePropertyDefaultOutputDevice)
        let status = AudioObjectAddPropertyListenerBlock(HAL.systemObject, &addr, .main) { [weak self] _, _ in
            self?.defaultOutputDeviceChanged()
        }
        if status != noErr {
            Log.error("無法監聽預設輸出裝置變化（OSStatus \(status)）")
        }
    }

    private func defaultOutputDeviceChanged() {
        guard isEnabled, !isSuspended else { return }
        // 裝置切換時通知常會連續來好幾次；延遲重建，後來的要求會作廢前面的。
        Log.info("預設輸出裝置改變，重建管線")
        rebuild(after: 0.3)
    }
}
