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
///
/// 聲道數 `channelCount` 等於輸出裝置串流的聲道數（立體聲 2、5.1 是 6、7.1 是 8）：
/// tap 攔截的格式和裝置串流相同，所以每個聲道照原位置混合、處理、送出，不做降混。
///
/// 輸入端是固定數量的「槽位」，每個槽位對應一個 tap：槽位 0 是「系統音效與其他」，
/// 其餘各自對應一個 App。槽位數量在管線建立後不變，改變的只是每個 tap 攔截誰。
struct RenderState {
    let slotCount: Int
    let channelCount: Int
    /// 第 slot 個槽位的第 c 個聲道在輸入緩衝區的位置：`slotChannels[slot × channelCount + c]`。
    let slotChannels: UnsafeMutablePointer<ChannelRef>
    /// 第 c 個聲道在輸出緩衝區的位置。
    let outChannels: UnsafeMutablePointer<ChannelRef>
    /// 每次 callback 解析出的各聲道輸出指標與間隔（預先配置，callback 內只寫入不配置）。
    let outPointers: UnsafeMutablePointer<UnsafeMutablePointer<Float32>>
    let outStrides: UnsafeMutablePointer<Int>
    private let placeholder: UnsafeMutablePointer<Float32>

    /// 各槽位的目標增益。由 UI 執行緒寫入。
    let slotGainTarget: UnsafeMutablePointer<Float32>
    /// 各槽位目前實際套用的增益。只有即時執行緒使用，每個緩衝區線性滑向目標，避免音量跳變產生雜音。
    let slotGainCurrent: UnsafeMutablePointer<Float32>
    /// 各槽位（套用增益後）自上次讀取以來的峰值，給電平表用。
    let slotPeak: UnsafeMutablePointer<Float32>

    /// 前級、EQ、Limiter、主音量、平衡。
    var dsp: DSPKernel

    // 以下數值與上面的槽位增益、峰值，都是即時執行緒與 UI 執行緒之間沒有同步的共用資料：
    // 每一個都是單一對齊整字，讀到稍舊的值也無妨。需要一致性的 EQ 係數走 DSPKernel 的鎖。
    var callbackCount: UInt64 = 0
    var inputPeak: Float32 = 0

    /// 回授保護是否已觸發。一旦觸發，這條管線只輸出靜音，直到被引擎拆除。
    var tripped: Bool = false

    // 頻譜分析用：處理後的聲音（所有聲道平均）寫進環狀緩衝區，UI 執行緒讀最近的一段來算頻譜。
    // 只有 EQ 編輯器顯示頻譜時才寫入。兩邊沒有同步，讀到正在被覆寫的一小段只會讓某一格畫面略有誤差。
    static let spectrumCapacity = 8192 // 2 的次方，方便用位元遮罩取餘數
    let spectrumBuffer: UnsafeMutablePointer<Float32>
    var spectrumWriteIndex: Int = 0
    var spectrumEnabled: Bool = false

    /// - Parameters:
    ///   - slotChannels: 每個槽位各聲道的輸入位置，依槽位排列，長度為槽位數 × 聲道數。
    ///   - outChannels: 各聲道的輸出位置，長度即為聲道數。
    init(slotChannels: [ChannelRef], outChannels: [ChannelRef], slotGains: [Float], dsp: DSPKernel) {
        let channels = max(outChannels.count, 1)
        let slots = slotChannels.count / channels
        precondition(slots * channels == slotChannels.count && slotGains.count == slots, "槽位與聲道數不一致")
        slotCount = slots
        channelCount = channels

        self.slotChannels = .allocate(capacity: slotChannels.count)
        self.slotChannels.initialize(from: slotChannels, count: slotChannels.count)
        self.outChannels = .allocate(capacity: channels)
        self.outChannels.initialize(from: outChannels, count: channels)
        placeholder = .allocate(capacity: 1)
        placeholder.initialize(to: 0)
        outPointers = .allocate(capacity: channels)
        outPointers.initialize(repeating: placeholder, count: channels)
        outStrides = .allocate(capacity: channels)
        outStrides.initialize(repeating: 1, count: channels)

        slotGainTarget = .allocate(capacity: slots)
        slotGainTarget.initialize(from: slotGains, count: slots)
        slotGainCurrent = .allocate(capacity: slots)
        slotGainCurrent.initialize(from: slotGains, count: slots)
        slotPeak = .allocate(capacity: slots)
        slotPeak.initialize(repeating: 0, count: slots)

        spectrumBuffer = .allocate(capacity: Self.spectrumCapacity)
        spectrumBuffer.initialize(repeating: 0, count: Self.spectrumCapacity)
        self.dsp = dsp
    }

