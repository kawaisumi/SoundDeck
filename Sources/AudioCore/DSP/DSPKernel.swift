import Foundation
import os

/// 即時執行緒上的訊號處理：前級 → 參數式 EQ → Limiter → 音量與左右平衡。
///
/// 支援 1 到 `maxChannels` 個聲道（立體聲、5.1、7.1…）。每個聲道各自通過同一組 EQ；
/// Limiter 同時看所有聲道、對所有聲道套用同一個增益，空間感才不會因為某個聲道被壓而偏移；
/// 平衡依每個聲道在左側、右側或中間（`ChannelSide`）決定要不要衰減。
///
/// 這個 struct 放在手動配置的記憶體裡，內部只有純值與指標，`process` 不配置記憶體、不阻塞。
/// UI 執行緒透過 `update` / `setVolume` 送入新參數：兩邊用一把 `os_unfair_lock` 交接，
/// 即時執行緒只用 trylock，搶不到就沿用舊參數、下個緩衝區再試，所以絕不會被 UI 卡住。
struct DSPKernel {
    static let maxBands = EQSettings.maxBands
    static let maxChannels = 16
    private static let coefficientsPerBand = 5
    private static let stateValuesPerChannel = 2 // 每個頻段、每個聲道各有 z1、z2

    /// 實際處理的聲道數，建立後不變。
    let channelCount: Int
    /// 每個聲道在左側（−1）、右側（1）或中間（0）。
    private let sides: UnsafeMutablePointer<Int8>
    /// 一個 frame 裡各聲道的值，處理時暫存用。
    private let frameValues: UnsafeMutablePointer<Double>

    /// Limiter 的門檻：−1 dBFS。
    static let limiterThreshold: Double = 0.891_250_938
    private static let maxLookahead = 128

    // MARK: 參數交接（由 lock 保護）

    private let lock: UnsafeMutablePointer<os_unfair_lock>
    private let pending: UnsafeMutablePointer<Double>
    private var pendingBandCount = 0
    private var pendingPreamp: Double = 1
    private var pendingVolume: Double = 1
    private var pendingBalance: Double = 0
    private var dirty = false

    // MARK: EQ 狀態（只有即時執行緒使用）

    private let current: UnsafeMutablePointer<Double>
    private let target: UnsafeMutablePointer<Double>
    private let step: UnsafeMutablePointer<Double>
    private let z: UnsafeMutablePointer<Double>
    /// 目前需要運算的頻段數。超過這個數的頻段，係數保證是 identity。
    private var bandCount = 0
    private var targetBandCount = 0
    private var ramping = false

    private var preamp: Double = 1
    private var preampTarget: Double = 1
    private var volume: Double = 1
    private var volumeTarget: Double = 1
    /// −1（全左）…0（置中）…1（全右）。
    private var balance: Double = 0
    private var balanceTarget: Double = 0

    // MARK: Limiter 狀態（只有即時執行緒使用）

    /// 預看長度 K（samples）。訊號延遲 K，增益用 K 個 sample 線性下降到位。
    let lookahead: Int
    /// 每個聲道一條延遲線，長度 maxLookahead：第 c 個聲道從 `delay[c × maxLookahead]` 開始。
    private let delay: UnsafeMutablePointer<Double>
    private let required: UnsafeMutablePointer<Double> // 最近 2K 個 sample 各自需要的增益
    private let averaged: UnsafeMutablePointer<Double> // 最近 K 個區間最小值
    private var delayIndex = 0
    private var requiredIndex = 0
    private var averagedIndex = 0
    private var averagedSum: Double
    private var samplesSinceReduction: Int
    private var limiterGain: Double = 1
    private let releaseCoefficient: Double

