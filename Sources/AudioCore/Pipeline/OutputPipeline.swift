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

/// 單一輸出裝置的處理管線：tap → （之後的增益／EQ／Limiter）→ 實體輸出裝置。
///
/// 做法是建立一個 private aggregate device，把實體輸出裝置當子裝置、tap 掛在 tap list，
/// 然後在 aggregate device 上跑 IOProc。每個使用中的輸出裝置各有一條（README §2.5）。
final class OutputPipeline {
    let info: PipelineInfo

    private let tap: ProcessTap
    private let aggregateID: AudioObjectID
    private var ioProcID: AudioDeviceIOProcID?
    private var isRunning = false
    private let state: UnsafeMutablePointer<RenderState>

    init(outputDevice: AudioObjectID, excluding excludedProcesses: [AudioObjectID]) throws {
        let outputUID = try HAL.deviceUID(outputDevice)
        let deviceName = HAL.deviceName(outputDevice)

        let tap = try ProcessTap(
            outputDeviceUID: outputUID, streamIndex: 0,
            excluding: excludedProcesses, name: "SoundDeck"
        )
        guard tap.channelCount >= 1,
              tap.format.mFormatID == kAudioFormatLinearPCM,
              tap.format.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              tap.format.mBitsPerChannel == 32
        else {
            throw CoreAudioError(status: kAudioDeviceUnsupportedFormatError, operation: "檢查 tap 格式")
        }

        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "SoundDeck (\(deviceName))",
            kAudioAggregateDeviceUIDKey: "local.sounddeck.aggregate.\(UUID().uuidString)",
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [
                [kAudioSubDeviceUIDKey: outputUID],
            ],
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapUIDKey: tap.uuid.uuidString,
                    kAudioSubTapDriftCompensationKey: true,
                ],
            ],
        ]

        var aggregateID = AudioObjectID(kAudioObjectUnknown)
        try HAL.check(
            AudioHardwareCreateAggregateDevice(description as CFDictionary, &aggregateID),
            "建立 aggregate device"
        )

        do {
            // aggregate device 剛建立時，串流配置可能還沒就緒，稍等一下。
            var inputLayout: [Int] = []
            var outputLayout: [Int] = []
            for _ in 0..<40 {
                inputLayout = (try? HAL.channelLayout(aggregateID, scope: kAudioObjectPropertyScopeInput)) ?? []
                outputLayout = (try? HAL.channelLayout(aggregateID, scope: kAudioObjectPropertyScopeOutput)) ?? []
                if inputLayout.reduce(0, +) >= tap.channelCount, outputLayout.reduce(0, +) >= 1 { break }
                Thread.sleep(forTimeInterval: 0.05)
            }
            let inputTotal = inputLayout.reduce(0, +)
            let outputTotal = outputLayout.reduce(0, +)
            guard inputTotal >= tap.channelCount, outputTotal >= 1 else {
                throw CoreAudioError(status: kAudioHardwareNotReadyError, operation: "等待 aggregate device 就緒")
            }

            // 輸入端：實體裝置若自己有輸入聲道（例如 USB 耳麥），它們排在前面，tap 的聲道排在最後。
            // 一定要取 tap 的聲道，否則會把麥克風送進喇叭。
            // tap 的聲道配置跟裝置串流相同，所以輸入與輸出都取裝置偏好的立體聲聲道；
            // 單聲道則左右都用同一個。
            let preferred = HAL.preferredStereoChannels(outputDevice)
            let tapOffset = inputTotal - tap.channelCount
            let tapLeft = tapOffset + min(preferred.left - 1, tap.channelCount - 1)
            let tapRight = tapOffset + min(preferred.right - 1, tap.channelCount - 1)
            guard let inLeft = ChannelRef.resolve(globalIndex: tapLeft, layout: inputLayout),
                  let inRight = ChannelRef.resolve(globalIndex: tapRight, layout: inputLayout)
            else {
                throw CoreAudioError(status: kAudioHardwareBadStreamError, operation: "定位 tap 聲道")
            }

            let leftIndex = min(preferred.left - 1, outputTotal - 1)
            let rightIndex = min(preferred.right - 1, outputTotal - 1)
            guard let outLeft = ChannelRef.resolve(globalIndex: leftIndex, layout: outputLayout),
                  let outRight = ChannelRef.resolve(globalIndex: rightIndex, layout: outputLayout)
            else {
                throw CoreAudioError(status: kAudioHardwareBadStreamError, operation: "定位輸出聲道")
            }

            let info = PipelineInfo(
                deviceName: deviceName,
                sampleRate: try HAL.sampleRate(aggregateID),
                bufferFrames: try HAL.bufferFrameSize(aggregateID),
                inputChannels: inputTotal,
                outputChannels: outputTotal
            )

            let state = UnsafeMutablePointer<RenderState>.allocate(capacity: 1)
            state.initialize(to: RenderState(
                inLeft: inLeft, inRight: inRight, outLeft: outLeft, outRight: outRight
            ))

            self.tap = tap
            self.aggregateID = aggregateID
            self.info = info
            self.state = state

            Log.info(
                "管線建立：\(deviceName) \(info.sampleRate) Hz，緩衝 \(info.bufferFrames) frames"
                + "（\(String(format: "%.1f", info.bufferMilliseconds)) ms），"
                + "輸入配置 \(inputLayout)（tap 起始聲道 \(tapOffset)），"
                + "輸出配置 \(outputLayout)（L=\(leftIndex) R=\(rightIndex)）"
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
        // IOProc 已停止並銷毀，之後不會再有人碰 state。tap 由屬性釋放時銷毀。
        state.deinitialize(count: 1)
        state.deallocate()
    }
}
