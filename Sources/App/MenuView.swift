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
                    .help("關閉後聲音會直接輸出，等化器、混音器與軟體音量都不作用。")
            }

            // 正常運作時不佔版面；只有啟動中、已停用或出錯時才顯示。
            statusBanner

            VolumeSection()

            Divider()

            DeviceListSection()

            Divider()

            MixerSection()

            Divider()

            EqualizerSection()

            Divider()

            FooterSection()
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
    private var statusBanner: some View {
        switch engine.status {
        case .running:
            EmptyView()

        case .stopped:
            Label("已停用，聲音直接輸出", systemImage: "pause.circle")
                .font(.caption)
                .foregroundStyle(.secondary)

        case .starting:
            Label("啟動中…", systemImage: "hourglass")
                .font(.caption)
                .foregroundStyle(.secondary)

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
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.12)))
        }
    }
}

// MARK: - 頁尾

private struct FooterSection: View {
    @StateObject private var loginItem = LoginItem()

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Toggle("開機時自動啟動", isOn: Binding(
                    get: { loginItem.isEnabled },
                    set: { loginItem.setEnabled($0) }
                ))
                .toggleStyle(.checkbox)
                .font(.callout)

                Spacer()

                Button("結束") {
                    NSApplication.shared.terminate(nil)
                }
                .help("結束 SoundDeck，聲音會恢復成系統原本的輸出。")
            }

            if let message = loginItem.message {
                Text(message)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear { loginItem.refresh() }
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
