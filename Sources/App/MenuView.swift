import AudioCore
import SwiftUI

struct MenuView: View {
    @EnvironmentObject private var engine: AudioEngine
    @EnvironmentObject private var devices: DeviceManager

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("SoundDeck").font(.headline)
                Spacer()
                Toggle("啟用音訊處理", isOn: enabledBinding)
                    .toggleStyle(.switch)
                    .labelsHidden()
            }

            VolumeSection()

            Divider()

            DeviceListSection()

            Divider()

            MixerSection()

            Divider()

            EqualizerSection()

            Divider()

            statusSection

            Divider()

            Button("結束 SoundDeck") {
                NSApplication.shared.terminate(nil)
            }
        }
        .padding(14)
        .frame(width: 320)
    }

    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { engine.isEnabled },
            set: { $0 ? engine.start() : engine.stop() }
        )
    }

    @ViewBuilder
    private var statusSection: some View {
        switch engine.status {
        case .stopped:
            Label("已停用，聲音直接輸出", systemImage: "pause.circle")
                .font(.caption)
                .foregroundStyle(.secondary)

        case .starting:
            Label("啟動中…", systemImage: "hourglass")
                .font(.caption)
                .foregroundStyle(.secondary)

        case .running(let info):
            VStack(alignment: .leading, spacing: 6) {
                // 只有 Popover 開著時這個 view 才存在，所以收起來時不會輪詢。
                TimelineView(.periodic(from: .now, by: 0.1)) { _ in
                    LevelMeter(peak: engine.readStats()?.inputPeak ?? 0)
                }
                Text(String(
                    format: "%.1f kHz · 緩衝 %d frames（%.1f ms）",
                    info.sampleRate / 1000, info.bufferFrames, info.bufferMilliseconds
                ))
                .font(.caption2)
                .foregroundStyle(.secondary)
            }

        case .failed(let message):
            VStack(alignment: .leading, spacing: 6) {
                Label("音訊處理未運作", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("權限設定位置：系統設定 → 隱私權與安全性 → 螢幕與系統音訊錄製。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - 主音量

private struct VolumeSection: View {
    @EnvironmentObject private var engine: AudioEngine
    @EnvironmentObject private var devices: DeviceManager

    /// 軟體音量是在我們的管線裡做的，音訊處理沒開就不會生效。
    private var softwareVolumeUnavailable: Bool {
        guard let device = devices.currentDevice, !device.hasHardwareVolume else { return false }
        if case .running = engine.status { return false }
        return true
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: "speaker.fill")
                    .foregroundStyle(.secondary)
                Slider(
                    value: Binding(
                        get: { Double(devices.volume) },
                        set: { devices.setVolume(Float($0)) }
                    ),
                    in: 0...1
                )
                .disabled(devices.currentDevice == nil || softwareVolumeUnavailable)
                .accessibilityLabel("主音量")
                Image(systemName: "speaker.wave.3.fill")
                    .foregroundStyle(.secondary)
                Text("\(Int((devices.volume * 100).rounded()))%")
                    .font(.caption)
                    .monospacedDigit()
                    .frame(width: 36, alignment: .trailing)
            }

            if let device = devices.currentDevice, !device.hasHardwareVolume {
                Text(softwareVolumeUnavailable
                    ? "這個裝置本身沒有音量控制，啟用音訊處理後才能在這裡調整。"
                    : "這個裝置本身沒有音量控制，目前使用軟體音量。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let error = devices.lastError {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - 等化器

private struct EqualizerSection: View {
    @EnvironmentObject private var equalizer: EqualizerController
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("等化器")
                Spacer()
                Toggle("啟用等化器", isOn: Binding(
                    get: { !equalizer.settings.isBypassed },
                    set: { enabled in equalizer.update { $0.isBypassed = !enabled } }
                ))
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
            }

            HStack {
                EQPresetMenu()
                Button("編輯…") {
                    openWindow(id: WindowID.equalizer)
                    // 選單列 App 預設不會成為前景，不拉到前面的話視窗會被其他 App 蓋住。
                    NSApplication.shared.activate(ignoringOtherApps: true)
                }
            }
        }
    }
}

// MARK: - 輸出裝置

private struct DeviceListSection: View {
    @EnvironmentObject private var devices: DeviceManager

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("輸出裝置")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.bottom, 2)

            if devices.devices.isEmpty {
                Text("找不到輸出裝置")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            ForEach(devices.devices) { device in
                DeviceRow(device: device, isCurrent: device.id == devices.currentDeviceID) {
                    devices.select(device)
                }
            }
        }
    }
}

private struct DeviceRow: View {
    let device: OutputDevice
    let isCurrent: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: iconName)
                    .frame(width: 20)
                    .foregroundStyle(isCurrent ? Color.accentColor : .secondary)
                Text(device.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                if isCurrent {
                    Image(systemName: "checkmark")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                }
            }
            .padding(.vertical, 5)
            .padding(.horizontal, 6)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isHovered ? Color.primary.opacity(0.08) : .clear)
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
    }

    private var iconName: String {
        switch device.kind {
        case .builtIn: return "speaker.wave.2.fill"
        case .display: return "tv"
        case .bluetooth: return "headphones"
        case .usb: return "cable.connector"
        case .airPlay: return "airplayaudio"
        case .virtual: return "waveform"
        case .other: return "hifispeaker.fill"
        }
    }
}

// MARK: - 電平表

/// 簡單的峰值電平條，範圍 -60 dB 到 0 dB。
private struct LevelMeter: View {
    let peak: Float

    private var fraction: Double {
        guard peak > 0 else { return 0 }
        let decibels = 20 * log10(Double(peak))
        return min(max((decibels + 60) / 60, 0), 1)
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule()
                    .fill(peak >= 1 ? Color.red : Color.green)
                    .frame(width: geometry.size.width * fraction)
            }
        }
        .frame(height: 5)
        .accessibilityLabel("輸入電平")
    }
}
