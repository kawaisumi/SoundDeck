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
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let engine = AudioEngine()
    private var statsLogTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        engine.start()

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
