import CoreAudio
import Foundation
import os

/// Core Audio 呼叫失敗時丟出的錯誤。
public struct CoreAudioError: Error, CustomStringConvertible {
    public let status: OSStatus
    public let operation: String

    public var description: String {
        "\(operation)失敗（OSStatus \(status) \(Self.fourCC(status))）"
    }

    private static func fourCC(_ status: OSStatus) -> String {
        let n = UInt32(bitPattern: status)
        let bytes = [UInt8(n >> 24 & 0xFF), UInt8(n >> 16 & 0xFF), UInt8(n >> 8 & 0xFF), UInt8(n & 0xFF)]
        guard bytes.allSatisfy({ $0 >= 0x20 && $0 < 0x7F }) else { return "" }
        return "'" + String(bytes: bytes, encoding: .ascii)! + "'"
    }
}

enum Log {
    private static let logger = Logger(subsystem: "local.sounddeck.app", category: "audio")

    static func info(_ message: String) {
        logger.notice("\(message, privacy: .public)")
    }

    static func error(_ message: String) {
        logger.error("\(message, privacy: .public)")
    }
}

/// Core Audio HAL 屬性存取的薄包裝。這裡的函式都不可在即時音訊執行緒上呼叫。
enum HAL {
    static let systemObject = AudioObjectID(kAudioObjectSystemObject)

    static func check(_ status: OSStatus, _ operation: @autoclosure () -> String) throws {
        guard status == noErr else {
            throw CoreAudioError(status: status, operation: operation())
        }
    }

    static func address(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    /// 讀取固定大小的純值屬性。
    static func read<T>(
        _ object: AudioObjectID,
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        initial: T,
        _ operation: String
    ) throws -> T {
        var addr = address(selector, scope: scope)
        var size = UInt32(MemoryLayout<T>.size)
        var value = initial
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(object, &addr, 0, nil, &size, $0)
        }
        try check(status, operation)
        return value
    }

    static func readString(
        _ object: AudioObjectID,
        _ selector: AudioObjectPropertySelector,
        _ operation: String
    ) throws -> String {
        var addr = address(selector)
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var value: Unmanaged<CFString>?
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(object, &addr, 0, nil, &size, $0)
        }
        try check(status, operation)
        guard let value else { return "" }
        return value.takeRetainedValue() as String
    }

    /// 某個方向（輸入／輸出）上，每個 buffer 各有幾個聲道。
    static func channelLayout(_ device: AudioObjectID, scope: AudioObjectPropertyScope) throws -> [Int] {
        var addr = address(kAudioDevicePropertyStreamConfiguration, scope: scope)
        var size: UInt32 = 0
        try check(AudioObjectGetPropertyDataSize(device, &addr, 0, nil, &size), "讀取聲道配置大小")
        guard size > 0 else { return [] }

        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { raw.deallocate() }
        try check(AudioObjectGetPropertyData(device, &addr, 0, nil, &size, raw), "讀取聲道配置")

        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.map { Int($0.mNumberChannels) }
    }

    // MARK: - 常用查詢

    static func defaultOutputDevice() throws -> AudioObjectID {
        let id = try read(
            systemObject, kAudioHardwarePropertyDefaultOutputDevice,
            initial: AudioObjectID(kAudioObjectUnknown), "取得預設輸出裝置"
        )
        guard id != kAudioObjectUnknown else {
            throw CoreAudioError(status: kAudioHardwareBadDeviceError, operation: "取得預設輸出裝置")
        }
        return id
    }

    static func deviceUID(_ device: AudioObjectID) throws -> String {
        try readString(device, kAudioDevicePropertyDeviceUID, "讀取裝置 UID")
    }

    static func deviceName(_ device: AudioObjectID) -> String {
        (try? readString(device, kAudioObjectPropertyName, "讀取裝置名稱")) ?? "未知裝置"
    }

    static func sampleRate(_ device: AudioObjectID) throws -> Double {
        try read(device, kAudioDevicePropertyNominalSampleRate, initial: Float64(0), "讀取取樣率")
    }

    static func bufferFrameSize(_ device: AudioObjectID) throws -> Int {
        Int(try read(device, kAudioDevicePropertyBufferFrameSize, initial: UInt32(0), "讀取緩衝區大小"))
    }

    /// 裝置偏好的立體聲左右聲道（1 起算）。讀不到時回傳 (1, 2)。
    static func preferredStereoChannels(_ device: AudioObjectID) -> (left: Int, right: Int) {
        let pair = try? read(
            device, kAudioDevicePropertyPreferredChannelsForStereo,
            scope: kAudioObjectPropertyScopeOutput,
            initial: (UInt32(1), UInt32(2)), "讀取偏好立體聲聲道"
        )
        guard let pair, pair.0 >= 1, pair.1 >= 1 else { return (1, 2) }
        return (Int(pair.0), Int(pair.1))
    }

    /// 把 PID 轉成 Core Audio 的 process 物件。該 process 尚未使用音訊時回傳 nil。
    static func processObject(pid: pid_t) -> AudioObjectID? {
        var addr = address(kAudioHardwarePropertyTranslatePIDToProcessObject)
        var pid = pid
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var object = AudioObjectID(kAudioObjectUnknown)
        let status = AudioObjectGetPropertyData(
            systemObject, &addr,
            UInt32(MemoryLayout<pid_t>.size), &pid,
            &size, &object
        )
        guard status == noErr, object != kAudioObjectUnknown else { return nil }
        return object
    }
}
