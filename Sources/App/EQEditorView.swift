import AppKit
import AudioCore
import SwiftUI

/// 參數式 EQ 的編輯視窗：上方是可拖曳的頻率響應曲線，下方是各頻段的精確數值。
struct EQEditorView: View {
    @EnvironmentObject private var engine: AudioEngine
    @EnvironmentObject private var devices: DeviceManager
    @EnvironmentObject private var equalizer: EqualizerController
    @State private var selectedBand: EQBand.ID?

    /// 曲線依實際輸出的取樣率計算；還沒有管線時用最常見的 48 kHz。
    private var sampleRate: Double {
        if case .running(let info) = engine.status, info.sampleRate > 0 { return info.sampleRate }
        return 48_000
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            EQCurveView(sampleRate: sampleRate, selectedBand: $selectedBand)
                .frame(height: 260)
                .opacity(equalizer.settings.isBypassed ? 0.45 : 1)

            Text("拖曳控制點調整頻率與增益 · 按住 Shift 微調 · 雙擊將增益歸零")
                .font(.caption)
                .foregroundStyle(.secondary)

            preampRow

            Divider()

            bandList
        }
        .padding(18)
        .frame(width: 700)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Toggle("啟用等化器", isOn: Binding(
                get: { !equalizer.settings.isBypassed },
                set: { enabled in equalizer.update { $0.isBypassed = !enabled } }
            ))
            .toggleStyle(.switch)

            Spacer()

            // 每個輸出裝置各有一組 EQ。預設編輯目前的輸出裝置，也可以切去調其他裝置的。
            Picker("裝置", selection: Binding(
                get: { equalizer.deviceUID ?? "" },
                set: { equalizer.select(deviceUID: $0.isEmpty ? nil : $0) }
            )) {
                ForEach(devices.devices) { device in
                    Text(device.id == devices.currentDeviceID ? "\(device.name)（目前輸出）" : device.name)
                        .tag(device.uid)
                }
            }
            .frame(width: 250)
            .help("每個輸出裝置各自記住一組等化器設定。")

            EQPresetMenu()
                .frame(width: 150)
        }
    }

    private var preampRow: some View {
        let settings = equalizer.settings
        let effective = settings.effectivePreampDB(sampleRate: sampleRate)
        return HStack(spacing: 10) {
            Text("前級增益")
                .frame(width: 60, alignment: .leading)
            Slider(
                value: Binding(
                    get: { settings.autoPreamp ? effective : settings.preampDB },
                    set: { value in equalizer.update { $0.preampDB = (value * 2).rounded() / 2 } }
                ),
                in: EQSettings.preampRange
            )
            .disabled(settings.autoPreamp)
            .accessibilityLabel("前級增益")
            Text(String(format: "%+.1f dB", effective))
                .monospacedDigit()
                .frame(width: 70, alignment: .trailing)
            Toggle("自動補償", isOn: Binding(
                get: { settings.autoPreamp },
                set: { auto in equalizer.update { $0.autoPreamp = auto } }
            ))
            .help("依曲線的最高點自動降低前級增益，避免加強頻段後整體音量過大而被限幅器壓縮。")
        }
    }

    private var bandList: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("").frame(width: 46)
                Text("類型").frame(width: 120, alignment: .leading)
                Text("頻率 (Hz)").frame(width: 90, alignment: .leading)
                Text("增益 (dB)").frame(width: 90, alignment: .leading)
                Text("Q 值").frame(width: 190, alignment: .leading)
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            ForEach(Array(equalizer.settings.bands.enumerated()), id: \.element.id) { index, band in
                EQBandRow(
                    index: index, band: band,
                    isSelected: band.id == selectedBand,
                    select: { selectedBand = band.id }
                )
            }

            HStack {
                Button {
                    selectedBand = equalizer.addBand()
                } label: {
                    Label("新增頻段", systemImage: "plus")
                }
                .disabled(!equalizer.canAddBand)

                Text("\(equalizer.settings.bands.count) / \(EQSettings.maxBands)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 4)
        }
    }
}

// MARK: - 預設組選單

struct EQPresetMenu: View {
    @EnvironmentObject private var equalizer: EqualizerController

