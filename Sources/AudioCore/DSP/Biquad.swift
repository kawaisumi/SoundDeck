import Foundation

/// 二階 IIR 濾波器的係數（a0 已正規化為 1）。
///
///     y[n] = b0·x[n] + b1·x[n-1] + b2·x[n-2] − a1·y[n-1] − a2·y[n-2]
///
/// 公式來自 Robert Bristow-Johnson 的 Audio EQ Cookbook。
public struct Biquad: Equatable, Sendable {
    public var b0, b1, b2, a1, a2: Double

    /// 不改變訊號的濾波器。
    public static let identity = Biquad(b0: 1, b1: 0, b2: 0, a1: 0, a2: 0)

    public init(b0: Double, b1: Double, b2: Double, a1: Double, a2: Double) {
        self.b0 = b0
        self.b1 = b1
        self.b2 = b2
        self.a1 = a1
        self.a2 = a2
    }

    public init(band: EQBand, sampleRate: Double) {
        let band = band.clamped
        // 中心頻率不能超過 Nyquist，否則係數會失去意義。
        let frequency = min(band.frequency, sampleRate * 0.49)
        let omega = 2 * Double.pi * frequency / sampleRate
        let cosW = cos(omega)
        let alpha = sin(omega) / (2 * band.q)
        let a = pow(10, band.gainDB / 40)

        let b0, b1, b2, a0, a1, a2: Double
        switch band.kind {
        case .peak:
            b0 = 1 + alpha * a
            b1 = -2 * cosW
            b2 = 1 - alpha * a
            a0 = 1 + alpha / a
            a1 = -2 * cosW
            a2 = 1 - alpha / a

        case .lowShelf:
            let k = 2 * sqrt(a) * alpha
            b0 = a * ((a + 1) - (a - 1) * cosW + k)
            b1 = 2 * a * ((a - 1) - (a + 1) * cosW)
            b2 = a * ((a + 1) - (a - 1) * cosW - k)
            a0 = (a + 1) + (a - 1) * cosW + k
            a1 = -2 * ((a - 1) + (a + 1) * cosW)
            a2 = (a + 1) + (a - 1) * cosW - k

        case .highShelf:
            let k = 2 * sqrt(a) * alpha
            b0 = a * ((a + 1) + (a - 1) * cosW + k)
            b1 = -2 * a * ((a - 1) + (a + 1) * cosW)
            b2 = a * ((a + 1) + (a - 1) * cosW - k)
            a0 = (a + 1) - (a - 1) * cosW + k
            a1 = 2 * ((a - 1) - (a + 1) * cosW)
            a2 = (a + 1) - (a - 1) * cosW - k

        case .lowPass:
            b0 = (1 - cosW) / 2
            b1 = 1 - cosW
            b2 = (1 - cosW) / 2
            a0 = 1 + alpha
            a1 = -2 * cosW
            a2 = 1 - alpha

        case .highPass:
            b0 = (1 + cosW) / 2
            b1 = -(1 + cosW)
            b2 = (1 + cosW) / 2
            a0 = 1 + alpha
            a1 = -2 * cosW
            a2 = 1 - alpha

        case .notch:
            b0 = 1
            b1 = -2 * cosW
            b2 = 1
            a0 = 1 + alpha
            a1 = -2 * cosW
            a2 = 1 - alpha
        }

        self.init(b0: b0 / a0, b1: b1 / a0, b2: b2 / a0, a1: a1 / a0, a2: a2 / a0)
    }

    /// 這個濾波器在指定頻率的增益（dB）。
    public func magnitudeDB(at frequency: Double, sampleRate: Double) -> Double {
        let omega = 2 * Double.pi * frequency / sampleRate
        let cos1 = cos(omega), sin1 = sin(omega)
        let cos2 = cos(2 * omega), sin2 = sin(2 * omega)

        let numRe = b0 + b1 * cos1 + b2 * cos2
        let numIm = b1 * sin1 + b2 * sin2
        let denRe = 1 + a1 * cos1 + a2 * cos2
        let denIm = a1 * sin1 + a2 * sin2

        let numerator = numRe * numRe + numIm * numIm
        let denominator = denRe * denRe + denIm * denIm
        guard denominator > 0, numerator > 0 else { return -120 }
        return max(10 * log10(numerator / denominator), -120)
    }
}
