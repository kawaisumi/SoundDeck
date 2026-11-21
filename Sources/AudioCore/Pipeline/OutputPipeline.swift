import CoreAudio
import Foundation

/// 一條管線的靜態資訊，建立後不變。
public struct PipelineInfo: Equatable, Sendable {
    public let deviceName: String
    public let sampleRate: Double
    public let bufferFrames: Int
    public let inputChannels: Int
    public let outputChannels: Int

    /// 一個緩衝區的時間長度（毫秒），是這條管線額外增加延遲的主要來源。
    public var bufferMilliseconds: Double {
        sampleRate > 0 ? Double(bufferFrames) / sampleRate * 1000 : 0
    }
}

public struct PipelineStats: Equatable, Sendable {
    public var callbackCount: UInt64
    /// 自上次讀取以來的輸入峰值（線性，1.0 = 0 dBFS）。
    public var inputPeak: Float
}

/// 混音器的路由狀態：每個槽位攔截哪些 process、增益多少、要從哪個裝置播出。
///
/// 槽位 0 固定是「系統音效與其他」：攔截所有沒有被分配到其他槽位的聲音，它的 `processes` 與 `devices` 不使用。
struct MixerRouting: Equatable {
    var processes: [[AudioObjectID]]
    var gains: [Float]
    /// 各槽位指定的輸出裝置 UID；nil 表示跟隨系統預設。
    var devices: [String?]

    static func empty(slotCount: Int) -> MixerRouting {
        MixerRouting(
            processes: Array(repeating: [], count: slotCount),
            gains: Array(repeating: 1, count: slotCount),
            devices: Array(repeating: nil, count: slotCount)
        )
    }
}

/// 單一輸出裝置的處理管線：各 App 的 tap → 各自的增益 → 混合 → 前級／EQ／Limiter／主音量 → 實體輸出裝置。
///
/// 做法是建立一個 private aggregate device，把實體輸出裝置當子裝置，並掛上固定數量的 tap（槽位）。
/// 槽位數量建立後不變，App 的增減只是改寫各 tap 攔截的對象，所以 IOProc 不需要重啟、聲音不會中斷。
///
/// 每個使用中的輸出裝置各有一條管線（README §2.5）。管線有兩個裝置的概念：
/// - **輸出裝置**：這條管線把聲音送到哪裡。
/// - **來源裝置**：各 App 槽位的 tap 攔截「送往哪個裝置」的聲音。App 一律是往系統預設輸出播放的，
///   所以來源永遠是系統預設輸出；把某個 App 指定到別的裝置，就是在那個裝置的管線裡攔截它送往預設輸出的聲音。
/// 槽位 0（其他）則是攔截原本就直接送往這條管線輸出裝置的聲音。
final class OutputPipeline {
    let info: PipelineInfo
    let deviceUID: String

    /// taps[0] 是「其他」（排除模式），其餘是各 App 的槽位（包含模式）。
    private let taps: [ProcessTap]
    private let ownProcess: AudioObjectID
    private let aggregateID: AudioObjectID
    private var ioProcID: AudioDeviceIOProcID?
    private var isRunning = false
    private let state: UnsafeMutablePointer<RenderState>

    var slotCount: Int { taps.count }

    /// - Parameters:
    ///   - sourceDeviceUID: App 槽位的 tap 要攔截送往哪個裝置的聲音（系統預設輸出）。
    ///   - slotProcesses: 各槽位要攔截的 process；索引 0 不使用。
    ///   - excluded: 已經被任何一條管線的槽位接手的所有 process，槽位 0 不能再抓它們。
    init(
        outputDevice: AudioObjectID,
        sourceDeviceUID: String,
        ownProcess: AudioObjectID,
        slotProcesses: [[AudioObjectID]],
        excluded: [AudioObjectID],
        slotGains: [Float],
        initialGain: Float,
        initialBalance: Float,
        equalizer: EQSettings
    ) throws {
        let outputUID = try HAL.deviceUID(outputDevice)
        let deviceName = HAL.deviceName(outputDevice)
        let slotCount = slotProcesses.count

        // 自己一定要排除，否則我們送出去的聲音又會被自己攔截，形成回授。
        var taps: [ProcessTap] = [
            try ProcessTap(
                mode: .excluding, processes: [ownProcess] + excluded,
                outputDeviceUID: outputUID, name: "SoundDeck 其他"
            ),
        ]
        for slot in 1..<slotCount {
            taps.append(try ProcessTap(
                mode: .including, processes: slotProcesses[slot],
                outputDeviceUID: sourceDeviceUID, name: "SoundDeck 槽位 \(slot)"
            ))
        }

        let tapChannels = taps[0].channelCount
        for tap in taps {
            guard tap.channelCount == tapChannels, tapChannels >= 1,
                  tap.format.mFormatID == kAudioFormatLinearPCM,
                  tap.format.mFormatFlags & kAudioFormatFlagIsFloat != 0,
                  tap.format.mBitsPerChannel == 32
            else {
                throw CoreAudioError(status: kAudioDeviceUnsupportedFormatError, operation: "檢查 tap 格式")
            }
        }

        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "SoundDeck (\(deviceName))",
            kAudioAggregateDeviceUIDKey: HAL.aggregateUIDPrefix + UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [
                [kAudioSubDeviceUIDKey: outputUID],
            ],
            kAudioAggregateDeviceTapListKey: taps.map { tap -> [String: Any] in
                [
                    kAudioSubTapUIDKey: tap.uuid.uuidString,
                    kAudioSubTapDriftCompensationKey: true,
                ]
            },
        ]

