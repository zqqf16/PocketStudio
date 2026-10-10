// WiFiManager.swift — 加入相机 Wi-Fi（移植自 pocket3/wifi.py）
//
// 原项目用 `networksetup -setairportnetwork`。本应用优先用 CoreWLAN：
//   CWWiFiClient.shared().interface()?.associate(to:password:)
// 限制（macOS 14+）：
//   • 读取 SSID / 扫描结果需要「定位服务」授权，否则 SSID 为 nil，无法按名称匹配网络。
//   • 部分系统版本 / 企业管理的 Mac 会拒绝程序化加入。
// 因此失败时自动降级为「手动加入」引导：复制密码、打开 Wi-Fi 设置、自动检测是否已连上。
// 是否已连上相机网络，用 getifaddrs 检查是否获得 192.168.2.x 地址（不依赖定位权限）。

import Foundation
@preconcurrency import CoreWLAN
@preconcurrency import CoreLocation
import AppKit

nonisolated enum WiFiJoinError: LocalizedError, Sendable {
    case noInterface, locationDenied, networkNotFound(String), associate(String)
    var errorDescription: String? {
        switch self {
        case .noInterface: return "未找到 Wi-Fi 网卡，或 Wi-Fi 已关闭。"
        case .locationDenied: return "未授予「定位服务」权限，macOS 不允许 App 读取 Wi-Fi 名称（SSID）。"
        case let .networkNotFound(s): return "附近未扫描到「\(s)」。相机 Wi-Fi 可能尚未开启（配对后约需 20 秒）。"
        case let .associate(s): return "系统拒绝自动加入：\(s)"
        }
    }
}

/// 隔离：@MainActor。CLLocationManager 在主线程创建，委托回调也在主线程。
@MainActor
final class WiFiManager: NSObject, @preconcurrency CLLocationManagerDelegate {
    private let location = CLLocationManager()
    var onAuthorizationChange: (() -> Void)?

    override init() {
        super.init()
        location.delegate = self
    }

    var interface: CWInterface? { CWWiFiClient.shared().interface() }
    var interfaceName: String? { interface?.interfaceName }
    var isPoweredOn: Bool { interface?.powerOn() ?? false }
    var currentSSID: String? { interface?.ssid() }

    var locationStatus: CLAuthorizationStatus { location.authorizationStatus }
    var locationAuthorized: Bool {
        let s = location.authorizationStatus
        return s == .authorizedAlways || s == .authorized
    }

    func requestLocationAuthorization() { location.requestWhenInUseAuthorization() }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) { onAuthorizationChange?() }

    /// 本机所有 IPv4 地址（接口名, 地址）
    nonisolated static func ipv4Addresses() -> [(String, String)] {
        var out: [(String, String)] = []
        var ifap: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifap) == 0, let first = ifap else { return out }
        defer { freeifaddrs(ifap) }
        var p: UnsafeMutablePointer<ifaddrs>? = first
        while let cur = p {
            let ifa = cur.pointee
            if let sa = ifa.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) {
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                    out.append((String(cString: ifa.ifa_name), String(cString: host)))
                }
            }
            p = ifa.ifa_next
        }
        return out
    }

    /// 是否在相机网络上：SSID 匹配，或获得与相机同网段 (192.168.2.x) 的地址
    func isOnCameraNetwork(ssid: String, cameraIP: String) -> Bool {
        if let cur = currentSSID, cur == ssid { return true }
        let prefix = cameraIP.split(separator: ".").prefix(3).joined(separator: ".") + "."
        return Self.ipv4Addresses().contains { $0.1.hasPrefix(prefix) && $0.1 != cameraIP }
    }

    var localCameraNetworkAddress: String? {
        Self.ipv4Addresses().first { $0.1.hasPrefix("192.168.2.") }.map { "\($0.0) \($0.1)" }
    }

    /// 程序化加入（阻塞操作在后台执行）
    func join(ssid: String, password: String) async throws {
        guard let iface = interface, iface.powerOn() else { throw WiFiJoinError.noInterface }
        _ = iface
        // 后台执行阻塞的扫描/关联；在闭包内重新获取 CWInterface，不跨隔离域传递非 Sendable 对象。
        try await Task.detached(priority: .userInitiated) { () throws -> Void in
            guard let iface = CWWiFiClient.shared().interface() else { throw WiFiJoinError.noInterface }
            let nets: Set<CWNetwork>
            do { nets = try iface.scanForNetworks(withName: ssid) }
            catch { throw WiFiJoinError.associate(error.localizedDescription) }
            guard let net = nets.first(where: { $0.ssid == ssid }) ?? nets.first else {
                throw WiFiJoinError.networkNotFound(ssid)
            }
            do { try iface.associate(to: net, password: password) }
            catch { throw WiFiJoinError.associate(error.localizedDescription) }
        }.value
    }

    /// 轮询等待连上相机网络
    func waitForCameraNetwork(ssid: String, cameraIP: String, timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if isOnCameraNetwork(ssid: ssid, cameraIP: cameraIP) { return true }
            if Task.isCancelled { return false }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        return isOnCameraNetwork(ssid: ssid, cameraIP: cameraIP)
    }

    // MARK: 系统设置跳转

    static func openWiFiSettings() { open("x-apple.systempreferences:com.apple.wifi-settings-extension") }
    static func openBluetoothPrivacy() { open("x-apple.systempreferences:com.apple.preference.security?Privacy_Bluetooth") }
    static func openLocalNetworkPrivacy() { open("x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork") }
    static func openLocationPrivacy() { open("x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices") }
    private static func open(_ s: String) { if let u = URL(string: s) { NSWorkspace.shared.open(u) } }
}
