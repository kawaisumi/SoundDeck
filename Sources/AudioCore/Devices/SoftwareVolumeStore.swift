import Foundation

/// 不支援硬體音量的裝置（HDMI / DisplayPort 螢幕、部分 USB DAC）所使用的軟體音量。
/// 依裝置 UID 記住滑桿位置（0…1），沒設定過的裝置是 1（不衰減）。
enum SoftwareVolumeStore {
    private static let key = "softwareVolumeByDeviceUID"

    static func volume(forUID uid: String) -> Float {
        let table = UserDefaults.standard.dictionary(forKey: key) as? [String: Double] ?? [:]
        return Float(min(max(table[uid] ?? 1, 0), 1))
    }

    static func setVolume(_ volume: Float, forUID uid: String) {
        var table = UserDefaults.standard.dictionary(forKey: key) as? [String: Double] ?? [:]
        table[uid] = Double(min(max(volume, 0), 1))
        UserDefaults.standard.set(table, forKey: key)
    }

    /// 滑桿位置 → 線性增益。用平方曲線，讓滑桿的手感比較接近聽覺上的響度變化。
    static func gain(forVolume volume: Float) -> Float {
        let clamped = min(max(volume, 0), 1)
        return clamped * clamped
    }

    static func gain(forUID uid: String) -> Float {
        gain(forVolume: volume(forUID: uid))
    }
}

/// 左右聲道平衡，依裝置 UID 記住（耳機和喇叭各自的平衡通常不同）。−1 全左、0 置中、1 全右。
enum BalanceStore {
    private static let key = "balanceByDeviceUID"

    static func balance(forUID uid: String) -> Float {
        let table = UserDefaults.standard.dictionary(forKey: key) as? [String: Double] ?? [:]
        return Float(min(max(table[uid] ?? 0, -1), 1))
    }

    static func setBalance(_ balance: Float, forUID uid: String) {
        var table = UserDefaults.standard.dictionary(forKey: key) as? [String: Double] ?? [:]
        let clamped = Double(min(max(balance, -1), 1))
        // 置中就不必記，讓設定檔保持乾淨。
        table[uid] = clamped == 0 ? nil : clamped
        UserDefaults.standard.set(table, forKey: key)
    }
}