        var aggregateID = AudioObjectID(kAudioObjectUnknown)
        try HAL.check(
            AudioHardwareCreateAggregateDevice(description as CFDictionary, &aggregateID),
            "建立 aggregate device"
        )

        do {
            // aggregate device 剛建立時，串流配置可能還沒就緒，稍等一下。
            let tapChannelTotal = tapChannels * slotCount
            var inputLayout: [Int] = []
            var outputLayout: [Int] = []
            for _ in 0..<40 {
                inputLayout = (try? HAL.channelLayout(aggregateID, scope: kAudioObjectPropertyScopeInput)) ?? []
                outputLayout = (try? HAL.channelLayout(aggregateID, scope: kAudioObjectPropertyScopeOutput)) ?? []
                if inputLayout.reduce(0, +) >= tapChannelTotal, outputLayout.reduce(0, +) >= 1 { break }
                Thread.sleep(forTimeInterval: 0.05)
            }
            let inputTotal = inputLayout.reduce(0, +)
            let outputTotal = outputLayout.reduce(0, +)
            guard inputTotal >= tapChannelTotal, outputTotal >= 1 else {
                throw CoreAudioError(status: kAudioHardwareNotReadyError, operation: "等待 aggregate device 就緒")
            }

            // 輸入端：實體裝置若自己有輸入聲道（例如 USB 耳麥），它們排在前面，
            // 各 tap 的聲道依 tap list 的順序排在最後。一定要取 tap 的聲道，否則會把麥克風送進喇叭。
            // tap 的格式跟裝置串流相同，所以第 c 個 tap 聲道直接對應裝置的第 c 個輸出聲道，不做降混：
            // 5.1 裝置上，中置、重低音、環繞聲道都照原位置送出。
            let tapOffset = inputTotal - tapChannelTotal
            let channelCount = min(tapChannels, outputTotal, DSPKernel.maxChannels)
            var slotChannels: [ChannelRef] = []
            for slot in 0..<slotCount {
                for channel in 0..<channelCount {
                    guard let ref = ChannelRef.resolve(
                        globalIndex: tapOffset + slot * tapChannels + channel, layout: inputLayout
                    ) else {
                        throw CoreAudioError(status: kAudioHardwareBadStreamError, operation: "定位 tap 聲道")
                    }
                    slotChannels.append(ref)
                }
            }
            var outChannels: [ChannelRef] = []
            for channel in 0..<channelCount {
                guard let ref = ChannelRef.resolve(globalIndex: channel, layout: outputLayout) else {
                    throw CoreAudioError(status: kAudioHardwareBadStreamError, operation: "定位輸出聲道")
                }
                outChannels.append(ref)
            }
            let sides = HAL.channelSides(outputDevice, count: channelCount)

            let info = PipelineInfo(
                deviceName: deviceName,
                sampleRate: try HAL.sampleRate(aggregateID),
                bufferFrames: try HAL.bufferFrameSize(aggregateID),
                inputChannels: inputTotal,
                outputChannels: outputTotal
            )

            let state = UnsafeMutablePointer<RenderState>.allocate(capacity: 1)
            state.initialize(to: RenderState(
                slotChannels: slotChannels, outChannels: outChannels, slotGains: slotGains,
                dsp: DSPKernel(
                    sampleRate: info.sampleRate, channelCount: channelCount, channelSides: sides,
                    initialVolume: Double(initialGain), initialBalance: Double(initialBalance)
                )
            ))

            self.deviceUID = outputUID
            self.taps = taps
            self.ownProcess = ownProcess
            self.aggregateID = aggregateID
            self.info = info
            self.state = state

            setEqualizer(equalizer)

            Log.info(
                "管線建立：\(deviceName) \(info.sampleRate) Hz，緩衝 \(info.bufferFrames) frames" // 不翻譯
                + "（\(String(format: "%.1f", info.bufferMilliseconds)) ms），\(slotCount) 個槽位，" // 不翻譯
                + "輸入配置 \(inputLayout)（tap 起始聲道 \(tapOffset)），" // 不翻譯
                + "輸出配置 \(outputLayout)，處理 \(channelCount) 個聲道 \(sides.map(\.rawValue))" // 不翻譯
            )
        } catch {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            throw error
        }
    }

    func start() throws {
        guard !isRunning else { return }
        let state = self.state
        var procID: AudioDeviceIOProcID?
        try HAL.check(
            AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, nil) { _, input, _, output, _ in
                Renderer.render(state, input: input, output: output)
            },
            "建立 IOProc"
        )
        ioProcID = procID

        do {
            try HAL.check(AudioDeviceStart(aggregateID, procID), "啟動音訊裝置")
        } catch {
            if let procID { AudioDeviceDestroyIOProcID(aggregateID, procID) }
            ioProcID = nil
            throw error
        }
        isRunning = true
    }

    func stop() {
        guard let procID = ioProcID else { return }
        if isRunning {
            AudioDeviceStop(aggregateID, procID)
            isRunning = false
        }
        AudioDeviceDestroyIOProcID(aggregateID, procID)
        ioProcID = nil
    }

    // MARK: - 混音器

    // 套用新的路由分成兩步，由引擎對所有管線先做完第一步、再做第二步。
    // 順序是刻意安排的：一個 process 在槽位之間、管線之間搬移時，寧可有一瞬間兩邊都抓到（聲音短暫重疊），
    // 也不要兩邊都沒抓到（那一瞬間它的原聲會不受控制地從預設裝置直接播出）。

    /// 第一步：更新增益、讓有新成員的槽位開始攔截、更新槽位 0 的排除清單。
    func beginRouting(slotProcesses: [[AudioObjectID]], excluded: [AudioObjectID], slotGains: [Float]) {
        guard slotProcesses.count == slotCount, slotGains.count == slotCount else { return }

        for slot in 0..<slotCount {
            state.pointee.slotGainTarget[slot] = max(0, slotGains[slot])
        }
        for slot in 1..<slotCount {
            let current = Set(taps[slot].processes)
            if slotProcesses[slot].contains(where: { !current.contains($0) }) {
                taps[slot].setProcesses(Array(current.union(slotProcesses[slot])).sorted())
            }
        }
        taps[0].setProcesses([ownProcess] + excluded)
    }

    /// 第二步：讓槽位放掉已經不屬於它的 process。
    func finishRouting(slotProcesses: [[AudioObjectID]]) {
        guard slotProcesses.count == slotCount else { return }
        for slot in 1..<slotCount {
            taps[slot].setProcesses(slotProcesses[slot])
        }
    }

    /// 讀取各槽位的峰值，並歸零以便下次重新累計。
    func readSlotPeaks() -> [Float] {
        (0..<slotCount).map { slot in
            let peak = state.pointee.slotPeak[slot]
            state.pointee.slotPeak[slot] = 0
            return peak
        }
    }

    // MARK: - 主音量與 EQ

    /// 設定管線末端的增益（軟體音量）。即時執行緒會平滑地過渡過去。
    /// 設定左右平衡（−1…1）。
    func setBalance(_ balance: Float) {
        withUnsafeMutablePointer(to: &state.pointee.dsp) {
            DSPKernel.setBalance($0, Double(balance))
        }
    }

    func setGain(_ gain: Float) {
        withUnsafeMutablePointer(to: &state.pointee.dsp) {
            DSPKernel.setVolume($0, Double(gain))
        }
    }

    /// 套用 EQ 設定。係數依這條管線的取樣率計算。
    func setEqualizer(_ settings: EQSettings) {
        let sampleRate = info.sampleRate
        var filters: [Biquad] = []
        var preampDB = 0.0
        if !settings.isBypassed {
            filters = settings.bands
                .filter(\.isEnabled)
                .prefix(EQSettings.maxBands)
                .map { Biquad(band: $0, sampleRate: sampleRate) }
            preampDB = settings.effectivePreampDB(sampleRate: sampleRate)
        }
        let preamp = pow(10, preampDB / 20)
        withUnsafeMutablePointer(to: &state.pointee.dsp) {
            DSPKernel.update($0, filters: filters, preamp: preamp)
        }
    }

    // MARK: - 頻譜

    func setSpectrumEnabled(_ enabled: Bool) {
        state.pointee.spectrumEnabled = enabled
    }

    /// 最近 `count` 個處理後的 sample（左右平均），舊的在前。
    func readSpectrumSamples(count: Int) -> [Float] {
        let capacity = RenderState.spectrumCapacity
        let count = min(count, capacity)
        let end = state.pointee.spectrumWriteIndex
        let buffer = state.pointee.spectrumBuffer
        return (0..<count).map { offset in
            buffer[(end - count + offset) & (capacity - 1)]
        }
    }

    // MARK: - 診斷

    /// IOProc 至今被呼叫的次數。啟動後應該持續增加。
    var callbackCount: UInt64 { state.pointee.callbackCount }

    /// 回授保護是否已觸發（見 `Renderer.runawayThreshold`）。
    var isTripped: Bool { state.pointee.tripped }

    /// 讀取診斷數值，並把峰值歸零以便下次重新累計。
    func readStats() -> PipelineStats {
        let stats = PipelineStats(
            callbackCount: state.pointee.callbackCount,
            inputPeak: state.pointee.inputPeak
        )
        state.pointee.inputPeak = 0
        return stats
    }

    deinit {
        stop()
        AudioHardwareDestroyAggregateDevice(aggregateID)
        // IOProc 已停止並銷毀，之後不會再有人碰 state。各 tap 由屬性釋放時銷毀。
        state.pointee.deallocate()
        state.deinitialize(count: 1)
        state.deallocate()
    }
}