    /// 釋放所有緩衝區。呼叫前必須確定即時執行緒已經不會再進來。
    func deallocate() {
        slotChannels.deallocate()
        outChannels.deallocate()
        outPointers.deallocate()
        outStrides.deallocate()
        placeholder.deallocate()
        slotGainTarget.deallocate()
        slotGainCurrent.deallocate()
        slotPeak.deallocate()
        spectrumBuffer.deallocate()
        dsp.deallocate()
    }
}

enum Renderer {
    /// 任何一個 tap 的原始峰值超過這個值（約 +12 dBFS）就判定為回授或異常訊號。
    /// 正常的浮點音訊即使超過 0 dBFS 也不會到這個程度。
    static let runawayThreshold: Float32 = 4

    /// IOProc 本體：把各槽位的聲音依各自的增益、逐聲道混合到輸出裝置，再就地做訊號處理。
    /// 必須保持即時安全：不配置記憶體、不阻塞。
    @inline(__always)
    static func render(
        _ state: UnsafeMutablePointer<RenderState>,
        input: UnsafePointer<AudioBufferList>,
        output: UnsafeMutablePointer<AudioBufferList>
    ) {
        let inList = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        let outList = UnsafeMutableAudioBufferListPointer(output)

        // 先把所有輸出清為靜音；沒有對應的聲道（裝置的其他串流）維持靜音。
        for buffer in outList {
            if let data = buffer.mData {
                memset(data, 0, Int(buffer.mDataByteSize))
            }
        }

        state.pointee.callbackCount &+= 1
        if state.pointee.tripped { return }

        let sampleSize = MemoryLayout<Float32>.size
        let channels = state.pointee.channelCount
        let outPointers = state.pointee.outPointers
        let outStrides = state.pointee.outStrides

        // 1. 解析各聲道的輸出位置。任何一個聲道對不上就整個略過，維持靜音。
        var outFrames = Int.max
        for channel in 0..<channels {
            let ref = state.pointee.outChannels[channel]
            guard ref.buffer < outList.count else { return }
            let buffer = outList[ref.buffer]
            let stride = Int(buffer.mNumberChannels)
            guard let data = buffer.mData, ref.channel < stride else { return }
            outPointers[channel] = data.assumingMemoryBound(to: Float32.self) + ref.channel
            outStrides[channel] = stride
            outFrames = min(outFrames, Int(buffer.mDataByteSize) / (sampleSize * stride))
        }
        guard outFrames > 0, outFrames != .max else { return }

        // 2. 逐槽位、逐聲道混合。
        var rawPeak: Float32 = 0
        var runaway = false
        let limit = runawayThreshold

        for slot in 0..<state.pointee.slotCount {
            let target = state.pointee.slotGainTarget[slot]
            let start = state.pointee.slotGainCurrent[slot]
            // 不論這個槽位這次有沒有資料，增益都要到位，下次有聲音時才不會從舊的值開始滑。
            defer { state.pointee.slotGainCurrent[slot] = target }
            var slotPeak: Float32 = 0

            for channel in 0..<channels {
                let ref = state.pointee.slotChannels[slot * channels + channel]
                guard ref.buffer < inList.count else { continue }
                let buffer = inList[ref.buffer]
                let stride = Int(buffer.mNumberChannels)
                guard let data = buffer.mData, ref.channel < stride else { continue }
                let frames = min(outFrames, Int(buffer.mDataByteSize) / (sampleSize * stride))
                guard frames > 0 else { continue }

                let source = data.assumingMemoryBound(to: Float32.self) + ref.channel
                let destination = outPointers[channel]
                let destinationStride = outStrides[channel]
                // 每個聲道用同樣的起點與斜率，所以各聲道的音量變化完全同步。
                var gain = start
                let gainStep = (target - start) / Float32(frames)
                for frame in 0..<frames {
                    let value = source[frame * stride]
                    let magnitude = abs(value)
                    // 用「不是 ≤」而不是「>」，這樣 NaN 也會被當成異常。
                    if !(magnitude <= limit) { runaway = true }
                    rawPeak = max(rawPeak, magnitude)
                    gain += gainStep
                    let scaled = value * gain
                    slotPeak = max(slotPeak, abs(scaled))
                    destination[frame * destinationStride] += scaled
                }
            }
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

        // 3. 前級、EQ、Limiter、音量、平衡。
        state.pointee.dsp.process(channels: outPointers, strides: outStrides, frames: outFrames)

        // 4. 頻譜：所有聲道平均。
        if state.pointee.spectrumEnabled {
            let buffer = state.pointee.spectrumBuffer
            let mask = RenderState.spectrumCapacity - 1
            let scale = 1 / Float32(channels)
            var index = state.pointee.spectrumWriteIndex
            for frame in 0..<outFrames {
                var sum: Float32 = 0
                for channel in 0..<channels {
                    sum += outPointers[channel][frame * outStrides[channel]]
                }
                buffer[index & mask] = sum * scale
                index &+= 1
            }
            state.pointee.spectrumWriteIndex = index
        }
    }
}
