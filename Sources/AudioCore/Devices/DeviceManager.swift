import Combine
import CoreAudio
import Foundation

public struct OutputDevice: Identifiable, Equatable, Sendable {
    public enum Kind: Sendable {
        case builtIn, display, bluetooth, usb, airPlay, virtual, other
    }

    public let id: AudioObjectID
    public let uid: String
    public let name: String
    public let kind: Kind
    /// false 表示裝置本身沒有音量控制，主音量會改用軟體音量。
    public let hasHardwareVolume: Bool
}

/// 輸出裝置的清單、切換與主音量。所有方法都必須在主執行緒呼叫。
public final class DeviceManager: ObservableObject {
    @Published public private(set) var devices: [OutputDevice] = []
    @Published public private(set) var currentDeviceID: AudioObjectID?
    /// 目前輸出裝置的主音量（0…1）。
    @Published public private(set) var volume: Float = 1
    /// 目前輸出裝置的左右平衡（−1 全左、0 置中、1 全右）。
    @Published public private(set) var balance: Float = 0
    @Published public private(set) var lastError: String?

    public var currentDevice: OutputDevice? {
        devices.first { $0.id == currentDeviceID }
    }

    private let engine: AudioEngine
    private var volumeListener: (device: AudioObjectID, block: AudioObjectPropertyListenerBlock)?

    public init(engine: AudioEngine) {
        self.engine = engine

        listen(kAudioHardwarePropertyDevices) { [weak self] in self?.refresh() }
        listen(kAudioHardwarePropertyDefaultOutputDevice) { [weak self] in self?.refresh() }
        refresh()
    }

    // MARK: - 操作

    public func select(_ device: OutputDevice) {
        do {
            try HAL.setDefaultOutputDevice(device.id)
            lastError = nil
        } catch {
            lastError = "\(error)"
        }
        // 實際的狀態更新由預設裝置改變的通知帶動；管線重建由 AudioEngine 自己監聽。
    }

    public func setVolume(_ newValue: Float) {
        guard let device = currentDevice else { return }
        let clamped = min(max(newValue, 0), 1)
        volume = clamped

        if device.hasHardwareVolume {
            do {
                try HAL.setHardwareVolume(device.id, clamped)
            } catch {
                lastError = "\(error)"
            }
        } else {
            SoftwareVolumeStore.setVolume(clamped, forUID: device.uid)
            engine.setSoftwareGain(SoftwareVolumeStore.gain(forVolume: clamped), forDeviceUID: device.uid)
        }
    }

    public func setBalance(_ newValue: Float) {
        guard let device = currentDevice else { return }
        let clamped = min(max(newValue, -1), 1)
        balance = clamped
        BalanceStore.setBalance(clamped, forUID: device.uid)
        engine.setBalance(clamped, forDeviceUID: device.uid)
    }

    // MARK: - 狀態同步

    private func refresh() {
        devices = HAL.outputDeviceIDs().compactMap { id in
            guard let uid = try? HAL.deviceUID(id) else { return nil }
            return OutputDevice(
                id: id,
                uid: uid,
                name: HAL.deviceName(id),
                kind: Self.kind(forTransport: HAL.transportType(id)),
                hasHardwareVolume: HAL.hasHardwareVolume(id)
            )
        }

        let current = try? HAL.defaultOutputDevice()
        if current != currentDeviceID {
            currentDeviceID = current
            observeVolume(of: currentDevice)
        }
        syncVolume()
    }

    private func syncVolume() {
        guard let device = currentDevice else { return }
        let savedBalance = BalanceStore.balance(forUID: device.uid)
        if savedBalance != balance { balance = savedBalance }
        let value = device.hasHardwareVolume
            ? (HAL.hardwareVolume(device.id) ?? volume)
            : SoftwareVolumeStore.volume(forUID: device.uid)
        if abs(value - volume) > 0.001 {
            volume = value
        }
    }

    /// 監聽目前裝置的硬體音量，讓鍵盤音量鍵或其他程式的調整能反映到滑桿上。
    private func observeVolume(of device: OutputDevice?) {
        var addr = HAL.address(HAL.virtualMainVolume, scope: kAudioObjectPropertyScopeOutput)
        if let old = volumeListener {
            AudioObjectRemovePropertyListenerBlock(old.device, &addr, .main, old.block)
            volumeListener = nil
        }
        guard let device, device.hasHardwareVolume else { return }

        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.syncVolume() }
        if AudioObjectAddPropertyListenerBlock(device.id, &addr, .main, block) == noErr {
            volumeListener = (device.id, block)
        }
    }

    private func listen(_ selector: AudioObjectPropertySelector, _ handler: @escaping () -> Void) {
        var addr = HAL.address(selector)
        let status = AudioObjectAddPropertyListenerBlock(HAL.systemObject, &addr, .main) { _, _ in handler() }
        if status != noErr {
            Log.error("無法監聽系統音訊屬性 \(selector)（OSStatus \(status)）")
        }
    }

    private static func kind(forTransport transport: UInt32) -> OutputDevice.Kind {
        switch transport {
        case kAudioDeviceTransportTypeBuiltIn: return .builtIn
        case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort: return .display
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: return .bluetooth
        case kAudioDeviceTransportTypeUSB: return .usb
        case kAudioDeviceTransportTypeAirPlay: return .airPlay
        case kAudioDeviceTransportTypeVirtual, kAudioDeviceTransportTypeAggregate: return .virtual
        default: return .other
        }
    }
}
