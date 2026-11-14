import AppKit
import AudioCore
import SwiftUI

/// 依 App 的混音器：每個正在使用音訊的 App 一列，最後一列是「系統音效與其他」。
struct MixerSection: View {
    @EnvironmentObject private var mixer: MixerController

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("混音器")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Toggle("依 App 指定裝置", isOn: Binding(
                    get: { mixer.isPerAppRoutingEnabled },
                    set: { mixer.setPerAppRoutingEnabled($0) }
                ))
                .toggleStyle(.switch)
                .controlSize(.mini)
                .font(.caption)
                .help("開啟後可以讓各 App 從不同的輸出裝置播放；關閉時全部走系統預設輸出，已指定的設定會保留。")
            }

            // 只有 Popover 開著時這個 view 才存在，所以收起來時不會輪詢電平。
            TimelineView(.periodic(from: .now, by: 0.1)) { _ in
                let peaks = mixer.readPeaks()
                // App 很多時只讓清單捲動，其他區塊保持在原位。
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(mixer.channels) { channel in
                            MixerRow(channel: channel, peak: peak(for: channel, in: peaks))
                        }
                        MixerRow(channel: mixer.other, peak: peak(for: mixer.other, in: peaks))
                    }
                    .padding(.trailing, mixer.channels.count > 4 ? 8 : 0)
                }
                .frame(maxHeight: 290)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func peak(for channel: MixerChannel, in peaks: [Float]) -> Float {
        channel.slot < peaks.count ? peaks[channel.slot] : 0
    }
}

private struct MixerRow: View {
    @EnvironmentObject private var mixer: MixerController
    @EnvironmentObject private var devices: DeviceManager
    let channel: MixerChannel
    let peak: Float

    private var isOther: Bool { channel.id == MixerController.otherID }

    /// 指定的裝置目前接著才算數；拔掉時這個 App 會暫時走系統預設。
    private var assignedDevice: OutputDevice? {
        guard let uid = channel.deviceUID else { return nil }
        return devices.devices.first { $0.uid == uid }
    }

    private var deviceMenu: some View {
        Menu {
            Button {
                mixer.setDevice(nil, for: channel.id)
            } label: {
                menuLabel("跟隨系統預設", isSelected: channel.deviceUID == nil)
            }
            Divider()
            ForEach(devices.devices) { device in
                Button {
                    mixer.setDevice(device.uid, for: channel.id)
                } label: {
                    menuLabel(device.name, isSelected: channel.deviceUID == device.uid)
                }
            }
        } label: {
            Image(systemName: channel.deviceUID == nil ? "hifispeaker" : "hifispeaker.fill")
                .foregroundStyle(channel.deviceUID == nil ? Color.secondary : Color.accentColor)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("選擇這個 App 的輸出裝置")
        .accessibilityLabel("\(channel.name) 的輸出裝置")
    }

    @ViewBuilder
    private func menuLabel(_ title: String, isSelected: Bool) -> some View {
        if isSelected {
            Label(title, systemImage: "checkmark")
        } else {
            Text(title)
        }
    }

    /// 名稱下方的小字：這個 App 被指定到哪個裝置。
    private var deviceCaption: String? {
        guard mixer.isPerAppRoutingEnabled, !isOther, channel.deviceUID != nil else { return nil }
        if let device = assignedDevice {
            return device.id == devices.currentDeviceID ? nil : "→ \(device.name)"
        }
        return "指定的裝置未連接，暫時使用系統預設"
    }

    var body: some View {
        HStack(spacing: 8) {
            icon
                .frame(width: 22, height: 22)
                .opacity(channel.isPlaying || isOther ? 1 : 0.5)

            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(channel.name)
                        .font(.callout)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .foregroundStyle(channel.isPlaying || isOther ? .primary : .secondary)
                    Spacer(minLength: 4)
                    Text(channel.isMuted ? "靜音" : "\(Int((channel.volume * 100).rounded()))%")
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }

                if let deviceCaption {
                    Text(deviceCaption)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Slider(
                    value: Binding(
                        get: { Double(channel.volume) },
                        set: { mixer.setVolume(Self.snapped(Float($0)), for: channel.id) }
                    ),
                    in: Double(MixerController.volumeRange.lowerBound)...Double(MixerController.volumeRange.upperBound)
                )
                .controlSize(.small)
                .disabled(channel.isMuted)
                .accessibilityLabel("\(channel.name) 音量")

                LevelBar(peak: peak)
            }

            if mixer.isPerAppRoutingEnabled, !isOther {
                deviceMenu
            }

            Button {
                mixer.setMuted(!channel.isMuted, for: channel.id)
            } label: {
                Image(systemName: channel.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .frame(width: 18)
                    .foregroundStyle(channel.isMuted ? Color.red : .secondary)
            }
            .buttonStyle(.borderless)
            .help(channel.isMuted ? "取消靜音" : "靜音")
            .accessibilityLabel(channel.isMuted ? "取消 \(channel.name) 的靜音" : "將 \(channel.name) 靜音")
        }
    }

    @ViewBuilder
    private var icon: some View {
        if let url = channel.bundleURL {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                .resizable()
        } else {
            Image(systemName: isOther ? "gearshape.2.fill" : "app.dashed")
                .resizable()
                .scaledToFit()
                .padding(2)
                .foregroundStyle(.secondary)
        }
    }

    /// 滑到 100% 附近時吸附到剛好 100%，方便回到原本的音量。
    private static func snapped(_ volume: Float) -> Float {
        abs(volume - 1) < 0.04 ? 1 : (volume * 100).rounded() / 100
    }
}

/// 細長的峰值電平條，範圍 -60 dB 到 0 dB。
private struct LevelBar: View {
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
        .frame(height: 3)
        .accessibilityHidden(true)
    }
}