    /// - Parameters:
    ///   - channelCount: 聲道數，1…`maxChannels`。
    ///   - channelSides: 每個聲道的位置；省略時，2 聲道視為左、右，其他視為中間（平衡不作用）。
    init(
        sampleRate: Double, channelCount: Int = 2, channelSides: [ChannelSide]? = nil,
        initialVolume: Double, initialBalance: Double = 0
    ) {
        let coefficientCount = Self.maxBands * Self.coefficientsPerBand
        let channels = min(max(channelCount, 1), Self.maxChannels)
        self.channelCount = channels

        sides = .allocate(capacity: Self.maxChannels)
        sides.initialize(repeating: 0, count: Self.maxChannels)
        let resolvedSides = channelSides ?? (channels == 2 ? [.left, .right] : [])
        for (index, side) in resolvedSides.prefix(channels).enumerated() {
            sides[index] = side.rawValue
        }
        frameValues = .allocate(capacity: Self.maxChannels)
        frameValues.initialize(repeating: 0, count: Self.maxChannels)

        lock = .allocate(capacity: 1)
        lock.initialize(to: os_unfair_lock())

        pending = .allocate(capacity: coefficientCount)
        current = .allocate(capacity: coefficientCount)
        target = .allocate(capacity: coefficientCount)
        step = .allocate(capacity: coefficientCount)
        for band in 0..<Self.maxBands {
            for buffer in [pending, current, target] {
                Self.write(.identity, to: buffer, band: band)
            }
        }
        step.initialize(repeating: 0, count: coefficientCount)

        let stateCount = Self.maxBands * Self.maxChannels * Self.stateValuesPerChannel
        z = .allocate(capacity: stateCount)
        z.initialize(repeating: 0, count: stateCount)

        let safeRate = sampleRate > 0 ? sampleRate : 48_000
        // 約 0.67 ms；取樣率越高 sample 數越多，時間長度大致不變。
        lookahead = min(max(Int((safeRate / 1500).rounded()), 16), Self.maxLookahead)
        delay = .allocate(capacity: Self.maxLookahead * Self.maxChannels)
        required = .allocate(capacity: Self.maxLookahead * 2)
        averaged = .allocate(capacity: Self.maxLookahead)
        delay.initialize(repeating: 0, count: Self.maxLookahead * Self.maxChannels)
        required.initialize(repeating: 1, count: Self.maxLookahead * 2)
        averaged.initialize(repeating: 1, count: Self.maxLookahead)
        averagedSum = Double(lookahead)
        samplesSinceReduction = lookahead * 2
        releaseCoefficient = 1 - exp(-1 / (0.12 * safeRate)) // 釋放時間常數約 120 ms

        let clampedVolume = initialVolume.clamped(to: 0...1)
        pendingVolume = clampedVolume
        volume = clampedVolume
        volumeTarget = clampedVolume

        let clampedBalance = initialBalance.clamped(to: -1...1)
        pendingBalance = clampedBalance
        balance = clampedBalance
        balanceTarget = clampedBalance
    }

    /// 釋放所有緩衝區。呼叫前必須確定即時執行緒已經不會再進來。
    func deallocate() {
        lock.deallocate()
        pending.deallocate()
        current.deallocate()
        target.deallocate()
        step.deallocate()
        z.deallocate()
        sides.deallocate()
        frameValues.deallocate()
        delay.deallocate()
        required.deallocate()
        averaged.deallocate()
    }

    private static func write(_ biquad: Biquad, to buffer: UnsafeMutablePointer<Double>, band: Int) {
        let base = band * coefficientsPerBand
        buffer[base] = biquad.b0
        buffer[base + 1] = biquad.b1
        buffer[base + 2] = biquad.b2
        buffer[base + 3] = biquad.a1
        buffer[base + 4] = biquad.a2
    }

    // MARK: - UI 執行緒

    /// 送入新的 EQ 係數與前級增益（線性）。即時執行緒會在一個緩衝區內平滑過渡過去。
    static func update(_ kernel: UnsafeMutablePointer<DSPKernel>, filters: [Biquad], preamp: Double) {
        let count = min(filters.count, maxBands)
        os_unfair_lock_lock(kernel.pointee.lock)
        for band in 0..<maxBands {
            write(band < count ? filters[band] : .identity, to: kernel.pointee.pending, band: band)
        }
        kernel.pointee.pendingBandCount = count
        kernel.pointee.pendingPreamp = preamp
        kernel.pointee.dirty = true
        os_unfair_lock_unlock(kernel.pointee.lock)
    }

