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

    func testBalanceAttenuatesOnlyTheOppositeSide() {
        let kernel = makeKernel()
        let input = [Float](repeating: 0.4, count: 4096)

        DSPKernel.setBalance(kernel, 0.5) // 偏右：左聲道減半，右聲道不變
        var output = run(kernel, left: input, right: input)
        XCTAssertEqual(output.left.last!, 0.2, accuracy: 1e-5)
        XCTAssertEqual(output.right.last!, 0.4, accuracy: 1e-5)

        DSPKernel.setBalance(kernel, -1) // 全左：右聲道靜音
        output = run(kernel, left: input, right: input)
        XCTAssertEqual(output.left.last!, 0.4, accuracy: 1e-5)
        XCTAssertEqual(output.right.last!, 0, accuracy: 1e-6)
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

final class SpectrumAnalyzerTests: XCTestCase {
    func testFullScaleSineReadsAboutZeroDBAtItsFrequency() {
        let analyzer = SpectrumAnalyzer(size: 4096)
        let sampleRate = 48_000.0
        let frequency = 1500.0 // 剛好落在第 128 格，避免頻譜洩漏影響量測
        let samples = (0..<4096).map { Float(sin(2 * .pi * frequency * Double($0) / sampleRate)) }
        let spectrum = analyzer.analyze(samples)

        let peakBin = spectrum.indices.max { spectrum[$0] < spectrum[$1] }!
        XCTAssertEqual(peakBin, 128)
        XCTAssertEqual(Double(spectrum[peakBin]), 0, accuracy: 0.5)
        // 遠離這個頻率的地方應該很安靜。
        XCTAssertLessThan(spectrum[1000], -80)
    }

    func testHalfAmplitudeIsSixDBLower() {
        let analyzer = SpectrumAnalyzer(size: 4096)
        let samples = (0..<4096).map { Float(0.5 * sin(2 * .pi * 1500 * Double($0) / 48_000)) }
        XCTAssertEqual(Double(analyzer.analyze(samples)[128]), -6.02, accuracy: 0.5)
    }

    func testSilenceIsVeryLow() {
        let spectrum = SpectrumAnalyzer(size: 1024).analyze([Float](repeating: 0, count: 1024))
        XCTAssertTrue(spectrum.allSatisfy { $0 <= -120 })
    }
}

final class EQTextFormatTests: XCTestCase {
    /// AutoEQ 實際輸出的 ParametricEQ.txt 格式。
    private let autoEQ = """
    Preamp: -6.4 dB
    Filter 1: ON LSC Fc 105 Hz Gain 5.6 dB Q 0.70
    Filter 2: ON PK Fc 46 Hz Gain -1.2 dB Q 1.13
    Filter 3: ON PK Fc 1335 Hz Gain -1.7 dB Q 1.37
    Filter 4: ON PK Fc 3291 Hz Gain 2.9 dB Q 2.52
    Filter 5: ON PK Fc 6082 Hz Gain -3.9 dB Q 3.59
    Filter 6: ON PK Fc 9718 Hz Gain 1.9 dB Q 1.88
    Filter 7: ON HSC Fc 10000 Hz Gain -2.6 dB Q 0.70
    """

    func testParsesAutoEQFile() throws {
        let parsed = try EQTextFormat.parse(autoEQ)
        XCTAssertEqual(parsed.preampDB, -6.4)
        XCTAssertNil(parsed.name)
        XCTAssertEqual(parsed.bands.count, 7)
        XCTAssertEqual(parsed.warnings, [])

        let first = parsed.bands[0]
        XCTAssertEqual(first.kind, .lowShelf)
        XCTAssertEqual(first.frequency, 105)
        XCTAssertEqual(first.gainDB, 5.6)
        XCTAssertEqual(first.q, 0.70)
        XCTAssertEqual(parsed.bands[3].kind, .peak)
        XCTAssertEqual(parsed.bands[6].kind, .highShelf)
    }

    func testParsesWholeAIReplyWithSurroundingText() throws {
        let reply = """
        好的！以下是為你設計的參數：

        ```
        # 名稱：女聲搖滾
        Preamp: −3.5 dB
        Filter 1: ON HP Fc 35 Hz Gain 0 dB Q 0.71
        Filter 2: ON PK Fc 90 Hz Gain 3 dB Q 1
        Filter 3: OFF PK Fc 500 Hz Gain 1.5 dB Q 0.9
        ```

        - Filter 1 濾掉喇叭發不出來的超低頻
        """
        let parsed = try EQTextFormat.parse(reply)
        XCTAssertEqual(parsed.name, "女聲搖滾")
        XCTAssertEqual(parsed.preampDB, -3.5)
        XCTAssertEqual(parsed.bands.map(\.kind), [.highPass, .peak, .peak])
        XCTAssertEqual(parsed.bands.map(\.isEnabled), [true, true, false])
        XCTAssertEqual(parsed.bands[1].gainDB, 3)
    }

    func testClampsOutOfRangeValuesAndReportsThem() throws {
        let parsed = try EQTextFormat.parse("Filter 1: ON PK Fc 30000 Hz Gain 24 dB Q 40")
        let band = try XCTUnwrap(parsed.bands.first)
        XCTAssertEqual(band.frequency, 20_000)
        XCTAssertEqual(band.gainDB, 18)
        XCTAssertEqual(band.q, 18)
        XCTAssertEqual(parsed.warnings.count, 3)
    }

    func testSkipsUnsupportedTypesAndLimitsBandCount() throws {
        var text = "Filter 1: ON BP Fc 1000 Hz Gain 0 dB Q 1\n"
        for index in 2...20 {
            text += "Filter \(index): ON PK Fc \(index * 100) Hz Gain 1 dB Q 1\n"
        }
        let parsed = try EQTextFormat.parse(text)
        XCTAssertEqual(parsed.bands.count, EQSettings.maxBands)
        XCTAssertEqual(parsed.warnings.count, 2) // BP 不支援、超過上限
    }

    func testRejectsTextWithoutFilters() {
        XCTAssertThrowsError(try EQTextFormat.parse("Preamp: -3 dB\n這裡沒有濾波器")) { error in
            XCTAssertEqual(error as? EQTextFormat.ParseError, .noFilters)
        }
    }

    func testFormatRoundTrips() throws {
        let settings = EQSettings(bands: [
            EQBand(kind: .highPass, frequency: 40, q: 0.71),
            EQBand(kind: .peak, frequency: 450, gainDB: 2, q: 0.9),
            EQBand(kind: .highShelf, frequency: 9000, gainDB: 2.5, q: 0.71, isEnabled: false),
        ])
        let text = EQTextFormat.format(settings, name: "測試")
        let parsed = try EQTextFormat.parse(text)
        XCTAssertEqual(parsed.name, "測試")
        XCTAssertEqual(parsed.bands.count, 3)
        for (original, roundTripped) in zip(settings.bands, parsed.bands) {
            XCTAssertEqual(original.kind, roundTripped.kind)
            XCTAssertEqual(original.frequency, roundTripped.frequency)
            XCTAssertEqual(original.gainDB, roundTripped.gainDB)
            XCTAssertEqual(original.q, roundTripped.q)
            XCTAssertEqual(original.isEnabled, roundTripped.isEnabled)
        }
    }

    func testAIPromptExampleIsImportable() throws {
        for (language, name) in [(AppLanguage.chinese, "示範設定"), (.english, "Example")] {
            let prompt = EQTextFormat.aiPrompt(deviceName: "Speaker", current: nil, language: language)
            let parsed = try EQTextFormat.parse(prompt)
            XCTAssertEqual(parsed.name, name)
            XCTAssertEqual(parsed.bands.count, 4)
            XCTAssertEqual(parsed.warnings, [])
        }
    }

    func testEnglishExportUsesNameLine() throws {
        let text = EQTextFormat.format(.flat, name: "Mine", language: .english)
        XCTAssertTrue(text.hasPrefix("# Name: Mine"))
        XCTAssertEqual(try EQTextFormat.parse(text).name, "Mine")
    }
}
