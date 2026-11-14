import Combine
import CoreAudio
import Foundation

/// 音訊引擎的對外介面。所有公開方法都必須在主執行緒呼叫。
///
/// M0 只有一條管線（系統預設輸出裝置）。之後開啟「依 App 指定輸出裝置」時，
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
    public private(set) var isEnabled = false

    /// 建立與拆除管線可能會短暫阻塞，放在專用的序列佇列上，不卡 UI。
    private let workQueue = DispatchQueue(label: "local.sounddeck.engine")
    private let lock = NSLock()
    private var pipeline: OutputPipeline? // 由 lock 保護

    private var watchdog: Timer?
    private var deviceListenerInstalled = false
    private var pendingRebuild: DispatchWorkItem?

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
        stopWatchdog()
        workQueue.sync { self.takePipeline()?.stop() }
    }

    /// 讀取目前管線的診斷數值；沒有管線時回傳 nil。
    public func readStats() -> PipelineStats? {
        lock.lock()
        defer { lock.unlock() }
        return pipeline?.readStats()
    }

    // MARK: - 管線生命週期

    private func takePipeline() -> OutputPipeline? {
        lock.lock()
        defer { lock.unlock() }
        let old = pipeline
        pipeline = nil
        return old
    }

    private func rebuild(stoppedBecause failure: String? = nil) {
        let shouldRun = isEnabled
        if shouldRun { status = .starting }

        workQueue.async { [weak self] in
            guard let self else { return }

            // 先拆掉舊的。tap 一停止讀取，系統聲音就會恢復成原本的直接輸出。
            if let old = self.takePipeline() {
                old.stop()
            }

            guard shouldRun else {
                self.publish(failure.map { .failed($0) } ?? .stopped)
                return
            }

            do {
                let device = try HAL.defaultOutputDevice()
                // 一定要把自己排除，否則我們送出去的聲音又會被自己攔截，形成回授。
                guard let ownProcess = HAL.processObject(pid: getpid()) else {
                    throw CoreAudioError(status: kAudioHardwareUnspecifiedError, operation: "取得自身的音訊 process 物件")
                }
                let newPipeline = try OutputPipeline(outputDevice: device, excluding: [ownProcess])
                try newPipeline.start()

                self.lock.lock()
                self.pipeline = newPipeline
                self.lock.unlock()
                self.publish(.running(newPipeline.info))
            } catch {
                Log.error("管線啟動失敗：\(error)")
                self.publish(.failed("\(error)"))
            }
        }
    }

    private func publish(_ status: Status) {
        DispatchQueue.main.async { self.status = status }
    }

    // MARK: - 回授保護

    /// 即時執行緒偵測到訊號暴衝時只會鎖住輸出；這裡負責把管線真正拆掉並通知使用者。
    private func startWatchdog() {
        guard watchdog == nil else { return }
        watchdog = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            guard let self, self.isEnabled else { return }
            self.lock.lock()
            let tripped = self.pipeline?.isTripped ?? false
            self.lock.unlock()
            guard tripped else { return }

            Log.error("偵測到訊號暴衝，已停用音訊處理")
            self.isEnabled = false
            self.stopWatchdog()
            self.rebuild(stoppedBecause: "偵測到音量異常暴衝（可能是與其他音訊工具形成回授），已自動停用。")
        }
    }

    private func stopWatchdog() {
        watchdog?.invalidate()
        watchdog = nil
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
        guard isEnabled else { return }
        // 裝置切換時通知常會連續來好幾次，稍微等一下再重建一次就好。
        pendingRebuild?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.isEnabled else { return }
            Log.info("預設輸出裝置改變，重建管線")
            self.rebuild()
        }
        pendingRebuild = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }
}
