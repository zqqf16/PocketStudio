// CameraLinkLoopbackTests.swift — 用本机回环上的「假相机」端到端测试 CameraLink + BSD 传输
import XCTest
import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif
#if canImport(PocketStudio)
@testable import PocketStudio
#else
@testable import PocketStudioCore
#endif

/// 极简假相机：绑定 127.0.0.1:port（传 0 让内核分配端口，避免并行测试抢端口），记录收到的包与到达时刻，回握手，并向客户端推送视频/遥测
nonisolated final class FakeCamera: @unchecked Sendable {
    let fd: Int32
    /// 实际绑定端口（init 传 0 时由内核分配）
    let port: UInt16
    /// 是否应答握手（关掉后用于测试「握手进行中 stop()」）
    let respondsToHandshake: Bool
    var peer = sockaddr_in()
    var received: [Bytes] = []
    var receivedAt: [Double] = []
    let lock = NSLock()
    var running = true
    init(port: UInt16 = 0, respondsToHandshake: Bool = true) {
        let fd: Int32
        #if os(Linux)
        fd = socket(AF_INET, Int32(SOCK_DGRAM.rawValue), 0)
        #else
        fd = socket(AF_INET, SOCK_DGRAM, 0)
        #endif
        var a = sockaddr_in()
        #if !os(Linux)
        a.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        #endif
        a.sin_family = sa_family_t(AF_INET); a.sin_port = port.bigEndian
        inet_pton(AF_INET, "127.0.0.1", &a.sin_addr)
        _ = withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        var bound = sockaddr_in(); var blen = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &bound) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &blen) } }
        self.fd = fd
        self.respondsToHandshake = respondsToHandshake
        self.port = UInt16(bigEndian: bound.sin_port)
        var tv = timeval(tv_sec: 0, tv_usec: 200_000)
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        Thread { self.loop() }.start()
    }
    func send(_ b: Bytes) {
        lock.lock(); var p = peer; lock.unlock()
        _ = b.withUnsafeBytes { raw in withUnsafePointer(to: &p) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            sendto(fd, raw.baseAddress, raw.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } } }
    }
    func loop() {
        var buf = Bytes(repeating: 0, count: 65536)
        while running {
            var from = sockaddr_in(); var len = socklen_t(MemoryLayout<sockaddr_in>.size)
            let n = buf.withUnsafeMutableBytes { raw in withUnsafeMutablePointer(to: &from) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                recvfrom(fd, raw.baseAddress, 65536, 0, $0, &len) } } }
            guard n > 0 else { continue }
            let d = Array(buf[0 ..< n])
            lock.lock(); peer = from; received.append(d); receivedAt.append(ProcessInfo.processInfo.systemUptime); lock.unlock()
            if respondsToHandshake, let h = DJIUDPFrame.parse(d), h.type == DJIUDPType.handshake {
                send(DJIUDPFrame.header(length: 9, sessionID: 0xABCD, seq: 0, type: 0) + [0])
            }
        }
    }
    func packets() -> [Bytes] { lock.lock(); defer { lock.unlock() }; return received }
    func arrivals() -> [Double] { lock.lock(); defer { lock.unlock() }; return receivedAt }
    deinit { running = false; close(fd) }
}

/// 线程安全小盒子（测试中在回调里累积数据）
nonisolated final class Locked<T>: @unchecked Sendable {
    private var v: T; private let l = NSLock()
    init(_ v: T) { self.v = v }
    func with<R>(_ f: (inout T) -> R) -> R { l.lock(); defer { l.unlock() }; return f(&v) }
    var value: T { with { $0 } }
}

