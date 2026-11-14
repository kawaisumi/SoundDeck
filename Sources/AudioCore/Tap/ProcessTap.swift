import CoreAudio
import Foundation

/// 一個 Core Audio process tap。物件存活期間 tap 存在，釋放時自動銷毀。
///
/// 靜音行為固定為 `mutedWhenTapped`：只有在我們實際讀取 tap 的期間，原本的聲音才會被靜音。
/// 因此 App 當掉或停止讀取時，系統聲音會自動恢復，不會變成沒聲音。
final class ProcessTap {
    let id: AudioObjectID
    let uuid: UUID
    let format: AudioStreamBasicDescription

    var channelCount: Int { Int(format.mChannelsPerFrame) }

    /// 攔截「送往指定輸出裝置」的所有聲音，但排除指定的 process。
    ///
    /// 刻意不用全域 tap：全域 tap 會連「別的 App 送往別的裝置」的聲音一起抓。
    /// 若系統裡有其他音訊轉送程式（虛擬裝置 → 實體喇叭），它轉送出來的聲音會被我們再抓一次、
    /// 再送回虛擬裝置，形成回授。只抓送往自己這個裝置的聲音，結構上就不會成環。
    ///
    /// tap 的格式會跟該裝置串流的格式相同，聲道數不一定是 2。
    init(outputDeviceUID: String, streamIndex: Int, excluding excluded: [AudioObjectID], name: String) throws {
        let description = CATapDescription(
            excludingProcesses: excluded, deviceUID: outputDeviceUID, stream: UInt(streamIndex)
        )
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
    }

    deinit {
        AudioHardwareDestroyProcessTap(id)
    }
}
