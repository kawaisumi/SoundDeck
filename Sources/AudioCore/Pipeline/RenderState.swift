import CoreAudio
import Foundation

/// 指向 AudioBufferList 中的某一個聲道。
struct ChannelRef {
    var buffer: Int
    var channel: Int

    /// 把「全域聲道編號」（0 起算，跨所有 buffer 連續計數）換算成 buffer 與 buffer 內的聲道。
    static func resolve(globalIndex: Int, layout: [Int]) -> ChannelRef? {
        var remaining = globalIndex
        for (bufferIndex, channels) in layout.enumerated() {
            if remaining < channels {
                return ChannelRef(buffer: bufferIndex, channel: remaining)
            }
            remaining -= channels
        }
        return nil
    }
}

/// 即時音訊執行緒使用的狀態。
///
/// 以手動配置的記憶體持有，IOProc 只拿到指標，因此 callback 內沒有 ARC、沒有鎖、沒有配置。
/// 管線內部一律是 2 聲道立體聲（README §2.6）。
struct RenderState {
    var inLeft: ChannelRef
    var inRight: ChannelRef
    var outLeft: ChannelRef
    var outRight: ChannelRef

    /// 管線末端的目標線性增益（軟體音量）。由 UI 執行緒寫入。
    var targetGain: Float32 = 1
    /// 目前實際套用的增益。只由即時執行緒讀寫，每個緩衝區線性滑向 targetGain，避免音量跳變產生雜音。
    var currentGain: Float32 = 1

    // 診斷用。由即時執行緒寫入、UI 執行緒讀取；
    // 目前是單純的對齊整字寫入，M2 加入 DSP 參數傳遞時改為正式的 atomic。
    var callbackCount: UInt64 = 0
    var inputPeak: Float32 = 0

    /// 回授保護是否已觸發。一旦觸發，這條管線只輸出靜音，直到被引擎拆除。
    var tripped: Bool = false
}

enum Renderer {
    /// 輸入峰值超過這個值（約 +12 dBFS）就判定為回授或異常訊號。
    /// 正常的浮點音訊即使超過 0 dBFS 也不會到這個程度。
    static let runawayThreshold: Float32 = 4

    /// IOProc 本體：把 tap 的立體聲複製到輸出裝置的左右聲道。
    /// 必須保持即時安全：不配置記憶體、不上鎖、不呼叫會阻塞的東西。
    @inline(__always)
    static func render(
        _ state: UnsafeMutablePointer<RenderState>,
        input: UnsafePointer<AudioBufferList>,
        output: UnsafeMutablePointer<AudioBufferList>
    ) {
        let inList = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        let outList = UnsafeMutableAudioBufferListPointer(output)

        // 先把所有輸出清為靜音；沒寫到的聲道（多聲道裝置的 3 以後）維持靜音。
        for buffer in outList {
            if let data = buffer.mData {
                memset(data, 0, Int(buffer.mDataByteSize))
            }
        }

        state.pointee.callbackCount &+= 1
        if state.pointee.tripped { return }

        let inL = state.pointee.inLeft, inR = state.pointee.inRight
        let outL = state.pointee.outLeft, outR = state.pointee.outRight
        guard inL.buffer < inList.count, inR.buffer < inList.count,
              outL.buffer < outList.count, outR.buffer < outList.count
        else { return }

        let inBufL = inList[inL.buffer], inBufR = inList[inR.buffer]
        let outBufL = outList[outL.buffer], outBufR = outList[outR.buffer]
        guard let inDataL = inBufL.mData, let inDataR = inBufR.mData,
              let outDataL = outBufL.mData, let outDataR = outBufR.mData
        else { return }

        let inStrideL = Int(inBufL.mNumberChannels), inStrideR = Int(inBufR.mNumberChannels)
        let outStrideL = Int(outBufL.mNumberChannels), outStrideR = Int(outBufR.mNumberChannels)
        guard inL.channel < inStrideL, inR.channel < inStrideR,
              outL.channel < outStrideL, outR.channel < outStrideR
        else { return }

        let sampleSize = MemoryLayout<Float32>.size
        let frames = min(
            min(Int(inBufL.mDataByteSize) / (sampleSize * inStrideL),
                Int(inBufR.mDataByteSize) / (sampleSize * inStrideR)),
            min(Int(outBufL.mDataByteSize) / (sampleSize * outStrideL),
                Int(outBufR.mDataByteSize) / (sampleSize * outStrideR))
        )
        guard frames > 0 else { return }

        let srcL = inDataL.assumingMemoryBound(to: Float32.self) + inL.channel
        let srcR = inDataR.assumingMemoryBound(to: Float32.self) + inR.channel
        let dstL = outDataL.assumingMemoryBound(to: Float32.self) + outL.channel
        let dstR = outDataR.assumingMemoryBound(to: Float32.self) + outR.channel

        var gain = state.pointee.currentGain
        let target = state.pointee.targetGain
        let gainStep = (target - gain) / Float32(frames)
        var peak: Float32 = 0
        for frame in 0..<frames {
            let left = srcL[frame * inStrideL]
            let right = srcR[frame * inStrideR]
            peak = max(peak, max(abs(left), abs(right)))
            gain += gainStep
            // 暫時的硬性上限，M2 會換成正式的 Limiter。
            dstL[frame * outStrideL] = min(max(left * gain, -1), 1)
            dstR[frame * outStrideR] = min(max(right * gain, -1), 1)
        }
        state.pointee.currentGain = target
        state.pointee.inputPeak = max(state.pointee.inputPeak, peak)

        // 回授保護：訊號異常暴衝（或出現 NaN）時，丟掉這個緩衝區並鎖住輸出。
        if !(peak <= runawayThreshold) {
            state.pointee.tripped = true
            for buffer in outList {
                if let data = buffer.mData {
                    memset(data, 0, Int(buffer.mDataByteSize))
                }
            }
        }
    }
}
