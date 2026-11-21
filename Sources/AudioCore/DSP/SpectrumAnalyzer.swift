import Accelerate
import Foundation

/// 把一段音訊轉成頻譜：每個頻率有多大聲（dBFS）。給 EQ 編輯器畫背景的頻譜圖用，在 UI 執行緒上執行。
public final class SpectrumAnalyzer {
    public let size: Int
    private let log2n: vDSP_Length
    private let setup: FFTSetup
    private var window: [Float]
    private var windowed: [Float]
    private var real: [Float]
    private var imaginary: [Float]
    private var magnitudes: [Float]

    /// - Parameter size: FFT 長度，必須是 2 的次方。4096 在 48 kHz 下約 11.7 Hz 一格、涵蓋約 85 ms 的聲音。
    public init(size: Int = 4096) {
        precondition(size > 0 && size & (size - 1) == 0, "FFT 長度必須是 2 的次方")
        self.size = size
        log2n = vDSP_Length(log2(Double(size)))
        setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
        window = [Float](repeating: 0, count: size)
        vDSP_hann_window(&window, vDSP_Length(size), Int32(vDSP_HANN_DENORM)) // 一般的 Hann 窗（峰值 1、平均 0.5）
        windowed = [Float](repeating: 0, count: size)
        real = [Float](repeating: 0, count: size / 2)
        imaginary = [Float](repeating: 0, count: size / 2)
        magnitudes = [Float](repeating: 0, count: size / 2)
    }

    deinit {
        vDSP_destroy_fftsetup(setup)
    }

    /// 計算頻譜。回傳 `size / 2` 個值，第 k 個代表 `k × 取樣率 ÷ size` Hz 附近的音量（dBFS）。
    /// 振幅 1.0 的正弦波在它的頻率上約為 0 dBFS。
    public func analyze(_ samples: [Float]) -> [Float] {
        let count = min(samples.count, size)
        windowed = [Float](repeating: 0, count: size)
        if count > 0 {
            vDSP_vmul(samples, 1, window, 1, &windowed, 1, vDSP_Length(count))
        }

        real.withUnsafeMutableBufferPointer { realPointer in
            imaginary.withUnsafeMutableBufferPointer { imaginaryPointer in
                var split = DSPSplitComplex(realp: realPointer.baseAddress!, imagp: imaginaryPointer.baseAddress!)
                windowed.withUnsafeBufferPointer { input in
                    input.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: size / 2) {
                        vDSP_ctoz($0, 2, &split, 1, vDSP_Length(size / 2))
                    }
                }
                vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                // zrip 把奈奎斯特頻率放在 imagp[0]；這一格用不到，清掉以免算進直流。
                split.imagp[0] = 0
                vDSP_zvmags(&split, 1, &magnitudes, 1, vDSP_Length(size / 2))
            }
        }

        // zrip 的結果是實際 DFT 的 2 倍；Hann 窗的平均增益是 0.5。
        // 振幅 A 的正弦波：|X| = A × N / 4，所以 A = 2 × √mags / N。
        let scale = 2 / Float(size)
        return magnitudes.map { power in
            let amplitude = power.squareRoot() * scale
            return amplitude > 1e-7 ? 20 * log10(amplitude) : -140
        }
    }
}
