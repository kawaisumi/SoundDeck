import AppKit
import AudioCore
import Combine
import os
import SwiftUI

@main
struct SoundDeckApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra("SoundDeck", systemImage: "slider.vertical.3") {
            MenuView()
                .environmentObject(appDelegate.engine)
                .environmentObject(appDelegate.devices)
                .environmentObject(appDelegate.equalizer)
                .environmentObject(appDelegate.mixer)
                .environmentObject(appDelegate.updater)
        }
        .menuBarExtraStyle(.window)

        // EQ 編輯器是獨立視窗：Popover 點到外面就會收合，不適合長時間調整。
        Window(L("等化器"), id: WindowID.equalizer) {
            EQEditorView()
                .environmentObject(appDelegate.engine)
                .environmentObject(appDelegate.devices)
                .environmentObject(appDelegate.equalizer)
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)
    }
}

enum DebugFlags {
    static let preview = CommandLine.arguments.contains("--preview")
}

enum WindowID {
    static let equalizer = "equalizer"
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let engine: AudioEngine
    let devices: DeviceManager
    let equalizer: EqualizerController
    let mixer: MixerController
    let updater = Updater()
    private var statsLogTimer: Timer?
    private var subscriptions = Set<AnyCancellable>()

    override init() {
        engine = AudioEngine()
        devices = DeviceManager(engine: engine)
        equalizer = EqualizerController(engine: engine)
        mixer = MixerController(engine: engine)
        super.init()

        // EQ 預設跟著系統目前的輸出裝置走：切換輸出時，檢視與編輯的對象也換成新裝置的設定。
        devices.$currentDeviceID
            .map { [devices] _ in devices.currentDevice?.uid }
            .removeDuplicates()
            .sink { [equalizer] uid in equalizer.select(deviceUID: uid) }
            .store(in: &subscriptions)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 開發用：列出輸出裝置後直接結束，不啟動音訊處理（不需要錄音權限）。
        if CommandLine.arguments.contains("--dump-devices") {
            for device in devices.devices {
                let current = device.id == devices.currentDeviceID
                print(
                    current ? "*" : " ", device.name, "|", device.kind,
                    "|", device.hasHardwareVolume ? "硬體音量" : "軟體音量",
                    current ? "| 音量 \(Int((devices.volume * 100).rounded()))%" : ""
                )
            }
            exit(0)
        }

        // 開發用：列出混音器目前看到的 App 後直接結束。
        if CommandLine.arguments.contains("--dump-apps") {
            for channel in mixer.channels {
                print(
                    channel.isPlaying ? "▶" : " ", channel.name, "|", channel.id,
                    "| 槽位 \(channel.slot) | \(Int(channel.volume * 100))%\(channel.isMuted ? " 靜音" : "")"
                )
            }
            exit(0)
        }

        engine.start()

        if DebugFlags.preview { openPreviewWindows() }

        // 開發用：--route-test <App ID> <裝置名稱>，啟動 8 秒後把該 App 指定到該裝置，再過 10 秒還原。
        if let index = CommandLine.arguments.firstIndex(of: "--route-test"), index + 2 < CommandLine.arguments.count {
            let appID = CommandLine.arguments[index + 1]
            let deviceName = CommandLine.arguments[index + 2]
            let wasEnabled = mixer.isPerAppRoutingEnabled
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [mixer, devices] in
                guard let device = devices.devices.first(where: { $0.name == deviceName }) else { return }
                let previous = mixer.channels.first { $0.id == appID }?.deviceUID
                mixer.setPerAppRoutingEnabled(true)
                mixer.setDevice(device.uid, for: appID)
                DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
                    mixer.setDevice(previous, for: appID)
                    mixer.setPerAppRoutingEnabled(wasEnabled)
                }
            }
        }

        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { [engine] _ in engine.suspendForSleep() }
        workspace.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [engine] _ in engine.resumeAfterWake() }

        // 開發用：加上 --log-stats 啟動時，每 2 秒把診斷數值寫進系統記錄。
        if CommandLine.arguments.contains("--log-stats") {
            let logger = Logger(subsystem: "local.sounddeck.app", category: "stats")
            statsLogTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [engine, mixer] _ in
                let status = String(describing: engine.status)
                // 每條管線各列出有聲音的槽位，用來確認每個 App 實際是從哪個裝置播出的。
                let names = Dictionary(uniqueKeysWithValues: ([mixer.other] + mixer.channels).map { ($0.slot, $0.name) })
                let summary = engine.readSlotPeaksByDevice().map { device, peaks in
                    let active = peaks.enumerated().filter { $0.element > 0.0005 }.map { slot, peak in
                        "\(names[slot] ?? "槽位\(slot)")=\(String(format: "%.3f", peak))"
                    }
                    return "[\(device)] " + (active.isEmpty ? "靜音" : active.joined(separator: " "))
                }
                logger.notice("mixer \(summary.joined(separator: " "), privacy: .public)")
                if let stats = engine.readStats() {
                    logger.notice("callbacks=\(stats.callbackCount) peak=\(stats.inputPeak) status=\(status, privacy: .public)")
                } else {
                    logger.notice("no pipeline, status=\(status, privacy: .public)")
                }
            }
        }
    }

    /// 開發用：加上 --preview 啟動時，把選單列面板與 EQ 編輯器開成一般視窗，方便截圖檢查排版。
    private var previewWindows: [NSWindow] = []

    private func openPreviewWindows() {
        func show<Content: View>(_ title: String, _ content: Content, at origin: NSPoint) {
            let window = NSWindow(
                contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false
            )
            window.title = title
            window.isReleasedWhenClosed = false
            // 存成圖片時沒有視窗背景，深色模式的白字會看不見，所以預覽一律用淺色外觀。
            window.appearance = NSAppearance(named: .aqua)
            window.contentView = NSHostingView(rootView: content
                .environmentObject(engine)
                .environmentObject(devices)
                .environmentObject(equalizer)
                .environmentObject(mixer)
                .environmentObject(updater))
            window.setFrameTopLeftPoint(origin)
            window.orderFrontRegardless()
            previewWindows.append(window)
        }
        show("SoundDeck", MenuView(), at: NSPoint(x: 60, y: 900))
        show(L("等化器"), EQEditorView(), at: NSPoint(x: 420, y: 900))

        // --preview-snapshot <資料夾>：幾秒後把兩個視窗的畫面存成 PNG（不需要螢幕錄製權限）。
        if let index = CommandLine.arguments.firstIndex(of: "--preview-snapshot"),
           index + 1 < CommandLine.arguments.count {
            let folder = URL(fileURLWithPath: CommandLine.arguments[index + 1])
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [previewWindows] in
                for (number, window) in previewWindows.enumerated() {
                    guard let view = window.contentView,
                          let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
                    view.cacheDisplay(in: view.bounds, to: bitmap)
                    let file = folder.appendingPathComponent("preview-\(number).png")
                    try? bitmap.representation(using: .png, properties: [:])?.write(to: file)
                }
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        engine.shutdown()
    }
}
