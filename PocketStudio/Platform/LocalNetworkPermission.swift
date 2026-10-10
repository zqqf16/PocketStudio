// LocalNetworkPermission.swift — 主动触发并检测 macOS「本地网络」权限
//
// macOS 没有查询本地网络授权的 API。可靠做法（Apple DTS 推荐）：
//  1. Info.plist 声明 NSLocalNetworkUsageDescription + NSBonjourServices（_pocketstudio._tcp/_udp）；
//  2. 用 NWListener 广播该 Bonjour 服务，同时用 NWBrowser 浏览同一服务 —— 这会立刻弹出系统授权框；
//  3. 结果判断：
//     • NWBrowser 进入 .waiting 且错误为 kDNSServiceErr_PolicyDenied (-65570) → 已拒绝；
//     • 浏览到自己广播的服务（results 非空）→ 已允许；
//     • 超时（默认 20 秒，用户可能还没点弹窗）→ 未能确认，提示稍后重试或去系统设置检查。
//  另外向相机地址发一个 1 字节 UDP 包（与原项目相同），作为额外的触发。
// 结束后（或超时）清理 listener / browser / 连接。结果持久化到 UserDefaults。
//
// 隔离：@MainActor。Network.framework 的回调是 @Sendable、在私有 queue 上执行，
// 回调里只把 Sendable 的简化事件交给 Task { @MainActor in … }。

import Foundation
@preconcurrency import Network

extension Notification.Name {
    static let localNetworkPermissionChanged = Notification.Name("PocketStudio.localNetworkPermissionChanged")
}

@MainActor
final class LocalNetworkPermission {
    static let shared = LocalNetworkPermission()

    nonisolated enum State: String, Sendable {
        case notRequested, requesting, granted, denied, undetermined
        var displayText: String {
            switch self {
            case .notRequested: return "未请求"
            case .requesting: return "⏳ 等待授权…请在系统弹窗中点「允许」"
            case .granted: return "✅ 已允许"
            case .denied: return "❌ 已拒绝 —— 请点「系统设置」，在「隐私与安全性 → 本地网络」中打开 PocketStudio"
            case .undetermined: return "⚠️ 未能确认（可能尚未点击弹窗）。可再次点「请求」，或到系统设置中检查"
            }
        }
    }

    /// Network 回调 → 主线程的事件（全部 Sendable）
    nonisolated private enum Event: Sendable { case policyDenied, found, failed(String) }

    static let serviceType = "_pocketstudio._tcp"
    /// kDNSServiceErr_PolicyDenied（dns_sd.h）
    nonisolated static let policyDeniedCode: Int32 = -65570

    private let defaultsKey = "localNetworkPermission"
    private(set) var state: State {
        didSet {
            if state != .requesting { UserDefaults.standard.set(state.rawValue, forKey: defaultsKey) }
            NotificationCenter.default.post(name: .localNetworkPermissionChanged, object: nil)
        }
    }

    private var listener: NWListener?
    private var browser: NWBrowser?
    private var probe: NWConnection?
    private var timeoutTask: Task<Void, Never>?
    private let netQueue = DispatchQueue(label: "pocketstudio.localnetwork")

    private init() {
        let saved = UserDefaults.standard.string(forKey: "localNetworkPermission").flatMap(State.init(rawValue:))
        state = (saved == .requesting ? nil : saved) ?? .notRequested
    }

    /// 真正的 UDP 连接成功（握手成功）时调用：说明权限必然已允许
    func markGrantedFromTraffic() { if state != .granted { state = .granted } }

    /// 立即触发系统弹窗并开始检测
    func request(cameraIP: String = DJIUDPFrame.cameraIP, timeout: TimeInterval = 20) {
        cleanup()
        state = .requesting

        // 1) 广播 Bonjour 服务
        do {
            let l = try NWListener(using: .tcp)
            l.service = NWListener.Service(name: "PocketStudio-\(ProcessInfo.processInfo.processIdentifier)", type: Self.serviceType)
            l.newConnectionHandler = { c in c.cancel() }
            l.stateUpdateHandler = { [weak self] st in
                if case let .failed(e) = st {
                    let msg = e.localizedDescription
                    Task { @MainActor in self?.handle(.failed(msg)) }
                }
            }
            l.start(queue: netQueue)
            listener = l
        } catch {
            // 监听失败不致命：浏览本身也会触发弹窗
        }

        // 2) 浏览同一服务
        let b = NWBrowser(for: .bonjour(type: Self.serviceType, domain: nil), using: NWParameters())
        b.stateUpdateHandler = { [weak self] st in
            var ev: Event?
            switch st {
            case let .waiting(e), let .failed(e):
                if case let .dns(code) = e, Int32(code) == LocalNetworkPermission.policyDeniedCode { ev = .policyDenied }
            default: break
            }
            if let ev { Task { @MainActor in self?.handle(ev) } }
        }
        b.browseResultsChangedHandler = { [weak self] results, _ in
            if !results.isEmpty { Task { @MainActor in self?.handle(.found) } }
        }
        b.start(queue: netQueue)
        browser = b

        // 3) 额外：向相机地址发一个无害 UDP 包
        let c = NWConnection(host: NWEndpoint.Host(cameraIP), port: 9004, using: .udp)
        c.start(queue: netQueue)
        c.send(content: Data([0x00]), completion: .idempotent)
        probe = c

        timeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            guard !Task.isCancelled, let self, self.state == .requesting else { return }
            self.state = .undetermined
            self.cleanup()
        }
    }

    private func handle(_ ev: Event) {
        guard state == .requesting else { return }
        switch ev {
        case .found: state = .granted; cleanup()
        case .policyDenied: state = .denied; cleanup()
        case .failed: break // 等待浏览结果或超时
        }
    }

    func cleanup() {
        timeoutTask?.cancel(); timeoutTask = nil
        browser?.cancel(); browser = nil
        listener?.cancel(); listener = nil
        probe?.cancel(); probe = nil
    }

    func openSettings() { WiFiManager.openLocalNetworkPrivacy() }
}
