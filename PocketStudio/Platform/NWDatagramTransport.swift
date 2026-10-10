// NWDatagramTransport.swift — 基于 Network.framework 的 UDP 传输（默认）
//
// 首次向 192.168.2.1 发包时，macOS 会弹出「本地网络」权限对话框（Info.plist: NSLocalNetworkUsageDescription）。
// requiredInterfaceType = .wifi 相当于原项目绑定 en1 的 WiFi 地址，确保包从 WiFi 网卡发出。

import Foundation
@preconcurrency import Network

/// 隔离：nonisolated + @unchecked Sendable。所有状态只在 CameraLink 的串行 queue 上被访问
/// （start/stop/send 由 CameraLink 在其 queue 上调用，NWConnection 回调也投递到同一 queue）。

nonisolated final class NWDatagramTransport: DatagramTransport, @unchecked Sendable {
    var onReceive: (@Sendable (Bytes) -> Void)?
    var onError: (@Sendable (String) -> Void)?
    private var connection: NWConnection?
    private let wifiOnly: Bool

    init(wifiOnly: Bool = true) { self.wifiOnly = wifiOnly }

    func start(host: String, port: UInt16, queue: DispatchQueue) throws {
        guard let p = NWEndpoint.Port(rawValue: port) else { throw TransportError.socket("无效端口 \(port)") }
        let params = NWParameters.udp
        params.allowLocalEndpointReuse = true
        if wifiOnly { params.requiredInterfaceType = .wifi }
        params.serviceClass = .interactiveVideo
        let c = NWConnection(host: NWEndpoint.Host(host), port: p, using: params)
        c.stateUpdateHandler = { [weak self] state in
            switch state {
            case let .waiting(err):
                self?.onError?("等待网络：\(err.localizedDescription)（请确认已连接相机 Wi-Fi，并已允许「本地网络」权限）")
            case let .failed(err):
                self?.onError?("连接失败：\(err.localizedDescription)")
            default: break
            }
        }
        connection = c
        c.start(queue: queue)
        receiveNext()
    }

    private func receiveNext() {
        guard let c = connection else { return }
        let id = ObjectIdentifier(c)   // 不在 @Sendable 闭包里捕获 NWConnection 本身
        c.receiveMessage { [weak self] data, _, _, error in
            guard let self else { return }
            if let data, !data.isEmpty { self.onReceive?(Bytes(data)) }
            if let error {
                if case .posix(let code) = error, code == .ECANCELED { return }
                self.onError?("接收错误：\(error.localizedDescription)")
                return
            }
            if let cur = self.connection, ObjectIdentifier(cur) == id { self.receiveNext() }
        }
    }

    func send(_ bytes: Bytes) {
        connection?.send(content: Data(bytes), completion: .idempotent)
    }

    func stop() {
        connection?.cancel()
        connection = nil
    }
}
