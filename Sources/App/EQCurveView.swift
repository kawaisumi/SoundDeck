import AppKit
import AudioCore
import SwiftUI

/// 頻率響應曲線與可拖曳的頻段控制點。
struct EQCurveView: View {
    @EnvironmentObject private var equalizer: EqualizerController
    let sampleRate: Double
    @Binding var selectedBand: EQBand.ID?

    /// 拖曳開始時該頻段的數值。拖曳量是相對於起點計算，這樣 Shift 微調才不會跳動。
    @State private var dragOrigin: (id: EQBand.ID, frequency: Double, gainDB: Double)?

    private static let displayGain: ClosedRange<Double> = -20...20
    private static let frequencyMarks: [Double] = [20, 50, 100, 200, 500, 1000, 2000, 5000, 10_000, 20_000]
    private static let gainMarks: [Double] = [-18, -12, -6, 0, 6, 12, 18]
    private static let fineTuneFactor = 0.2

    var body: some View {
        GeometryReader { geometry in
            let layout = Layout(size: geometry.size)
            ZStack(alignment: .topLeading) {
                Canvas { context, _ in
                    drawGrid(in: &context, layout: layout)
                    drawCurve(in: &context, layout: layout)
                }

                ForEach(Array(equalizer.settings.bands.enumerated()), id: \.element.id) { index, band in
                    handle(for: band, index: index, layout: layout)
                }
            }
        }
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary))
        .accessibilityLabel("頻率響應曲線")
    }

    // MARK: - 座標換算

    private struct Layout {
        let size: CGSize
        let left: CGFloat = 34
        let right: CGFloat = 10
        let top: CGFloat = 10
        let bottom: CGFloat = 20

        var plot: CGRect {
            CGRect(x: left, y: top, width: max(size.width - left - right, 1), height: max(size.height - top - bottom, 1))
        }

        func x(for frequency: Double) -> CGFloat {
            let fraction = log10(frequency / 20) / 3 // 20 Hz–20 kHz 正好三個十倍頻
            return plot.minX + plot.width * fraction
        }

        func frequency(for x: CGFloat) -> Double {
            20 * pow(10, 3 * Double((x - plot.minX) / plot.width))
        }

        func y(for gainDB: Double) -> CGFloat {
            let range = EQCurveView.displayGain
            let fraction = (range.upperBound - gainDB) / (range.upperBound - range.lowerBound)
            return plot.minY + plot.height * fraction
        }

        var pointsPerDecibel: CGFloat {
            plot.height / (EQCurveView.displayGain.upperBound - EQCurveView.displayGain.lowerBound)
        }
    }

    // MARK: - 繪製

    private func drawGrid(in context: inout GraphicsContext, layout: Layout) {
        let plot = layout.plot
        let gridColor = Color.primary.opacity(0.1)

        for frequency in Self.frequencyMarks {
            let x = layout.x(for: frequency)
            var line = Path()
            line.move(to: CGPoint(x: x, y: plot.minY))
            line.addLine(to: CGPoint(x: x, y: plot.maxY))
            context.stroke(line, with: .color(gridColor), lineWidth: 1)

            let label = frequency >= 1000 ? "\(Int(frequency / 1000))k" : "\(Int(frequency))"
            context.draw(
                Text(label).font(.system(size: 9)).foregroundStyle(.secondary),
                at: CGPoint(x: x, y: plot.maxY + 10)
            )
        }

        for gain in Self.gainMarks {
            let y = layout.y(for: gain)
            var line = Path()
            line.move(to: CGPoint(x: plot.minX, y: y))
            line.addLine(to: CGPoint(x: plot.maxX, y: y))
            context.stroke(line, with: .color(gain == 0 ? Color.primary.opacity(0.3) : gridColor), lineWidth: 1)

            context.draw(
                Text(gain > 0 ? "+\(Int(gain))" : "\(Int(gain))").font(.system(size: 9)).foregroundStyle(.secondary),
                at: CGPoint(x: plot.minX - 16, y: y)
            )
        }
    }

    private func drawCurve(in context: inout GraphicsContext, layout: Layout) {
        let plot = layout.plot
        let settings = equalizer.settings
        // 每 2 pt 取一點，直接由 biquad 係數算出合計響應，畫面上看到的就是實際套用的結果。
        let filters = settings.bands.filter(\.isEnabled).map { Biquad(band: $0, sampleRate: sampleRate) }
        let stepCount = max(Int(plot.width / 2), 2)

        var curve = Path()
        for step in 0...stepCount {
            let x = plot.minX + plot.width * CGFloat(step) / CGFloat(stepCount)
            let frequency = layout.frequency(for: x)
            let gain = filters.reduce(0) { $0 + $1.magnitudeDB(at: frequency, sampleRate: sampleRate) }
            let y = layout.y(for: gain.clamped(to: Self.displayGain))
            if step == 0 {
                curve.move(to: CGPoint(x: x, y: y))
            } else {
                curve.addLine(to: CGPoint(x: x, y: y))
            }
        }

        var fill = curve
        let zeroY = layout.y(for: 0)
        fill.addLine(to: CGPoint(x: plot.maxX, y: zeroY))
        fill.addLine(to: CGPoint(x: plot.minX, y: zeroY))
        fill.closeSubpath()

        context.fill(fill, with: .color(Color.accentColor.opacity(0.15)))
        context.stroke(curve, with: .color(.accentColor), style: StrokeStyle(lineWidth: 2, lineJoin: .round))
    }

    // MARK: - 控制點

    private func handle(for band: EQBand, index: Int, layout: Layout) -> some View {
        let isSelected = band.id == selectedBand
        let color = EQPalette.color(for: index)
        // 沒有增益參數的類型（高通、低通、陷波）固定畫在 0 dB 線上，只能左右拖。
        let position = CGPoint(
            x: layout.x(for: band.frequency),
            y: layout.y(for: band.kind.hasGain ? band.gainDB : 0)
        )

        return Circle()
            .fill(band.isEnabled ? color : Color.gray)
            .overlay(Circle().strokeBorder(.white, lineWidth: isSelected ? 2.5 : 1.5))
            .overlay(
                Text("\(index + 1)")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white)
            )
            .frame(width: isSelected ? 20 : 17, height: isSelected ? 20 : 17)
            .shadow(color: .black.opacity(0.25), radius: 1.5, y: 1)
            // 讓可點擊的範圍比看到的圓點大一些，比較好抓。
            .frame(width: 28, height: 28)
            .contentShape(Circle())
            .position(position)
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in drag(band, translation: value.translation, layout: layout) }
                    .onEnded { _ in dragOrigin = nil }
            )
            .simultaneousGesture(
                TapGesture(count: 2).onEnded {
                    selectedBand = band.id
                    equalizer.updateBand(band.id) { $0.gainDB = 0 }
                }
            )
            .simultaneousGesture(
                TapGesture().onEnded { selectedBand = band.id }
            )
            .help(String(format: "%.0f Hz · %+.1f dB · Q %.2f", band.frequency, band.gainDB, band.q))
            .accessibilityLabel("頻段 \(index + 1)")
            .accessibilityValue(String(format: "%.0f 赫茲，%+.1f 分貝", band.frequency, band.gainDB))
    }

    private func drag(_ band: EQBand, translation: CGSize, layout: Layout) {
        if dragOrigin?.id != band.id {
            dragOrigin = (band.id, band.frequency, band.gainDB)
            selectedBand = band.id
        }
        guard let origin = dragOrigin else { return }

        let factor = NSEvent.modifierFlags.contains(.shift) ? Self.fineTuneFactor : 1
        let x = layout.x(for: origin.frequency) + translation.width * factor
        let frequency = layout.frequency(for: x)
        let gain = origin.gainDB - Double(translation.height * factor / layout.pointsPerDecibel)

        equalizer.updateBand(band.id) { target in
            target.frequency = Self.roundedFrequency(frequency)
            if target.kind.hasGain {
                target.gainDB = (gain * 10).rounded() / 10
            }
        }
    }

    /// 取三位有效數字，避免出現 1237.48 Hz 這種沒有意義的精度。
    private static func roundedFrequency(_ frequency: Double) -> Double {
        let clamped = frequency.clamped(to: EQBand.frequencyRange)
        let magnitude = pow(10, floor(log10(clamped)) - 2)
        return (clamped / magnitude).rounded() * magnitude
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
