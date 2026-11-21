import AudioToolbox
import CoreAudio
import Foundation
import os

/// Core Audio 呼叫失敗時丟出的錯誤。
public struct CoreAudioError: Error, CustomStringConvertible {
    public let status: OSStatus
    public let operation: String

    public var description: String {
        // operation 是中文原文，顯示時才翻譯，這樣各處呼叫時不必每次都包一層 L(…)。
        L("%@失敗（OSStatus %ld %@）", L(operation), Int(status), Self.fourCC(status))
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

    /// 我們自己建立的 aggregate device 的 UID 前綴，用來把它們從裝置清單中濾掉。
    static let aggregateUIDPrefix = "local.sounddeck.aggregate."

    /// 裝置的「虛擬主音量」（'vmvc'）。系統音量鍵用的就是這個屬性；
    /// 沒有主音量但有個別聲道音量的裝置，系統也會透過它統一控制。
    static let virtualMainVolume: AudioObjectPropertySelector = 0x766D_7663

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

    /// 讀取陣列型屬性。
    static func readArray<T>(
        _ object: AudioObjectID,
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        of type: T.Type,
        _ operation: String
    ) throws -> [T] {
        var addr = address(selector, scope: scope)
        var size: UInt32 = 0
        try check(AudioObjectGetPropertyDataSize(object, &addr, 0, nil, &size), operation)
        let count = Int(size) / MemoryLayout<T>.stride
        guard count > 0 else { return [] }
        return try [T](unsafeUninitializedCapacity: count) { buffer, initialized in
            try check(AudioObjectGetPropertyData(object, &addr, 0, nil, &size, buffer.baseAddress!), operation)
            initialized = Int(size) / MemoryLayout<T>.stride
        }
    }

    static func write<T>(
        _ object: AudioObjectID,
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        value: T,
        _ operation: String
    ) throws {
        var addr = address(selector, scope: scope)
        var value = value
        let status = withUnsafePointer(to: &value) {
            AudioObjectSetPropertyData(object, &addr, 0, nil, UInt32(MemoryLayout<T>.size), $0)
        }
        try check(status, operation)
    }

    static func isSettable(
        _ object: AudioObjectID,
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> Bool {
        var addr = address(selector, scope: scope)
        guard AudioObjectHasProperty(object, &addr) else { return false }
        var settable: DarwinBoolean = false
        return AudioObjectIsPropertySettable(object, &addr, &settable) == noErr && settable.boolValue
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

    /// 所有可以當成輸出的裝置（不含我們自己建立的 aggregate device）。
    static func outputDeviceIDs() -> [AudioObjectID] {
        let all = (try? readArray(
            systemObject, kAudioHardwarePropertyDevices, of: AudioObjectID.self, "列舉裝置"
        )) ?? []
        return all.filter { device in
            guard let layout = try? channelLayout(device, scope: kAudioObjectPropertyScopeOutput),
                  layout.reduce(0, +) > 0,
                  let uid = try? deviceUID(device),
                  !uid.hasPrefix(aggregateUIDPrefix)
            else { return false }
            let canBeDefault = (try? read(
                device, kAudioDevicePropertyDeviceCanBeDefaultDevice,
                scope: kAudioObjectPropertyScopeOutput, initial: UInt32(1), "讀取可否為預設裝置"
            )) ?? 1
            return canBeDefault != 0
        }
    }

    /// 依 UID 找出目前可用的輸出裝置；裝置不存在或不能輸出時回傳 nil。
    static func outputDevice(forUID uid: String) -> AudioObjectID? {
        outputDeviceIDs().first { (try? deviceUID($0)) == uid }
    }

    static func transportType(_ device: AudioObjectID) -> UInt32 {
        (try? read(device, kAudioDevicePropertyTransportType, initial: UInt32(0), "讀取連接方式")) ?? 0
    }

    /// 把系統的預設輸出與提示音輸出都切到指定裝置（與「系統設定」的行為一致）。
    static func setDefaultOutputDevice(_ device: AudioObjectID) throws {
        try write(systemObject, kAudioHardwarePropertyDefaultOutputDevice, value: device, "切換預設輸出裝置")
        try? write(systemObject, kAudioHardwarePropertyDefaultSystemOutputDevice, value: device, "切換提示音輸出裝置")
    }

    static func hasHardwareVolume(_ device: AudioObjectID) -> Bool {
        isSettable(device, virtualMainVolume, scope: kAudioObjectPropertyScopeOutput)
    }

    static func hardwareVolume(_ device: AudioObjectID) -> Float? {
        try? read(
            device, virtualMainVolume, scope: kAudioObjectPropertyScopeOutput,
            initial: Float32(0), "讀取裝置音量"
        )
    }

    static func setHardwareVolume(_ device: AudioObjectID, _ volume: Float) throws {
        try write(
            device, virtualMainVolume, scope: kAudioObjectPropertyScopeOutput,
            value: Float32(max(0, min(volume, 1))), "設定裝置音量"
        )
    }

    static func deviceUID(_ device: AudioObjectID) throws -> String {
        try readString(device, kAudioDevicePropertyDeviceUID, "讀取裝置 UID")
    }

    static func deviceName(_ device: AudioObjectID) -> String {
        (try? readString(device, kAudioObjectPropertyName, "讀取裝置名稱")) ?? L("未知裝置")
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

    // MARK: - 音訊 process

    /// 目前所有向系統註冊過音訊的 process 物件。
    static func processObjectIDs() -> [AudioObjectID] {
        (try? readArray(
            systemObject, kAudioHardwarePropertyProcessObjectList, of: AudioObjectID.self, "列舉音訊 process"
        )) ?? []
    }

    static func processPID(_ process: AudioObjectID) -> pid_t? {
        try? read(process, kAudioProcessPropertyPID, initial: pid_t(-1), "讀取 process PID")
    }

    static func processIsRunningOutput(_ process: AudioObjectID) -> Bool {
        ((try? read(process, kAudioProcessPropertyIsRunningOutput, initial: UInt32(0), "讀取 process 輸出狀態")) ?? 0) != 0
    }

    // MARK: - 聲道配置

    /// 每個輸出聲道在左側、右側或中間，給平衡決定要衰減哪些聲道用。
    ///
    /// 1、2 聲道直接視為單聲道、左右（有些 HDMI 裝置回報的立體聲配置是「左、未使用」，不可信）。
    /// 多聲道時，只有每個聲道都有明確的位置標籤才採用裝置回報的配置（例如 5.1 的 L R C LFE Ls Rs）；
    /// 否則，6 或 8 聲道且偏好的立體聲是 1、2 時視為標準的 5.1／7.1 排列，
    /// 其他情況只有偏好的立體聲那兩個聲道算左右。
    static func channelSides(_ device: AudioObjectID, count: Int) -> [ChannelSide] {
        guard count > 0 else { return [] }
        if count == 1 { return [.center] }
        if count == 2 { return [.left, .right] }

        if let labels = preferredChannelLabels(device), labels.count >= count {
            let used = labels.prefix(count)
            if used.allSatisfy(isPositional) {
                return used.map(side(for:))
            }
        }

        let preferred = preferredStereoChannels(device)
        if preferred.left == 1, preferred.right == 2, count == 6 || count == 8 {
            let surround: [ChannelSide] = [.left, .right, .center, .center, .left, .right, .left, .right]
            return Array(surround.prefix(count))
        }
        var sides = [ChannelSide](repeating: .center, count: count)
        if preferred.left - 1 < count { sides[preferred.left - 1] = .left }
        if preferred.right - 1 < count { sides[preferred.right - 1] = .right }
        return sides
    }

    /// 標籤有沒有說明聲道的實際位置。「未使用」「未知」或只是「第 N 個獨立聲道」都不算。
    private static func isPositional(_ label: AudioChannelLabel) -> Bool {
        label != kAudioChannelLabel_Unused
            && label != kAudioChannelLabel_Unknown
            && label != kAudioChannelLabel_UseCoordinates
            && !(label >= kAudioChannelLabel_Discrete && label <= kAudioChannelLabel_Discrete_65535)
            && label != kAudioChannelLabel_Mono
    }

    private static func side(for label: AudioChannelLabel) -> ChannelSide {
        switch label {
        case kAudioChannelLabel_Left, kAudioChannelLabel_LeftSurround, kAudioChannelLabel_LeftCenter,
             kAudioChannelLabel_LeftSurroundDirect, kAudioChannelLabel_RearSurroundLeft, kAudioChannelLabel_LeftWide,
             kAudioChannelLabel_VerticalHeightLeft, kAudioChannelLabel_TopBackLeft, kAudioChannelLabel_LeftTotal,
             kAudioChannelLabel_HeadphonesLeft:
            return .left
        case kAudioChannelLabel_Right, kAudioChannelLabel_RightSurround, kAudioChannelLabel_RightCenter,
             kAudioChannelLabel_RightSurroundDirect, kAudioChannelLabel_RearSurroundRight, kAudioChannelLabel_RightWide,
             kAudioChannelLabel_VerticalHeightRight, kAudioChannelLabel_TopBackRight, kAudioChannelLabel_RightTotal,
             kAudioChannelLabel_HeadphonesRight:
            return .right
        default:
            return .center
        }
    }

    /// 裝置偏好的輸出聲道配置，轉成每個聲道的標籤。讀不到時回傳 nil。
    private static func preferredChannelLabels(_ device: AudioObjectID) -> [AudioChannelLabel]? {
        var addr = address(kAudioDevicePropertyPreferredChannelLayout, scope: kAudioObjectPropertyScopeOutput)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &addr, 0, nil, &size) == noErr,
              size >= UInt32(MemoryLayout<AudioChannelLayout>.size)
        else { return nil }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioChannelLayout>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, raw) == noErr else { return nil }
        return labels(of: raw.assumingMemoryBound(to: AudioChannelLayout.self))
    }

    /// 把聲道配置展開成每個聲道的標籤。配置可能是直接列出每個聲道，也可能只給一個代碼（例如「5.1」），
    /// 後者要請系統展開。
    static func labels(of layout: UnsafePointer<AudioChannelLayout>) -> [AudioChannelLabel]? {
        let tag = layout.pointee.mChannelLayoutTag
        if tag == kAudioChannelLayoutTag_UseChannelDescriptions {
            let count = Int(layout.pointee.mNumberChannelDescriptions)
            guard count > 0 else { return nil }
            return withUnsafePointer(to: layout.pointee.mChannelDescriptions) { first in
                let descriptions = UnsafeRawPointer(first).assumingMemoryBound(to: AudioChannelDescription.self)
                return (0..<count).map { descriptions[$0].mChannelLabel }
            }
        }

        // 指標只能在 withUnsafePointer 的範圍內使用，所以展開的動作整個放在裡面做。
        if tag == kAudioChannelLayoutTag_UseChannelBitmap {
            var bitmap = layout.pointee.mChannelBitmap
            return withUnsafePointer(to: &bitmap) {
                expandLayout(kAudioFormatProperty_ChannelLayoutForBitmap, $0, UInt32(MemoryLayout<AudioChannelBitmap>.size))
            }
        }
        var tagValue = tag
        return withUnsafePointer(to: &tagValue) {
            expandLayout(kAudioFormatProperty_ChannelLayoutForTag, $0, UInt32(MemoryLayout<AudioChannelLayoutTag>.size))
        }
    }

    private static func expandLayout(
        _ property: AudioFormatPropertyID, _ specifier: UnsafeRawPointer, _ specifierSize: UInt32
    ) -> [AudioChannelLabel]? {
        var expandedSize: UInt32 = 0
        guard AudioFormatGetPropertyInfo(property, specifierSize, specifier, &expandedSize) == noErr,
              expandedSize >= UInt32(MemoryLayout<AudioChannelLayout>.size)
        else { return nil }
        let expanded = UnsafeMutableRawPointer.allocate(
            byteCount: Int(expandedSize), alignment: MemoryLayout<AudioChannelLayout>.alignment
        )
        defer { expanded.deallocate() }
        guard AudioFormatGetProperty(property, specifierSize, specifier, &expandedSize, expanded) == noErr else { return nil }
        let expandedLayout = expanded.assumingMemoryBound(to: AudioChannelLayout.self)
        guard expandedLayout.pointee.mChannelLayoutTag == kAudioChannelLayoutTag_UseChannelDescriptions else { return nil }
        return labels(of: expandedLayout)
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