nonisolated final class CameraLinkLoopbackTests: XCTestCase {
    func testEndToEnd() throws {
        let cam = FakeCamera(port: 0)
        let link = CameraLink(host: "127.0.0.1", port: cam.port, transport: BSDDatagramTransport())
        let videoGot = expectation(description: "video")
        let video = Locked(Bytes())
        link.onVideo = { b in if video.with({ $0 += b; return $0.count }) >= 5 { videoGot.fulfill() } }
        let snap = Locked<LinkSnapshot?>(nil)
        link.onSnapshot = { s in snap.with { $0 = s } }
        let hs = expectation(description: "hs")
        link.connect(timeout: 3) { r in if case .success = r { hs.fulfill() } else { XCTFail("\(r)") } }
        wait(for: [hs], timeout: 5)

        cam.send(DJIUDPFrame.header(length: 0, sessionID: 0xABCD, seq: 0x10, type: 2) + Bytes(repeating: 0, count: 12) + [0, 0, 0, 1, 0x65])
        var p80 = Bytes(repeating: 0, count: 60); p80[0] = 0x80; p80[57] = 1
        let d = DUML.build(senderType: 1, senderID: 0, receiverType: 2, receiverID: 0, cmdSet: 2, cmdID: 0x80, payload: p80, cmdType: 2)
        cam.send(DJIUDPFrame.header(length: 8 + d.count, sessionID: 0xABCD, seq: 1, type: 1) + d)
        wait(for: [videoGot], timeout: 3)
        // 就绪门控：收到首个云台姿态且视频启动 ≥0.6s 后才放行非零速度
        let att = DUML.build(senderType: 4, senderID: 0, receiverType: 2, receiverID: 0, cmdSet: 4, cmdID: 5, payload: Bytes(repeating: 0, count: 49), cmdType: 0)
        cam.send(DJIUDPFrame.header(length: 8 + att.count, sessionID: 0xABCD, seq: 2, type: 1) + att)
        Thread.sleep(forTimeInterval: 1.2)
        XCTAssertEqual(link.currentSnapshot().gimbalReady, true)
        link.setGimbalSpeed(yaw: 1, pitch: 0)
        link.takePhoto()
        Thread.sleep(forTimeInterval: 1.0)
        link.stop()

        let pk = cam.packets().compactMap(DJIUDPFrame.parse)
        let acks = pk.filter { $0.type == DJIUDPType.ack }
        XCTAssertGreaterThan(acks.count, 20, "ACK 应约 50Hz")
        XCTAssertTrue(acks.allSatisfy { $0.sessionID == 0xABCD }, "握手后应采用相机 session")
        let duml = pk.filter { $0.type == DJIUDPType.command }.flatMap { DUML.parse($0.body) }
        XCTAssertTrue(duml.contains { $0.cmdSet == 0 && $0.cmdID == 0x0E && $0.payload.isEmpty && $0.cmdType == DUMLCmdType.request }, "链路心跳 0x0E")
        XCTAssertFalse(duml.contains { $0.cmdSet == 0 && $0.cmdID == 0x4F }, "默认不发版本配置 0x4F")
        XCTAssertTrue(duml.contains { $0.cmdSet == 0 && $0.cmdID == 0x81 && $0.cmdType == 4 }, "DM368 注册")
        XCTAssertTrue(duml.contains { $0.cmdSet == 2 && $0.cmdID == 0x8E }, "相机心跳")
        XCTAssertTrue(duml.contains { $0.cmdSet == 2 && $0.cmdID == 0x01 && $0.payload == [1] && $0.cmdType == DUMLCmdType.request }, "拍照 = 0x02/0x01 [01] flags 0x40")
        XCTAssertTrue(duml.contains { $0.cmdSet == 3 && $0.cmdID == 0xDA && $0.receiverType == 3 }, "云台初始化 0x03/0xDA")
        let gimbalPk = duml.filter { $0.cmdSet == 4 && $0.cmdID == 1 }
        XCTAssertTrue(gimbalPk.contains { $0.payload.le16(4) == 2048 && $0.payload.le16(0) == 1024 }, "yaw 满速写在第 3 个字段")
        XCTAssertEqual(gimbalPk.last?.payload.le16(0), 1024, "看门狗/断开后最后一包必须是零速")
        XCTAssertEqual(gimbalPk.last?.payload.le16(4), 1024)
        XCTAssertEqual(video.value, [0, 0, 0, 1, 0x65])
        XCTAssertEqual(snap.value?.camera.recording, true)
        XCTAssertEqual(snap.value?.sessionID, 0xABCD)
    }

    /// 握手进行中 stop()：必须以 .cancelled 立即收敛续体。
    /// 修复前 stop() 只把 handshakeCompletion 置 nil 并取消超时定时器 → withCheckedContinuation 永久悬挂（任务泄漏）。
    func testStopDuringHandshakeResumesCancelled() {
        let cam = FakeCamera(port: 0, respondsToHandshake: false)
        let link = CameraLink(host: "127.0.0.1", port: cam.port, transport: BSDDatagramTransport())
        let done = expectation(description: "握手以取消收敛")
        let err = Locked<LinkError?>(nil)
        link.connect(timeout: 10) { r in
            if case let .failure(e) = r { err.with { $0 = e } }
            done.fulfill()   // 二次 resume 会因 over-fulfill 直接失败
        }
        Thread.sleep(forTimeInterval: 0.3)   // 确保握手已发出并在等待
        link.stop()
        wait(for: [done], timeout: 3)        // 远小于 10s 超时：只能来自 stop() 的 resume
        XCTAssertEqual(err.value, .cancelled)
    }

    /// 用户命令统一限速 ≥300ms：快门 + 录制开关连点也不能形成突发（§5d：突发会让相机可靠通道卡死且不自愈）。
    /// 修复前 toggleRecording 直发，紧跟快门后可以 0 间隔冲到相机。
    func testUserCommandsAreRateLimited() {
        let cam = FakeCamera(port: 0)
        let link = CameraLink(host: "127.0.0.1", port: cam.port, transport: BSDDatagramTransport())
        let hs = expectation(description: "hs")
        link.connect(timeout: 3) { r in if case .success = r { hs.fulfill() } else { XCTFail("\(r)") } }
        wait(for: [hs], timeout: 5)

        link.takePhoto()
        link.toggleRecording()
        link.startRecording()
        Thread.sleep(forTimeInterval: 1.5)    // 3 条命令按 300ms 排布，1.5s 足够全部送达
        link.stop()

        let pk = cam.packets()
        let arrivals = cam.arrivals()
        XCTAssertEqual(pk.count, arrivals.count)
        var photoAt: Double?
        var recAt: [Double] = []
        for (i, d) in pk.enumerated() {
            guard let h = DJIUDPFrame.parse(d), h.type == DJIUDPType.command else { continue }
            for p in DUML.parse(h.body) {
                if p.cmdSet == 2, p.cmdID == 0x01 { photoAt = arrivals[i] }
                if p.cmdSet == 2, p.cmdID == 0x02 { recAt.append(arrivals[i]) }
            }
        }
        guard let photoAt else { return XCTFail("没有收到拍照命令") }
        XCTAssertEqual(recAt.count, 2, "toggleRecording（开始）+ startRecording 两条录制命令都应在限速后送达")
        let gaps = [recAt[0] - photoAt, recAt[1] - recAt[0]]
        for g in gaps { XCTAssertGreaterThanOrEqual(g, 0.25, "相邻用户命令间隔应 ≥300ms（实测 \(g)s）") }
    }
}
