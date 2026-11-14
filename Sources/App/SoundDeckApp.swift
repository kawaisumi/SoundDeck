import AppKit
import AudioCore
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
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let engine: AudioEngine
    let devices: DeviceManager
    private var statsLogTimer: Timer?

    override init() {
        engine = AudioEngine()
        devices = DeviceManager(engine: engine)
        super.init()
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

        engine.start()

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
            statsLogTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [engine] _ in
                let status = String(describing: engine.status)
                if let stats = engine.readStats() {
                    logger.notice("callbacks=\(stats.callbackCount) peak=\(stats.inputPeak) status=\(status, privacy: .public)")
                } else {
                    logger.notice("no pipeline, status=\(status, privacy: .public)")
                }
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        engine.shutdown()
    }
}
