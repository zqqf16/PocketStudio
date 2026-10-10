// AppSettings.swift — 用户设置（UserDefaults；Wi-Fi 密码存钥匙串）

import Foundation
import Security

extension Notification.Name {
    static let settingsChanged = Notification.Name("PocketStudio.settingsChanged")
}

nonisolated enum TransportKind: String, CaseIterable, Sendable {
    case network, bsd
    var displayName: String { self == .network ? "Network.framework（默认）" : "BSD Socket 兼容模式" }
}

@MainActor
final class AppSettings {
    static let shared = AppSettings()
    private let d = UserDefaults.standard

    private func notify() { NotificationCenter.default.post(name: .settingsChanged, object: nil) }

    var hasCompletedOnboarding: Bool {
        get { d.bool(forKey: "onboardingDone") } set { d.set(newValue, forKey: "onboardingDone") }
    }
    var ssid: String {
        get { d.string(forKey: "ssid") ?? "" } set { d.set(newValue, forKey: "ssid"); notify() }
    }
    var password: String {
        get { Keychain.read(account: "camera-wifi") ?? "" } set { Keychain.write(newValue, account: "camera-wifi"); notify() }
    }
    var cameraIP: String {
        get { d.string(forKey: "cameraIP") ?? DJIUDPFrame.cameraIP } set { d.set(newValue, forKey: "cameraIP"); notify() }
    }
    var bleTimeout: Double {
        get { d.object(forKey: "bleTimeout") as? Double ?? 15 } set { d.set(newValue, forKey: "bleTimeout") }
    }
    /// 配对后等待相机 AP 开启的秒数（原项目固定 20 秒）
    var apWaitSeconds: Double {
        get { d.object(forKey: "apWait") as? Double ?? 20 } set { d.set(newValue, forKey: "apWait") }
    }
    var skipBLE: Bool { get { d.bool(forKey: "skipBLE") } set { d.set(newValue, forKey: "skipBLE") } }
    var skipWiFi: Bool { get { d.bool(forKey: "skipWiFi") } set { d.set(newValue, forKey: "skipWiFi") } }
    var transport: TransportKind {
        get { TransportKind(rawValue: d.string(forKey: "transport") ?? "") ?? .network } set { d.set(newValue.rawValue, forKey: "transport") }
    }
    var wifiInterfaceOnly: Bool {
        get { d.object(forKey: "wifiOnly") as? Bool ?? true } set { d.set(newValue, forKey: "wifiOnly") }
    }
    var recordingFormat: RecordingFormat {
        get { RecordingFormat(rawValue: d.string(forKey: "recFormat") ?? "") ?? .mp4 } set { d.set(newValue.rawValue, forKey: "recFormat") }
    }
    var recordingFolder: URL {
        get {
            if let p = d.string(forKey: "recFolder") { return URL(fileURLWithPath: p) }
            return FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first!.appendingPathComponent("PocketStudio")
        }
        set { d.set(newValue.path, forKey: "recFolder"); notify() }
    }
    /// 云台速度（0.1…1.0），原项目默认 0.3，数字键 1–9 设置
    var gimbalSpeed: Double {
        get { d.object(forKey: "gimbalSpeed") as? Double ?? 0.3 } set { d.set(newValue, forKey: "gimbalSpeed"); notify() }
    }
    var trackpadScrollControl: Bool {
        get { d.object(forKey: "scrollCtl") as? Bool ?? true } set { d.set(newValue, forKey: "scrollCtl") }
    }
    var dragOnVideoControl: Bool {
        get { d.object(forKey: "dragCtl") as? Bool ?? true } set { d.set(newValue, forKey: "dragCtl") }
    }
    var invertPitch: Bool { get { d.bool(forKey: "invertPitch") } set { d.set(newValue, forKey: "invertPitch") } }
    var invertYaw: Bool { get { d.bool(forKey: "invertYaw") } set { d.set(newValue, forKey: "invertYaw") } }
    /// Gimbal:0x01 负载字段顺序。默认 [pitch, roll, yaw]（实机验证）；可切回原 Python 的 [yaw, roll, pitch]
    var gimbalAxisOrder: GimbalAxisOrder {
        get { GimbalAxisOrder(rawValue: d.string(forKey: "gimbalAxisOrder") ?? "") ?? .pitchRollYaw }
        set { d.set(newValue.rawValue, forKey: "gimbalAxisOrder") }
    }
    /// 原 Python 的命令头（ack=seq−32、0x60）与 ACK 组 2（自己的 cmdSeq）；默认关 = OpenPocketCine 布局
    /// TCP 7001 SetPairingPIN（OPC：Pocket 系列握手前先戳一下并保持连接）。默认开。
    var tcpPoke: Bool { get { d.object(forKey: "tcpPoke") as? Bool ?? true } set { d.set(newValue, forKey: "tcpPoke") } }
    /// 拍照后相机自动进入回放时发「退出回放」。默认开。
    var autoExitPlayback: Bool { get { d.object(forKey: "autoExitPlayback") as? Bool ?? true } set { d.set(newValue, forKey: "autoExitPlayback") } }
    var legacyFraming: Bool { get { d.bool(forKey: "legacyFraming") } set { d.set(newValue, forKey: "legacyFraming") } }
    var swapPitchYaw: Bool { get { d.bool(forKey: "swapPY") } set { d.set(newValue, forKey: "swapPY") } }
    var continuousGimbalStream: Bool {
        get { d.object(forKey: "gimbalStream") as? Bool ?? true } set { d.set(newValue, forKey: "gimbalStream") }
    }
}

nonisolated enum Keychain {
    private static let service = "com.pocketstudio.app"
    static func read(account: String) -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: account, kSecReturnData as String: true,
                                kSecMatchLimit as String: kSecMatchLimitOne]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
    static func write(_ value: String, account: String) {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                   kSecAttrAccount as String: account]
        SecItemDelete(base as CFDictionary)
        guard !value.isEmpty else { return }
        var add = base; add[kSecValueData as String] = Data(value.utf8)
        SecItemAdd(add as CFDictionary, nil)
    }
}
