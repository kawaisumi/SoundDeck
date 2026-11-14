import AppKit
import CoreAudio
import Darwin
import Foundation

/// 一個正在使用音訊的 App，以及屬於它的所有音訊 process（含 helper）。
struct AudioAppSnapshot: Equatable {
    /// bundle ID；沒有 bundle ID 的程式（例如指令列工具開的視窗）用 "name-<名稱>"，這樣設定才能跨次啟動保留。
    let id: String
    let name: String
    let bundleURL: URL?
    var processes: [AudioObjectID]
    var isPlaying: Bool
}

/// 列出目前有哪些 App 在使用音訊，並把 helper process 歸併到它所屬的 App。只能在主執行緒使用。
///
/// 瀏覽器與 Electron App 的聲音實際上是由 helper process 發出的（例如 `Google Chrome Helper`、
/// `com.apple.WebKit.GPU`），所以不能直接用音訊 process 自己的身分，而要找出「它是替誰工作的」。
/// 無法歸屬到任何一般 App 的 process（系統音效、Siri、各種 daemon）不會出現在結果裡，
/// 它們的聲音由混音器的「系統音效與其他」統一處理。
final class AudioProcessMonitor {
    private struct Owner {
        let id: String
        let name: String
        let bundleURL: URL?
    }

    /// PID → 所屬 App。一個 process 的歸屬不會改變，查過就記著；nil 表示查過但不屬於任何 App。
    private var ownerCache: [pid_t: Owner?] = [:]
    private let ownPID = getpid()

    func snapshot() -> [AudioAppSnapshot] {
        var apps: [String: AudioAppSnapshot] = [:]
        var order: [String] = []
        var alivePIDs = Set<pid_t>()

        for process in HAL.processObjectIDs() {
            guard let pid = HAL.processPID(process), pid > 0, pid != ownPID else { continue }
            alivePIDs.insert(pid)

            let owner: Owner?
            if let cached = ownerCache[pid] {
                owner = cached
            } else {
                owner = Self.findOwner(of: pid, ownPID: ownPID)
                ownerCache[pid] = .some(owner)
            }
            guard let owner else { continue }

            let playing = HAL.processIsRunningOutput(process)
            if apps[owner.id] == nil {
                apps[owner.id] = AudioAppSnapshot(
                    id: owner.id, name: owner.name, bundleURL: owner.bundleURL,
                    processes: [], isPlaying: false
                )
                order.append(owner.id)
            }
            apps[owner.id]?.processes.append(process)
            if playing { apps[owner.id]?.isPlaying = true }
        }

        // PID 會被系統重複使用，已經消失的 process 要從快取移除。
        ownerCache = ownerCache.filter { alivePIDs.contains($0.key) }

        return order.compactMap { apps[$0] }.map { app in
            var sorted = app
            sorted.processes.sort()
            return sorted
        }
    }

    // MARK: - 歸屬判定

    /// 找出一個音訊 process 是替哪個 App 發聲的。
    ///
    /// 候選依序是：process 自己 → 系統記錄的「負責的 process」→ 往上的父 process。
    /// 第一個「獨立的 App」就是擁有者。包在別的 App 裡面的 helper（例如
    /// `Discord.app/Contents/Frameworks/Discord Helper.app`）雖然系統也把它當成 App，但不算獨立，
    /// 要繼續往上找；真的都找不到時，改用包住它的最外層 App。
    private static func findOwner(of pid: pid_t, ownPID: pid_t) -> Owner? {
        var candidates: [pid_t] = [pid]
        if let responsible = responsiblePID(for: pid), responsible > 0 {
            candidates.append(responsible)
        }
        var current = pid
        for _ in 0..<6 {
            guard let parent = parentPID(of: current), parent > 1 else { break }
            candidates.append(parent)
            current = parent
        }

        var enclosingBundle: URL?
        for candidate in candidates where candidate != ownPID {
            guard let app = NSRunningApplication(processIdentifier: candidate),
                  app.activationPolicy != .prohibited
            else { continue }
            if let outer = app.bundleURL.flatMap(outermostEnclosingApp) {
                enclosingBundle = enclosingBundle ?? outer
                continue
            }
            return owner(for: app, pid: candidate)
        }

        if let enclosingBundle,
           let app = NSWorkspace.shared.runningApplications.first(where: {
               $0.bundleURL?.standardizedFileURL == enclosingBundle && $0.processIdentifier != ownPID
           }) {
            return owner(for: app, pid: app.processIdentifier)
        }
        return nil
    }

    private static func owner(for app: NSRunningApplication, pid: pid_t) -> Owner {
        Owner(
            id: app.bundleIdentifier ?? app.localizedName.map { "name-\($0)" } ?? "pid-\(pid)",
            name: app.localizedName ?? app.bundleIdentifier ?? "PID \(pid)",
            bundleURL: app.bundleURL
        )
    }

    /// 如果這個 bundle 位在另一個 .app 裡面，回傳最外層那個 .app；本身就是最外層則回傳 nil。
    static func outermostEnclosingApp(of bundleURL: URL) -> URL? {
        let components = bundleURL.standardizedFileURL.pathComponents
        guard let first = components.firstIndex(where: { $0.hasSuffix(".app") }),
              first < components.count - 1
        else { return nil }
        return URL(fileURLWithPath: NSString.path(withComponents: Array(components[...first])))
            .standardizedFileURL
    }

    private typealias ResponsibilityFunction = @convention(c) (pid_t) -> pid_t

    /// `responsibility_get_pid_responsible_for_pid`：系統用來判斷「這個 process 是替哪個 App 工作」的函式，
    /// 權限視窗顯示的 App 名稱就是靠它。它不在公開標頭裡，所以用 dlsym 查；查不到就退回父 process 的方式。
    private static let responsibilityFunction: ResponsibilityFunction? = {
        let rtldDefault = UnsafeMutableRawPointer(bitPattern: -2)
        guard let symbol = dlsym(rtldDefault, "responsibility_get_pid_responsible_for_pid") else { return nil }
        return unsafeBitCast(symbol, to: ResponsibilityFunction.self)
    }()

    private static func responsiblePID(for pid: pid_t) -> pid_t? {
        guard let function = responsibilityFunction else { return nil }
        let result = function(pid)
        return result > 0 ? result : nil
    }

    private static func parentPID(of pid: pid_t) -> pid_t? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
        return info.kp_eproc.e_ppid
    }
}
