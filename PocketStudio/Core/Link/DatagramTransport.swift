// DatagramTransport.swift — UDP 传输抽象 + BSD socket 实现（平台无关：macOS / Linux 均可编译）
//
// macOS 默认使用 Network.framework 实现（Platform/NWDatagramTransport.swift）。
// BSD 实现作为「兼容模式」：与原 Python 版完全相同的 sendto/recvfrom 语义，
// 接收来自任何源端口的数据报（若相机从其他端口回包也能收到）。

import Foundation
import Dispatch
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

nonisolated public protocol DatagramTransport: AnyObject, Sendable {
    /// 收到数据报（在 start 传入的 queue 上回调）
    var onReceive: (@Sendable (Bytes) -> Void)? { get set }
    /// 传输错误或状态说明（在 queue 上回调）
    var onError: (@Sendable (String) -> Void)? { get set }
    func start(host: String, port: UInt16, queue: DispatchQueue) throws
    func send(_ bytes: Bytes)
    func stop()
}

nonisolated public enum TransportError: Error, Sendable, CustomStringConvertible {
    case socket(String)
    public var description: String { switch self { case let .socket(s): return s } }
}

nonisolated public final class BSDDatagramTransport: DatagramTransport, @unchecked Sendable {
    public var onReceive: (@Sendable (Bytes) -> Void)?
    public var onError: (@Sendable (String) -> Void)?
    private var fd: Int32 = -1
    private var addr = sockaddr_in()
    private let lock = NSLock()
    private var running = false
    private var thread: Thread?

    public init() {}

    public func start(host: String, port: UInt16, queue: DispatchQueue) throws {
        #if os(Linux)
        let s = socket(AF_INET, Int32(SOCK_DGRAM.rawValue), 0)
        #else
        let s = socket(AF_INET, SOCK_DGRAM, 0)
        #endif
        guard s >= 0 else { throw TransportError.socket("socket() 失败：errno \(errno)") }
        var rcv: Int32 = 1024 * 1024
        _ = setsockopt(s, SOL_SOCKET, SO_RCVBUF, &rcv, socklen_t(MemoryLayout<Int32>.size))
        var tv = timeval(tv_sec: 0, tv_usec: 500_000)
        _ = setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var a = sockaddr_in()
        #if !os(Linux)
        a.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        #endif
        a.sin_family = sa_family_t(AF_INET)
        a.sin_port = port.bigEndian
        guard inet_pton(AF_INET, host, &a.sin_addr) == 1 else {
            close(s); throw TransportError.socket("无效的 IP 地址：\(host)")
        }
        lock.lock(); fd = s; addr = a; running = true; lock.unlock()

        let t = Thread { [weak self] in self?.receiveLoop(fd: s, queue: queue) }
        t.name = "pocketstudio.udp.rx"
        t.qualityOfService = .userInteractive
        thread = t
        t.start()
    }

    private func isRunning() -> Bool { lock.lock(); defer { lock.unlock() }; return running }

    private func receiveLoop(fd s: Int32, queue: DispatchQueue) {
        var buf = Bytes(repeating: 0, count: 65536)
        while isRunning() {
            let n = buf.withUnsafeMutableBytes { recv(s, $0.baseAddress, 65536, 0) }
            if n > 0 {
                let d = Array(buf[0 ..< n])
                queue.async { [weak self] in self?.onReceive?(d) }
            } else if n < 0 {
                let e = errno
                if e == EAGAIN || e == EWOULDBLOCK || e == EINTR { continue }
                if isRunning() { queue.async { [weak self] in self?.onError?("recv 错误：errno \(e)") } }
                break
            }
        }
    }

    public func send(_ bytes: Bytes) {
        lock.lock(); let s = fd; var a = addr; lock.unlock()
        guard s >= 0 else { return }
        _ = bytes.withUnsafeBytes { raw in
            withUnsafePointer(to: &a) { p in
                p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(s, raw.baseAddress, raw.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
    }

    public func stop() {
        lock.lock(); running = false; let s = fd; fd = -1; lock.unlock()
        if s >= 0 { close(s) }
        thread = nil
    }

    deinit { stop() }
}
