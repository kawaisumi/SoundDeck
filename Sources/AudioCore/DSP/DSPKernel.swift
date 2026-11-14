import Foundation
import os

/// 即時執行緒上的訊號處理：前級 → 參數式 EQ → Limiter → 音量。
///
/// 這個 struct 放在手動配置的記憶體裡，內部只有純值與指標，`process` 不配置記憶體、不阻塞。
/// UI 執行緒透過 `update` / `setVolume` 送入新參數：兩邊用一把 `os_unfair_lock` 交接，
/// 即時執行緒只用 trylock，搶不到就沿用舊參數、下個緩衝區再試，所以絕不會被 UI 卡住。
struct DSPKernel {
    static let maxBands = EQSettings.maxBands
    private static let coefficientsPerBand = 5
    private static let stateValuesPerBand = 4 // 左聲道 z1、z2，右聲道 z1、z2

    /// Limiter 的門檻：−1 dBFS。
    static let limiterThreshold: Double = 0.891_250_938
    private static let maxLookahead = 128

    // MARK: 參數交接（由 lock 保護）

    private let lock: UnsafeMutablePointer<os_unfair_lock>
    private let pending: UnsafeMutablePointer<Double>
    private var pendingBandCount = 0
    private var pendingPreamp: Double = 1
    private var pendingVolume: Double = 1
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

    // MARK: Limiter 狀態（只有即時執行緒使用）

    /// 預看長度 K（samples）。訊號延遲 K，增益用 K 個 sample 線性下降到位。
    let lookahead: Int
    private let delayL: UnsafeMutablePointer<Double>
    private let delayR: UnsafeMutablePointer<Double>
    private let required: UnsafeMutablePointer<Double> // 最近 2K 個 sample 各自需要的增益
    private let averaged: UnsafeMutablePointer<Double> // 最近 K 個區間最小值
    private var delayIndex = 0
    private var requiredIndex = 0
    private var averagedIndex = 0
    private var averagedSum: Double
    private var samplesSinceReduction: Int
    private var limiterGain: Double = 1
    private let releaseCoefficient: Double

    init(sampleRate: Double, initialVolume: Double) {
        let coefficientCount = Self.maxBands * Self.coefficientsPerBand

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

        z = .allocate(capacity: Self.maxBands * Self.stateValuesPerBand)
        z.initialize(repeating: 0, count: Self.maxBands * Self.stateValuesPerBand)

        let safeRate = sampleRate > 0 ? sampleRate : 48_000
        // 約 0.67 ms；取樣率越高 sample 數越多，時間長度大致不變。
        lookahead = min(max(Int((safeRate / 1500).rounded()), 16), Self.maxLookahead)
        delayL = .allocate(capacity: Self.maxLookahead)
        delayR = .allocate(capacity: Self.maxLookahead)
        required = .allocate(capacity: Self.maxLookahead * 2)
        averaged = .allocate(capacity: Self.maxLookahead)
        delayL.initialize(repeating: 0, count: Self.maxLookahead)
        delayR.initialize(repeating: 0, count: Self.maxLookahead)
        required.initialize(repeating: 1, count: Self.maxLookahead * 2)
        averaged.initialize(repeating: 1, count: Self.maxLookahead)
        averagedSum = Double(lookahead)
        samplesSinceReduction = lookahead * 2
        releaseCoefficient = 1 - exp(-1 / (0.12 * safeRate)) // 釋放時間常數約 120 ms

        let clampedVolume = initialVolume.clamped(to: 0...1)
        pendingVolume = clampedVolume
        volume = clampedVolume
        volumeTarget = clampedVolume
    }

    /// 釋放所有緩衝區。呼叫前必須確定即時執行緒已經不會再進來。
    func deallocate() {
        lock.deallocate()
        pending.deallocate()
        current.deallocate()
        target.deallocate()
        step.deallocate()
        z.deallocate()
        delayL.deallocate()
        delayR.deallocate()
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

    /// 設定最末端的音量（線性，0…1）。
    static func setVolume(_ kernel: UnsafeMutablePointer<DSPKernel>, _ volume: Double) {
        os_unfair_lock_lock(kernel.pointee.lock)
        kernel.pointee.pendingVolume = volume.clamped(to: 0...1)
        os_unfair_lock_unlock(kernel.pointee.lock)
    }

    // MARK: - 即時執行緒

    /// 就地處理一段立體聲。`left` / `right` 指向各自聲道的第一個 sample，stride 是相鄰 sample 的間隔。
    mutating func process(
        left: UnsafeMutablePointer<Float32>, leftStride: Int,
        right: UnsafeMutablePointer<Float32>, rightStride: Int,
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
            os_unfair_lock_unlock(lock)
        }

        let preampStep = (preampTarget - preamp) / Double(frames)
        let volumeStep = (volumeTarget - volume) / Double(frames)
        let threshold = Self.limiterThreshold
        let k = lookahead
        let windowLength = k * 2
        let inverseK = 1 / Double(k)

        for frame in 0..<frames {
            preamp += preampStep
            var l = Double(left[frame * leftStride]) * preamp
            var r = Double(right[frame * rightStride]) * preamp

            // 2. EQ：串接的 biquad，transposed direct form II。
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
                let s = band * Self.stateValuesPerBand

                let yl = b0 * l + z[s]
                z[s] = b1 * l - a1 * yl + z[s + 1]
                z[s + 1] = b2 * l - a2 * yl
                l = yl

                let yr = b0 * r + z[s + 2]
                z[s + 2] = b1 * r - a1 * yr + z[s + 3]
                z[s + 3] = b2 * r - a2 * yr
                r = yr
            }

            // 3. Limiter（預看式峰值限幅，左右聲道連動）。
            //    每個 sample 算出「不超過門檻所需的增益」，取最近 2K 個的最小值，再對 K 個做移動平均。
            //    訊號延遲 K 個 sample，所以增益會在峰值抵達之前就線性降到位，保證輸出不超過門檻。
            let peak = max(abs(l), abs(r))
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

            let delayedL = delayL[delayIndex], delayedR = delayR[delayIndex]
            delayL[delayIndex] = l
            delayR[delayIndex] = r
            delayIndex += 1
            if delayIndex == k { delayIndex = 0 }

            // 4. 音量，以及理論上不會觸發的最後一道上限。
            volume += volumeStep
            let gain = limiterGain * volume
            left[frame * leftStride] = Float32((delayedL * gain).clamped(to: -1...1))
            right[frame * rightStride] = Float32((delayedR * gain).clamped(to: -1...1))
        }

        preamp = preampTarget
        volume = volumeTarget

        if ramping {
            ramping = false
            memcpy(current, target, Self.maxBands * perBand * MemoryLayout<Double>.size)
            // 被移除的頻段：清掉殘留狀態，下次再啟用時從乾淨的狀態開始。
            if targetBandCount < bandCount {
                for index in (targetBandCount * Self.stateValuesPerBand)..<(bandCount * Self.stateValuesPerBand) {
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
