import AppKit
import AudioCore
import SwiftUI
import UniformTypeIdentifiers

/// 匯入 EQ 設定：AutoEQ 的 ParametricEQ.txt、Equalizer APO 格式，或 AI 依範本產生的整段回覆。
struct EQImportView: View {
    @EnvironmentObject private var devices: DeviceManager
    @EnvironmentObject private var equalizer: EqualizerController
    @Environment(\.dismiss) private var dismiss

    @State private var text = ""
    @State private var name = ""
    /// 使用者是否自己改過名稱；沒改過的話，名稱跟著貼上的內容自動更新。
    @State private var nameEdited = false
    @State private var isPickingFile = false
    @State private var fileError: String?
    @State private var copiedMessage: String?

    private var parseResult: Result<EQTextFormat.Parsed, EQTextFormat.ParseError>? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        do {
            return .success(try EQTextFormat.parse(trimmed))
        } catch let error as EQTextFormat.ParseError {
            return .failure(error)
        } catch {
            return .failure(.noFilters)
        }
    }

    private var parsed: EQTextFormat.Parsed? {
        if case .success(let value) = parseResult { return value }
        return nil
    }

    private var deviceName: String? {
        devices.devices.first { $0.uid == equalizer.deviceUID }?.name
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("匯入 EQ 設定")
                .font(.headline)

            aiSection

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("貼上設定內容")
                    Spacer()
                    Button("從剪貼簿貼上") { pasteFromClipboard() }
                    Button("選擇檔案…") { isPickingFile = true }
                }
                TextEditor(text: $text)
                    .font(.system(.callout, design: .monospaced))
                    .frame(height: 150)
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary))
                    .overlay(alignment: .topLeading) {
                        if text.isEmpty {
                            Text("支援 AutoEQ 的 ParametricEQ.txt、Equalizer APO 的參數式 EQ，\n也可以把 AI 的整段回覆直接貼進來。")
                                .font(.callout)
                                .foregroundStyle(.tertiary)
                                .padding(8)
                                .allowsHitTesting(false)
                        }
                    }
                    .accessibilityLabel("設定內容")
                if let fileError {
                    Text(fileError)
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            preview

            HStack {
                Text("名稱")
                TextField("預設組名稱", text: Binding(
                    get: { name },
                    set: { name = $0; nameEdited = true }
                ))
                .textFieldStyle(.roundedBorder)
            }

            HStack {
                Text(deviceName.map { "會套用到「\($0)」的等化器。" } ?? "會套用到目前的等化器。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("取消", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("套用") { apply(saveAsPreset: false) }
                    .disabled(parsed == nil)
                Button("套用並存為預設組") { apply(saveAsPreset: true) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(parsed == nil || name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(18)
        .frame(width: 560)
        .fileImporter(
            isPresented: $isPickingFile,
            allowedContentTypes: [.plainText, .text],
            allowsMultipleSelection: false
        ) { result in
            loadFile(result)
        }
        .onChange(of: parsed?.name) { _, newName in
            if !nameEdited, let newName { name = newName }
        }
    }

    // MARK: - 區塊

    private var aiSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("請 AI 幫你調")
                .font(.subheadline.weight(.semibold))
            Text("複製範本貼給 ChatGPT、Claude 等 AI，把括號裡的內容改成你的播放裝置和常聽的音樂。AI 回覆後，把整段回覆貼到下面即可匯入。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button {
                    copy(EQTextFormat.aiPrompt(deviceName: deviceName, current: equalizer.settings), message: "已複製範本")
                } label: {
                    Label("複製給 AI 的範本", systemImage: "doc.on.doc")
                }
                Button {
                    copy(EQTextFormat.format(equalizer.settings, name: equalizer.matchingPreset?.name), message: "已複製目前的設定")
                } label: {
                    Label("複製目前的設定", systemImage: "square.and.arrow.up")
                }
                .help("把目前的等化器設定複製成文字，可以分享給別人或存檔。")
                if let copiedMessage {
                    Text(copiedMessage)
                        .font(.caption)
                        .foregroundStyle(.green)
                }
            }
        }
    }

    @ViewBuilder
    private var preview: some View {
        switch parseResult {
        case nil:
            EmptyView()

        case .failure(let error):
            Label(error.description, systemImage: "xmark.octagon.fill")
                .font(.caption)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)

        case .success(let result):
            VStack(alignment: .leading, spacing: 4) {
                Label(summary(of: result), systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
                ForEach(Array(result.bands.enumerated()), id: \.offset) { index, band in
                    Text(describe(band, index: index))
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(band.isEnabled ? .primary : .secondary)
                }
                ForEach(result.warnings, id: \.self) { warning in
                    Label(warning, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.05)))
        }
    }

    private func summary(of result: EQTextFormat.Parsed) -> String {
        var text = "找到 \(result.bands.count) 個頻段"
        if let preamp = result.preampDB {
            text += String(format: "。檔案的前級增益 %+.1f dB 僅供參考，匯入後改由自動補償計算", preamp)
        }
        return text + "。"
    }

    private func describe(_ band: EQBand, index: Int) -> String {
        let gain = band.kind.hasGain ? String(format: "%+5.1f dB", band.gainDB) : "        "
        let kind: String
        switch band.kind {
        case .peak: kind = "鐘形"
        case .lowShelf: kind = "低頻擱架"
        case .highShelf: kind = "高頻擱架"
        case .highPass: kind = "高通"
        case .lowPass: kind = "低通"
        case .notch: kind = "陷波"
        }
        return String(format: "%2d  %@  %6.0f Hz  %@  Q %.2f%@",
                      index + 1, kind.padding(toLength: 4, withPad: "　", startingAt: 0),
                      band.frequency, gain, band.q, band.isEnabled ? "" : "（停用）")
    }

    // MARK: - 動作

    private func copy(_ string: String, message: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
        copiedMessage = message
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            if copiedMessage == message { copiedMessage = nil }
        }
    }

    private func pasteFromClipboard() {
        guard let string = NSPasteboard.general.string(forType: .string), !string.isEmpty else {
            fileError = "剪貼簿裡沒有文字。"
            return
        }
        fileError = nil
        text = string
    }

    private func loadFile(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result, let url = urls.first else { return }
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        do {
            text = try String(contentsOf: url, encoding: .utf8)
            fileError = nil
            // AutoEQ 的檔名就是耳機型號，例如「Sennheiser HD 650 ParametricEQ.txt」。
            if !nameEdited {
                let base = url.deletingPathExtension().lastPathComponent
                name = parsed?.name ?? base.replacingOccurrences(of: " ParametricEQ", with: "")
            }
        } catch {
            fileError = "無法讀取檔案：\(error.localizedDescription)"
        }
    }

    private func apply(saveAsPreset: Bool) {
        guard let parsed else { return }
        equalizer.update { settings in
            settings.bands = parsed.bands.map {
                EQBand(kind: $0.kind, frequency: $0.frequency, gainDB: $0.gainDB, q: $0.q, isEnabled: $0.isEnabled)
            }
            // 預設組只記頻段，所以前級一律交給自動補償，之後重新套用預設組時結果才會一致。
            settings.autoPreamp = true
            settings.isBypassed = false
        }
        if saveAsPreset {
            equalizer.saveCurrentAsPreset(named: name)
        }
        dismiss()
    }
}
