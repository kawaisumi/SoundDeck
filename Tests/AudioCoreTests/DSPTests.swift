@testable import AudioCore
import XCTest

final class BiquadTests: XCTestCase {
    private let sampleRate = 48_000.0

    func testIdentityIsFlat() {
        for frequency in [20.0, 1000, 15_000] {
            XCTAssertEqual(Biquad.identity.magnitudeDB(at: frequency, sampleRate: sampleRate), 0, accuracy: 1e-9)
        }
    }

    func testPeakGainAtCenterAndFarAway() {
        let band = EQBand(kind: .peak, frequency: 1000, gainDB: 6, q: 1.4)
        let filter = Biquad(band: band, sampleRate: sampleRate)
        XCTAssertEqual(filter.magnitudeDB(at: 1000, sampleRate: sampleRate), 6, accuracy: 0.01)
        XCTAssertEqual(filter.magnitudeDB(at: 30, sampleRate: sampleRate), 0, accuracy: 0.1)
        XCTAssertEqual(filter.magnitudeDB(at: 18_000, sampleRate: sampleRate), 0, accuracy: 0.1)
    }

    func testShelvesReachTheirGain() {
        let low = Biquad(band: EQBand(kind: .lowShelf, frequency: 200, gainDB: -8, q: 0.71), sampleRate: sampleRate)
        XCTAssertEqual(low.magnitudeDB(at: 20, sampleRate: sampleRate), -8, accuracy: 0.2)
        XCTAssertEqual(low.magnitudeDB(at: 10_000, sampleRate: sampleRate), 0, accuracy: 0.1)

        let high = Biquad(band: EQBand(kind: .highShelf, frequency: 4000, gainDB: 5, q: 0.71), sampleRate: sampleRate)
        XCTAssertEqual(high.magnitudeDB(at: 20_000, sampleRate: sampleRate), 5, accuracy: 0.2)
        XCTAssertEqual(high.magnitudeDB(at: 50, sampleRate: sampleRate), 0, accuracy: 0.1)
    }

    func testPassFiltersAreMinus3dBAtCutoffWithButterworthQ() {
        let q = 1 / 2.0.squareRoot()
        let highPass = Biquad(band: EQBand(kind: .highPass, frequency: 100, q: q), sampleRate: sampleRate)
        XCTAssertEqual(highPass.magnitudeDB(at: 100, sampleRate: sampleRate), -3.01, accuracy: 0.05)
        XCTAssertLessThan(highPass.magnitudeDB(at: 25, sampleRate: sampleRate), -20)

        let lowPass = Biquad(band: EQBand(kind: .lowPass, frequency: 5000, q: q), sampleRate: sampleRate)
        XCTAssertEqual(lowPass.magnitudeDB(at: 5000, sampleRate: sampleRate), -3.01, accuracy: 0.05)
    }

    func testDisabledBandsAndAutoPreamp() {
        var settings = EQSettings(bands: [
            EQBand(kind: .peak, frequency: 1000, gainDB: 9, q: 1),
            EQBand(kind: .peak, frequency: 100, gainDB: 12, q: 1, isEnabled: false),
        ])
        XCTAssertEqual(settings.responseDB(at: 100, sampleRate: sampleRate), 0, accuracy: 0.3)
        XCTAssertEqual(settings.effectivePreampDB(sampleRate: sampleRate), -9, accuracy: 0.05)

        settings.bands[0].gainDB = -9 // 只有衰減時不需要補償
        XCTAssertEqual(settings.effectivePreampDB(sampleRate: sampleRate), 0, accuracy: 1e-9)

        settings.autoPreamp = false
        settings.preampDB = -4
        XCTAssertEqual(settings.effectivePreampDB(sampleRate: sampleRate), -4, accuracy: 1e-9)
    }
}

final class DSPKernelTests: XCTestCase {
    private let sampleRate = 48_000.0

    /// 把一段立體聲分成每 256 frames 一塊送進 kernel，回傳處理後的結果。
    private func run(
        _ kernel: UnsafeMutablePointer<DSPKernel>, left: [Float], right: [Float]
    ) -> (left: [Float], right: [Float]) {
        var left = left, right = right
        let blockSize = 256
        left.withUnsafeMutableBufferPointer { l in
            right.withUnsafeMutableBufferPointer { r in
                var offset = 0
                while offset < l.count {
                    let frames = min(blockSize, l.count - offset)
                    kernel.pointee.process(
                        left: l.baseAddress! + offset, leftStride: 1,
                        right: r.baseAddress! + offset, rightStride: 1,
                        frames: frames
                    )
                    offset += frames
                }
            }
        }
        return (left, right)
    }

    private func makeKernel(volume: Double = 1) -> UnsafeMutablePointer<DSPKernel> {
        let kernel = UnsafeMutablePointer<DSPKernel>.allocate(capacity: 1)
        kernel.initialize(to: DSPKernel(sampleRate: sampleRate, initialVolume: volume))
        addTeardownBlock {
            kernel.pointee.deallocate()
            kernel.deallocate()
        }
        return kernel
    }

    private func sine(_ frequency: Double, amplitude: Double, count: Int) -> [Float] {
        (0..<count).map { Float(amplitude * sin(2 * .pi * frequency * Double($0) / sampleRate)) }
    }

