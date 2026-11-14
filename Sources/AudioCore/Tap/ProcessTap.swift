import CoreAudio
import Foundation

/// 一個 Core Audio process tap。物件存活期間 tap 存在，釋放時自動銷毀。
///
/// 所有 tap 都只攔截「送往指定輸出裝置」的聲音，不用全域 tap：全域 tap 會連別的程式送往別的裝置的
/// 聲音一起抓，若系統裡有其他音訊轉送工具（虛擬裝置 → 實體喇叭）就會形成回授。
///
/// 靜音行為固定為 `mutedWhenTapped`：只有在我們實際讀取 tap 的期間，原本的聲音才會被靜音，
/// 所以 App 當掉或停止讀取時，系統聲音會自動恢復。
///
/// tap 攔截的對象可以在執行中改寫（`setProcesses`），不需要重建 aggregate device，音訊也不會中斷。
final class ProcessTap {
    enum Mode {
        /// 只攔截清單內的 process。清單是空的就什麼都不抓。
        case including
        /// 攔截清單以外的所有 process。
        case excluding
    }

    let id: AudioObjectID
    let uuid: UUID
    let format: AudioStreamBasicDescription
    private let description: CATapDescription
    private(set) var processes: [AudioObjectID]

    var channelCount: Int { Int(format.mChannelsPerFrame) }

    init(mode: Mode, processes: [AudioObjectID], outputDeviceUID: String, name: String) throws {
        let description: CATapDescription
        switch mode {
        case .including:
            description = CATapDescription(processes: processes, deviceUID: outputDeviceUID, stream: 0)
        case .excluding:
            description = CATapDescription(excludingProcesses: processes, deviceUID: outputDeviceUID, stream: 0)
        }
        let uuid = UUID()
        description.uuid = uuid
        description.name = name
        description.isPrivate = true
        description.muteBehavior = .mutedWhenTapped

        var tapID = AudioObjectID(kAudioObjectUnknown)
        try HAL.check(AudioHardwareCreateProcessTap(description, &tapID), "建立 process tap")

        do {
            self.format = try HAL.read(
                tapID, kAudioTapPropertyFormat,
                initial: AudioStreamBasicDescription(), "讀取 tap 格式"
            )
        } catch {
            AudioHardwareDestroyProcessTap(tapID)
            throw error
        }
        self.id = tapID
        self.uuid = uuid
        self.description = description
        self.processes = processes
    }

    /// 改寫這個 tap 的 process 清單（依模式是「要抓的」或「要排除的」）。
    @discardableResult
    func setProcesses(_ newProcesses: [AudioObjectID]) -> Bool {
        guard newProcesses != processes else { return true }
        description.processes = newProcesses

        var addr = HAL.address(kAudioTapPropertyDescription)
        var value = description
        let status = withUnsafePointer(to: &value) {
            AudioObjectSetPropertyData(id, &addr, 0, nil, UInt32(MemoryLayout<CATapDescription>.size), $0)
        }
        guard status == noErr else {
            Log.error("改寫 tap 對象失敗（OSStatus \(status)）")
            description.processes = processes
            return false
        }
        processes = newProcesses
        return true
    }

    deinit {
        AudioHardwareDestroyProcessTap(id)
    }
}
