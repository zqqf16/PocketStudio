// TCPPoke.swift — TCP 7001 SetPairingPIN「戳一下」（OpenPocketCine DatalinkDriver.poke7001 的移植）
// Pocket 系列：UDP 握手前在 TCP 7001 发送 SetPairingPIN，并在整个会话中保持连接、持续读掉相机写来的 0x21/0x06 帧。
// 失败不致命（原 Python 项目没有这一步也能连），只记日志。
import Foundation
import Network

@MainActor
final class TCPPoke {
    private var conn: NWConnection?
    private(set) var isReady = false
    private let queue = DispatchQueue(label: "pocketstudio.tcp7001")

    /// 已就绪则复用（OPC：第二次连接再开 TCP 会 RST 相机仍持有的那条）
    func ensure(host: String, pin: String = DJIBLE.pairPIN) async -> Bool {
        if isReady, let c = conn, c.state == .ready { return true }
        close()
        for _ in 1 ... 3 {
            if await once(host: host, pin: pin) { return true }
            close()
            try? await Task.sleep(nanoseconds: 350_000_000)
        }
        return false
    }

    private func once(host: String, pin: String) async -> Bool {
        let p = NWParameters.tcp
        p.requiredInterfaceType = .wifi
        let c = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: DJITCPPoke.port)!, using: p)
        conn = c
        let ok: Bool = await withCheckedContinuation { cont in
            let once = OnceFlag()
            c.stateUpdateHandler = { st in
                switch st {
                case .ready: if once.fire() { cont.resume(returning: true) }
                case .failed, .cancelled: if once.fire() { cont.resume(returning: false) }
                default: break
                }
            }
            c.start(queue: queue)
            queue.asyncAfter(deadline: .now() + 2) { if once.fire() { cont.resume(returning: false) } }
        }
        guard ok else { return false }
        c.send(content: Data(DJITCPPoke.frame(pin: pin)), completion: .idempotent)
        try? await Task.sleep(nanoseconds: 400_000_000)
        guard c.state == .ready else { return false }
        Self.drain(c)
        isReady = true
        return true
    }

    nonisolated private static func drain(_ c: NWConnection) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { _, _, complete, error in
            guard !complete, error == nil else { return }
            drain(c)
        }
    }

    func close() {
        conn?.stateUpdateHandler = nil
        conn?.cancel(); conn = nil; isReady = false
    }
}

nonisolated private final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock(); private var done = false
    func fire() -> Bool { lock.lock(); defer { lock.unlock() }; if done { return false }; done = true; return true }
}
