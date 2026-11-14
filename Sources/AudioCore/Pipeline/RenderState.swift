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
/// 以手動配置的記憶體持有，IOProc 只拿到指標，因此 callback 內沒有 ARC、沒有配置。
/// 管線內部一律是 2 聲道立體聲（README §2.6）。
///
/// 輸入端是固定數量的「槽位」，每個槽位對應一個 tap：槽位 0 是「系統音效與其他」，
/// 其餘各自對應一個 App。槽位數量在管線建立後不變，改變的只是每個 tap 攔截誰。
struct RenderState {
    let slotCount: Int
    let slotLeft: UnsafeMutablePointer<ChannelRef>
    let slotRight: UnsafeMutablePointer<ChannelRef>

    /// 各槽位的目標增益。由 UI 執行緒寫入。
    let slotGainTarget: UnsafeMutablePointer<Float32>
    /// 各槽位目前實際套用的增益。只有即時執行緒使用，每個緩衝區線性滑向目標，避免音量跳變產生雜音。
    let slotGainCurrent: UnsafeMutablePointer<Float32>
    /// 各槽位（套用增益後）自上次讀取以來的峰值，給電平表用。
    let slotPeak: UnsafeMutablePointer<Float32>

    var outLeft: ChannelRef
    var outRight: ChannelRef

    /// 前級、EQ、Limiter、主音量。
    var dsp: DSPKernel

    // 以下數值與上面的槽位增益、峰值，都是即時執行緒與 UI 執行緒之間沒有同步的共用資料：
    // 每一個都是單一對齊整字，讀到稍舊的值也無妨。需要一致性的 EQ 係數走 DSPKernel 的鎖。
    var callbackCount: UInt64 = 0
    var inputPeak: Float32 = 0

    /// 回授保護是否已觸發。一旦觸發，這條管線只輸出靜音，直到被引擎拆除。
    var tripped: Bool = false

    init(
        slotLeft: [ChannelRef], slotRight: [ChannelRef], slotGains: [Float],
        outLeft: ChannelRef, outRight: ChannelRef, dsp: DSPKernel
    ) {
        let count = slotLeft.count
        slotCount = count
        self.slotLeft = .allocate(capacity: count)
        self.slotRight = .allocate(capacity: count)
        slotGainTarget = .allocate(capacity: count)
        slotGainCurrent = .allocate(capacity: count)
        slotPeak = .allocate(capacity: count)
        for index in 0..<count {
            self.slotLeft[index] = slotLeft[index]
            self.slotRight[index] = slotRight[index]
            slotGainTarget[index] = slotGains[index]
            slotGainCurrent[index] = slotGains[index]
            slotPeak[index] = 0
        }
        self.outLeft = outLeft
        self.outRight = outRight
        self.dsp = dsp
    }

    /// 釋放所有緩衝區。呼叫前必須確定即時執行緒已經不會再進來。
    func deallocate() {
        slotLeft.deallocate()
        slotRight.deallocate()
        slotGainTarget.deallocate()
        slotGainCurrent.deallocate()
        slotPeak.deallocate()
        dsp.deallocate()
    }
}

enum Renderer {
    /// 任何一個 tap 的原始峰值超過這個值（約 +12 dBFS）就判定為回授或異常訊號。
    /// 正常的浮點音訊即使超過 0 dBFS 也不會到這個程度。
    static let runawayThreshold: Float32 = 4

    /// IOProc 本體：把各槽位的聲音依各自的增益混合到輸出裝置的左右聲道，再就地做訊號處理。
    /// 必須保持即時安全：不配置記憶體、不阻塞。
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

        let sampleSize = MemoryLayout<Float32>.size
        let outL = state.pointee.outLeft, outR = state.pointee.outRight
        guard outL.buffer < outList.count, outR.buffer < outList.count else { return }
        let outBufL = outList[outL.buffer], outBufR = outList[outR.buffer]
        guard let outDataL = outBufL.mData, let outDataR = outBufR.mData else { return }
        let outStrideL = Int(outBufL.mNumberChannels), outStrideR = Int(outBufR.mNumberChannels)
        guard outL.channel < outStrideL, outR.channel < outStrideR else { return }
        let outFrames = min(
            Int(outBufL.mDataByteSize) / (sampleSize * outStrideL),
            Int(outBufR.mDataByteSize) / (sampleSize * outStrideR)
        )
        guard outFrames > 0 else { return }
        let dstL = outDataL.assumingMemoryBound(to: Float32.self) + outL.channel
        let dstR = outDataR.assumingMemoryBound(to: Float32.self) + outR.channel

        var rawPeak: Float32 = 0
        var runaway = false
        let limit = runawayThreshold

        for slot in 0..<state.pointee.slotCount {
            let inL = state.pointee.slotLeft[slot], inR = state.pointee.slotRight[slot]
            let target = state.pointee.slotGainTarget[slot]
            // 不論這個槽位這次有沒有資料，增益都要到位，下次有聲音時才不會從舊的值開始滑。
            defer { state.pointee.slotGainCurrent[slot] = target }

            guard inL.buffer < inList.count, inR.buffer < inList.count else { continue }
            let inBufL = inList[inL.buffer], inBufR = inList[inR.buffer]
            guard let inDataL = inBufL.mData, let inDataR = inBufR.mData else { continue }
            let inStrideL = Int(inBufL.mNumberChannels), inStrideR = Int(inBufR.mNumberChannels)
            guard inL.channel < inStrideL, inR.channel < inStrideR else { continue }
            let frames = min(
                outFrames,
                min(Int(inBufL.mDataByteSize) / (sampleSize * inStrideL),
                    Int(inBufR.mDataByteSize) / (sampleSize * inStrideR))
            )
            guard frames > 0 else { continue }

            let srcL = inDataL.assumingMemoryBound(to: Float32.self) + inL.channel
            let srcR = inDataR.assumingMemoryBound(to: Float32.self) + inR.channel

            var gain = state.pointee.slotGainCurrent[slot]
            let gainStep = (target - gain) / Float32(frames)
            var slotRawPeak: Float32 = 0
            var slotPeak: Float32 = 0
            for frame in 0..<frames {
                let left = srcL[frame * inStrideL]
                let right = srcR[frame * inStrideR]
                let absL = abs(left), absR = abs(right)
                // 用「不是 ≤」而不是「>」，這樣 NaN 也會被當成異常。
                if !(absL <= limit) || !(absR <= limit) { runaway = true }
                slotRawPeak = max(slotRawPeak, max(absL, absR))
                gain += gainStep
                let scaledL = left * gain, scaledR = right * gain
                slotPeak = max(slotPeak, max(abs(scaledL), abs(scaledR)))
                dstL[frame * outStrideL] += scaledL
                dstR[frame * outStrideR] += scaledR
            }
            rawPeak = max(rawPeak, slotRawPeak)
            state.pointee.slotPeak[slot] = max(state.pointee.slotPeak[slot], slotPeak)
        }

        // 回授保護：訊號異常暴衝（或出現 NaN）時，丟掉這個緩衝區並鎖住輸出。
        // 要在訊號處理之前檢查，否則 NaN 會進到濾波器的狀態裡。
        if runaway {
            state.pointee.tripped = true
            for buffer in outList {
                if let data = buffer.mData {
                    memset(data, 0, Int(buffer.mDataByteSize))
                }
            }
            return
        }
        state.pointee.inputPeak = max(state.pointee.inputPeak, rawPeak)

        state.pointee.dsp.process(
            left: dstL, leftStride: outStrideL,
            right: dstR, rightStride: outStrideR,
            frames: outFrames
        )
    }
}