    func testFlatSettingsOnlyDelayTheSignal() {
        let kernel = makeKernel()
        let input = sine(440, amplitude: 0.5, count: 4096)
        let output = run(kernel, left: input, right: input)
        let delay = kernel.pointee.lookahead

        for index in delay..<input.count {
            XCTAssertEqual(output.left[index], input[index - delay], accuracy: 1e-6)
            XCTAssertEqual(output.right[index], input[index - delay], accuracy: 1e-6)
        }
    }

    func testLimiterNeverExceedsThreshold() {
        let kernel = makeKernel()
        // 安靜 → 突然出現遠超過 0 dBFS 的訊號 → 回到安靜，重複幾次。
        var input: [Float] = []
        for _ in 0..<3 {
            input += sine(1000, amplitude: 0.2, count: 3000)
            input += sine(90, amplitude: 4, count: 3000)
            input += [Float](repeating: 3.5, count: 500)
        }
        let output = run(kernel, left: input, right: input.map { -$0 * 0.5 })

        let peak = max(output.left.map(abs).max()!, output.right.map(abs).max()!)
        XCTAssertLessThanOrEqual(Double(peak), DSPKernel.limiterThreshold + 1e-6)
        // 而且確實有在用到接近門檻的音量，不是整段被壓得很小聲。
        XCTAssertGreaterThan(Double(peak), DSPKernel.limiterThreshold * 0.95)
    }

    func testLimiterRecoversAfterLoudPassage() {
        let kernel = makeKernel()
        let loud = sine(200, amplitude: 4, count: 4800)
        let quiet = sine(200, amplitude: 0.3, count: 48_000)
        let output = run(kernel, left: loud + quiet, right: loud + quiet)

        // 釋放時間常數約 120 ms，一秒後應該已經回到原本的音量。
        let tail = output.left.suffix(4800).map(abs).max()!
        XCTAssertEqual(tail, 0.3, accuracy: 0.005)
    }

    func testPeakBandBoostsSineAtItsFrequency() {
        let kernel = makeKernel()
        let band = EQBand(kind: .peak, frequency: 1000, gainDB: 6, q: 1)
        DSPKernel.update(kernel, filters: [Biquad(band: band, sampleRate: sampleRate)], preamp: 1)

        let input = sine(1000, amplitude: 0.1, count: 9600)
        let output = run(kernel, left: input, right: input)
        let steadyState = output.left.suffix(2400).map(abs).max()!
        XCTAssertEqual(Double(steadyState), 0.1 * pow(10, 6.0 / 20), accuracy: 0.002)
    }

    func testPreampAndVolumeScaleTheSignal() {
        let kernel = makeKernel(volume: 0.5)
        DSPKernel.update(kernel, filters: [], preamp: 0.5)
        let input = [Float](repeating: 0.4, count: 4096)
        let output = run(kernel, left: input, right: input)
        XCTAssertEqual(output.left.last!, 0.4 * 0.5 * 0.5, accuracy: 1e-5)

        DSPKernel.setVolume(kernel, 1)
        let louder = run(kernel, left: input, right: input)
        XCTAssertEqual(louder.left.last!, 0.4 * 0.5, accuracy: 1e-5)
    }

    func testRemovingBandsReturnsToFlat() {
        let kernel = makeKernel()
        let band = EQBand(kind: .lowShelf, frequency: 300, gainDB: 12, q: 0.71)
        DSPKernel.update(kernel, filters: [Biquad(band: band, sampleRate: sampleRate)], preamp: 1)
        let input = sine(100, amplitude: 0.1, count: 9600)
        _ = run(kernel, left: input, right: input)

        DSPKernel.update(kernel, filters: [], preamp: 1)
        let output = run(kernel, left: input, right: input)
        XCTAssertEqual(output.left.suffix(2400).map(abs).max()!, 0.1, accuracy: 0.001)
    }

    func testInterleavedStride() {
        let kernel = makeKernel(volume: 0.5)
        // 一個交錯的立體聲緩衝區：L R L R …
        var interleaved = [Float](repeating: 0, count: 2048)
        for frame in 0..<1024 {
            interleaved[frame * 2] = 0.2
            interleaved[frame * 2 + 1] = -0.6
        }
        interleaved.withUnsafeMutableBufferPointer { buffer in
            kernel.pointee.process(
                left: buffer.baseAddress!, leftStride: 2,
                right: buffer.baseAddress! + 1, rightStride: 2,
                frames: 1024
            )
        }
        XCTAssertEqual(interleaved[2046], 0.1, accuracy: 1e-5)
        XCTAssertEqual(interleaved[2047], -0.3, accuracy: 1e-5)
    }
}

final class ProcessAttributionTests: XCTestCase {
    func testHelperInsideAppResolvesToOutermostApp() {
        let helper = URL(fileURLWithPath: "/Applications/Discord.app/Contents/Frameworks/Discord Helper (Renderer).app")
        XCTAssertEqual(
            AudioProcessMonitor.outermostEnclosingApp(of: helper)?.path, "/Applications/Discord.app"
        )
    }

    func testTopLevelAppIsNotAHelper() {
        XCTAssertNil(AudioProcessMonitor.outermostEnclosingApp(of: URL(fileURLWithPath: "/Applications/Discord.app")))
        XCTAssertNil(AudioProcessMonitor.outermostEnclosingApp(of: URL(fileURLWithPath: "/Applications/Utilities/Terminal.app")))
    }
}