    /// 設定左右平衡：−1 只剩左聲道、0 置中、1 只剩右聲道。偏向一邊時只降低另一邊，偏向的那邊維持原音量。
    static func setBalance(_ kernel: UnsafeMutablePointer<DSPKernel>, _ balance: Double) {
        os_unfair_lock_lock(kernel.pointee.lock)
        kernel.pointee.pendingBalance = balance.clamped(to: -1...1)
        os_unfair_lock_unlock(kernel.pointee.lock)
    }

    /// 設定最末端的音量（線性，0…1）。
    static func setVolume(_ kernel: UnsafeMutablePointer<DSPKernel>, _ volume: Double) {
        os_unfair_lock_lock(kernel.pointee.lock)
        kernel.pointee.pendingVolume = volume.clamped(to: 0...1)
        os_unfair_lock_unlock(kernel.pointee.lock)
    }

    // MARK: - 即時執行緒

    /// 就地處理一段立體聲。給只有兩個聲道的呼叫端（與測試）使用。
    mutating func process(
        left: UnsafeMutablePointer<Float32>, leftStride: Int,
        right: UnsafeMutablePointer<Float32>, rightStride: Int,
        frames: Int
    ) {
        var pointers = (left, right)
        var strides = (leftStride, rightStride)
        withUnsafeMutableBytes(of: &pointers) { pointerBytes in
            withUnsafeMutableBytes(of: &strides) { strideBytes in
                process(
                    channels: pointerBytes.baseAddress!.assumingMemoryBound(to: UnsafeMutablePointer<Float32>.self),
                    strides: strideBytes.baseAddress!.assumingMemoryBound(to: Int.self),
                    frames: frames
                )
            }
        }
    }

