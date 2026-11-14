import AudioCore
import SwiftUI

struct MenuView: View {
    @EnvironmentObject private var engine: AudioEngine

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("SoundDeck").font(.headline)
                Spacer()
                Toggle("啟用", isOn: enabledBinding)
                    .toggleStyle(.switch)
                    .labelsHidden()
            }

            statusSection

            Divider()

            Button("結束 SoundDeck") {
                NSApplication.shared.terminate(nil)
            }
        }
        .padding(14)
        .frame(width: 300)
    }

    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { engine.status != .stopped },
            set: { $0 ? engine.start() : engine.stop() }
        )
    }

    @ViewBuilder
    private var statusSection: some View {
        switch engine.status {
        case .stopped:
            Label("已停用，聲音直接輸出", systemImage: "pause.circle")
                .foregroundStyle(.secondary)

        case .starting:
            Label("啟動中…", systemImage: "hourglass")
                .foregroundStyle(.secondary)

        case .running(let info):
            VStack(alignment: .leading, spacing: 8) {
                Label(info.deviceName, systemImage: "hifispeaker.fill")
                Text(String(
                    format: "%.1f kHz · 緩衝 %d frames（%.1f ms）",
                    info.sampleRate / 1000, info.bufferFrames, info.bufferMilliseconds
                ))
                .font(.caption)
                .foregroundStyle(.secondary)

                // 只有 Popover 開著時這個 view 才存在，所以收起來時不會輪詢。
                TimelineView(.periodic(from: .now, by: 0.1)) { _ in
                    LevelMeter(peak: engine.readStats()?.inputPeak ?? 0)
                }
            }

        case .failed(let message):
            VStack(alignment: .leading, spacing: 6) {
                Label("無法啟動", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("請確認已在「系統設定 → 隱私權與安全性 → 螢幕與系統音訊錄製」允許 SoundDeck。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// 簡單的峰值電平條，範圍 -60 dB 到 0 dB。
private struct LevelMeter: View {
    let peak: Float

    private var fraction: Double {
        guard peak > 0 else { return 0 }
        let decibels = 20 * log10(Double(peak))
        return min(max((decibels + 60) / 60, 0), 1)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule()
                        .fill(peak >= 1 ? Color.red : Color.green)
                        .frame(width: geometry.size.width * fraction)
                }
            }
            .frame(height: 6)

            Text(peak > 0 ? "輸入電平" : "輸入電平（目前沒有聲音；若正在播放卻沒有反應，請檢查錄音權限）")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