    var body: some View {
        Menu {
            ForEach(EQPreset.builtIn) { preset in
                Button {
                    equalizer.apply(preset)
                } label: {
                    if preset.id == equalizer.matchingPreset?.id {
                        Label(preset.name, systemImage: "checkmark")
                    } else {
                        Text(preset.name)
                    }
                }
            }
        } label: {
            Text(equalizer.matchingPreset?.name ?? "自訂")
        }
        .accessibilityLabel("預設組")
    }
}

// MARK: - 頻段列

private struct EQBandRow: View {
    @EnvironmentObject private var equalizer: EqualizerController
    let index: Int
    let band: EQBand
    let isSelected: Bool
    let select: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Toggle("啟用頻段 \(index + 1)", isOn: binding(\.isEnabled))
                .labelsHidden()
            Text("\(index + 1)")
                .font(.caption.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(.white)
                .frame(width: 20, height: 20)
                .background(Circle().fill(EQPalette.color(for: index)))

            Picker("類型", selection: binding(\.kind)) {
                ForEach(EQBand.Kind.allCases, id: \.self) { kind in
                    Text(kind.displayName).tag(kind)
                }
            }
            .labelsHidden()
            .frame(width: 120)

            NumberField(value: binding(\.frequency), range: EQBand.frequencyRange, decimals: 0)
                .frame(width: 90)
                .accessibilityLabel("頻率")

            NumberField(value: binding(\.gainDB), range: EQBand.gainRange, decimals: 1)
                .frame(width: 90)
                .disabled(!band.kind.hasGain)
                .accessibilityLabel("增益")

            // Q 的有效範圍跨兩個數量級，用對數刻度的滑桿比較好調。
            Slider(
                value: Binding(
                    get: { log10(band.q) },
                    set: { value in equalizer.updateBand(band.id) { $0.q = (pow(10, value) * 100).rounded() / 100 } }
                ),
                in: log10(EQBand.qRange.lowerBound)...log10(EQBand.qRange.upperBound)
            )
            .frame(width: 130)
            .accessibilityLabel("Q 值")
            Text(String(format: "%.2f", band.q))
                .monospacedDigit()
                .frame(width: 44, alignment: .trailing)

            Spacer(minLength: 0)

            Button {
                equalizer.removeBand(band.id)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("刪除這個頻段")
            .accessibilityLabel("刪除頻段 \(index + 1)")
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? Color.accentColor.opacity(0.12) : .clear)
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: select)
        .opacity(band.isEnabled ? 1 : 0.55)
    }

    private func binding<Value>(_ keyPath: WritableKeyPath<EQBand, Value>) -> Binding<Value> {
        Binding(
            get: { band[keyPath: keyPath] },
            set: { value in
                select()
                equalizer.updateBand(band.id) { $0[keyPath: keyPath] = value }
            }
        )
    }
}

/// 按 Return 或離開欄位時才送出的數字輸入框，送出時會限制在合法範圍內。
private struct NumberField: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let decimals: Int

    @State private var text = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        TextField("", text: $text)
            .textFieldStyle(.roundedBorder)
            .monospacedDigit()
            .multilineTextAlignment(.trailing)
            .focused($isFocused)
            .onSubmit(commit)
            .onChange(of: isFocused) { _, focused in
                if !focused { commit() }
            }
            .onChange(of: value, initial: true) { _, newValue in
                if !isFocused { text = format(newValue) }
            }
    }

    private func format(_ number: Double) -> String {
        String(format: "%.\(decimals)f", number)
    }

    private func commit() {
        if let parsed = Double(text.trimmingCharacters(in: .whitespaces)) {
            value = min(max(parsed, range.lowerBound), range.upperBound)
        }
        text = format(value)
    }
}

// MARK: - 共用

enum EQPalette {
    private static let colors: [Color] = [.red, .orange, .yellow, .green, .mint, .cyan, .blue, .indigo, .purple, .pink]

    static func color(for index: Int) -> Color {
        colors[index % colors.count]
    }
}

extension EQBand.Kind {
    var displayName: String {
        switch self {
        case .peak: return "鐘形 (Peak)"
        case .lowShelf: return "低頻擱架"
        case .highShelf: return "高頻擱架"
        case .highPass: return "高通"
        case .lowPass: return "低通"
        case .notch: return "陷波"
        }
    }
}