    /// 就地處理 `channelCount` 個聲道。`channels[c]` 指向第 c 個聲道的第一個 sample，
    /// `strides[c]` 是同一聲道相鄰兩個 sample 的間隔（交錯格式時等於該緩衝區的聲道數）。
    mutating func process(
        channels: UnsafePointer<UnsafeMutablePointer<Float32>>,
        strides: UnsafePointer<Int>,
        frames: Int
    ) {
        guard frames > 0 else { return }
        let perBand = Self.coefficientsPerBand

        // 1. 接收新參數。搶不到鎖就下次再說。
        if os_unfair_lock_trylock(lock) {
            if dirty {
                dirty = false
                memcpy(target, pending, Self.maxBands * perBand * MemoryLayout<Double>.size)
                targetBandCount = pendingBandCount
                preampTarget = pendingPreamp
                // 過渡期間新舊頻段都要算；多出來的那一邊係數是 identity，所以結果正確。
                bandCount = max(bandCount, targetBandCount)
                let scale = 1 / Double(frames)
                for index in 0..<(bandCount * perBand) {
                    step[index] = (target[index] - current[index]) * scale
                }
                ramping = true
            }
            volumeTarget = pendingVolume
            balanceTarget = pendingBalance
            os_unfair_lock_unlock(lock)
        }

        let preampStep = (preampTarget - preamp) / Double(frames)
        let volumeStep = (volumeTarget - volume) / Double(frames)
        let balanceStep = (balanceTarget - balance) / Double(frames)
        let threshold = Self.limiterThreshold
        let k = lookahead
        let windowLength = k * 2
        let inverseK = 1 / Double(k)

        let channelCount = self.channelCount
        let channelStride = Self.maxChannels * Self.stateValuesPerChannel
        let delayLength = Self.maxLookahead

        for frame in 0..<frames {
            preamp += preampStep
            for channel in 0..<channelCount {
                frameValues[channel] = Double(channels[channel][frame * strides[channel]]) * preamp
            }

            // 2. EQ：串接的 biquad，transposed direct form II。每個聲道用同一組係數、各自的狀態。
            for band in 0..<bandCount {
                let c = band * perBand
                if ramping {
                    current[c] += step[c]
                    current[c + 1] += step[c + 1]
                    current[c + 2] += step[c + 2]
                    current[c + 3] += step[c + 3]
                    current[c + 4] += step[c + 4]
                }
                let b0 = current[c], b1 = current[c + 1], b2 = current[c + 2]
                let a1 = current[c + 3], a2 = current[c + 4]
                let bandBase = band * channelStride

                for channel in 0..<channelCount {
                    let s = bandBase + channel * Self.stateValuesPerChannel
                    let x = frameValues[channel]
                    let y = b0 * x + z[s]
                    z[s] = b1 * x - a1 * y + z[s + 1]
                    z[s + 1] = b2 * x - a2 * y
                    frameValues[channel] = y
                }
            }

            // 3. Limiter（預看式峰值限幅，所有聲道連動）。
            //    每個 sample 算出「不超過門檻所需的增益」，取最近 2K 個的最小值，再對 K 個做移動平均。
            //    訊號延遲 K 個 sample，所以增益會在峰值抵達之前就線性降到位，保證輸出不超過門檻。
            var peak: Double = 0
            for channel in 0..<channelCount {
                peak = max(peak, abs(frameValues[channel]))
            }
            let need = peak > threshold ? threshold / peak : 1
            required[requiredIndex] = need
            requiredIndex += 1
            if requiredIndex == windowLength { requiredIndex = 0 }

            var windowMin: Double = 1
            if need < 1 {
                samplesSinceReduction = 0
            } else if samplesSinceReduction < windowLength + k {
                samplesSinceReduction += 1
            }
            if samplesSinceReduction < windowLength {
                // 視窗內有需要壓低的 sample 才掃描；平常這段完全跳過。
                for index in 0..<windowLength {
                    windowMin = min(windowMin, required[index])
                }
            }

            averagedSum += windowMin - averaged[averagedIndex]
            averaged[averagedIndex] = windowMin
            averagedIndex += 1
            if averagedIndex == k { averagedIndex = 0 }

            let attack = min(averagedSum * inverseK, 1)
            limiterGain = min(attack, limiterGain + (1 - limiterGain) * releaseCoefficient)

            // 4. 音量與平衡，以及理論上不會觸發的最後一道上限。
            volume += volumeStep
            balance += balanceStep
            let gain = limiterGain * volume
            let leftSideGain = gain * min(1, 1 - balance)
            let rightSideGain = gain * min(1, 1 + balance)

            for channel in 0..<channelCount {
                let slot = channel * delayLength + delayIndex
                let delayed = delay[slot]
                delay[slot] = frameValues[channel]
                let channelGain: Double
                switch sides[channel] {
                case -1: channelGain = leftSideGain
                case 1: channelGain = rightSideGain
                default: channelGain = gain
                }
                channels[channel][frame * strides[channel]] = Float32((delayed * channelGain).clamped(to: -1...1))
            }
            delayIndex += 1
            if delayIndex == k { delayIndex = 0 }
        }

        preamp = preampTarget
        volume = volumeTarget
        balance = balanceTarget

        if ramping {
            ramping = false
            memcpy(current, target, Self.maxBands * perBand * MemoryLayout<Double>.size)
            // 被移除的頻段：清掉殘留狀態，下次再啟用時從乾淨的狀態開始。
            if targetBandCount < bandCount {
                let channelStride = Self.maxChannels * Self.stateValuesPerChannel
                for index in (targetBandCount * channelStride)..<(bandCount * channelStride) {
                    z[index] = 0
                }
            }
            bandCount = targetBandCount
        }

        // 移動平均是用累加的方式維護；沒有在壓限時（此時視窗內全是 1）把它校正回精確值，避免誤差累積。
        if samplesSinceReduction >= windowLength + k {
            averagedSum = Double(k)
        }
    }
}

/// 聲道在聆聽者的哪一側，決定平衡要不要衰減它。
enum ChannelSide: Int8, Sendable {
    case left = -1
    case center = 0 // 中置、重低音、正上方等：平衡不影響
    case right = 1
}
