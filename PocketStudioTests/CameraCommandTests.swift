// CameraCommandTests.swift — 相机/云台命令载荷与状态解析（以实机日志 2026-10-10 11:23 的原始字节为基准）
import XCTest
#if canImport(PocketStudio)
@testable import PocketStudio
#else
@testable import PocketStudioCore
#endif

nonisolated private func hex(_ s: String) -> Bytes { s.split(separator: " ").map { UInt8($0, radix: 16)! } }

nonisolated final class CameraCommandTests: XCTestCase {
    /// 实机日志：RX Camera:0x80 (60B)
    let log80 = hex("01 02 80 00 01 23 99 03 00 95 e0 00 00 00 00 00 00 a8 0f 00 00 00 00 00 00 00 00 00 00 00 00 00 02 46 00 00 01 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 01 00 00")
    /// 实机日志：RX Gimbal:0x05 (49B)
    let log05 = hex("07 fa 00 00 bb fa 00 00 35 f7 00 01 40 fd 1f 00 06 11 00 00 fa 00 07 00 73 85 5e 3e d2 c8 b8 3e 50 1b 67 bf 1b ed b1 3d 00 00 00 00 01 00 00 00 00")
    /// 实机日志：RX Camera:0xDC (22B)
    let logDC = hex("00 12 01 00 00 01 23 99 03 00 95 e0 00 00 00 00 00 00 a8 0f 00 00")

    func pkt(_ set: UInt8, _ id: UInt8, _ p: Bytes) -> DUMLPacket {
        DUML.parse(DUML.build(senderType: 1, senderID: 0, receiverType: 2, receiverID: 0, cmdSet: set, cmdID: id, payload: p, cmdType: 0))[0]
    }

    func testRealCameraStatus() {
        var c = CameraStatus()
        XCTAssertTrue(c.apply(pkt(2, 0x80, log80)))
        XCTAssertFalse(c.recording, "日志里相机未在录制：@0 bit7 = 0")
        XCTAssertEqual(c.mode, .video, "@57 = 0x01 录像")
        XCTAssertTrue(c.sdInserted)
        XCTAssertEqual(c.sdTotalMB, 0x039923)
        XCTAssertEqual(c.sdFreeMB, 0xE095)
        var rec = log80; rec[0] |= 0x80; rec[29] = 75
        XCTAssertTrue(c.apply(pkt(2, 0x80, rec)))
        XCTAssertTrue(c.recording); XCTAssertEqual(c.recordingTimeS, 75)
        var d = CameraStatus()
        XCTAssertTrue(d.apply(pkt(2, 0xDC, logDC))); XCTAssertTrue(d.sdInserted); XCTAssertEqual(d.sdFreeMB, 0xE095)
    }

    func testRealGimbalAttitude() {
        var g = GimbalState()
        g.update(payload: log05)
        XCTAssertEqual(g.yaw, -134.9, accuracy: 0.01)
        XCTAssertEqual(g.pitch, -25.0, accuracy: 0.01, "@20 = +25.0（向下）→ 俯仰 −25°")
        XCTAssertEqual(g.nativePitch, -152.9, accuracy: 0.01)
        XCTAssertEqual(g.mode, .directionLock, "@6 = 0x00")
        var legacy = GimbalState(); legacy.update(payload: log05, legacyLayout: true)
        XCTAssertEqual(legacy.yaw, -152.9, accuracy: 0.01)
    }

    func testCameraCommandPayloads() throws {
        XCTAssertEqual(CameraCommand.takePhoto.cmdID, 0x01); XCTAssertEqual(CameraCommand.takePhoto.payload, [0x01])
        XCTAssertEqual(CameraCommand.startRecording.cmdID, 0x02); XCTAssertEqual(CameraCommand.startRecording.payload, [0x01])
        XCTAssertEqual(CameraCommand.stopRecording.cmdID, 0x02); XCTAssertEqual(CameraCommand.stopRecording.payload, [0x00])
        let photo = try XCTUnwrap(CameraCommand.setMode(.photo))
        XCTAssertEqual(photo.cmdID, 0xE1); XCTAssertEqual(photo.payload, [0x05])
        XCTAssertEqual(CameraCommand.setMode(.video)?.payload, [0x01])
        XCTAssertEqual(CameraCommand.setMode(.slowMotion)?.payload, [0x00])
        XCTAssertEqual(CameraCommand.setMode(.timelapse)?.payload, [0x02])
        let videoMode = try XCTUnwrap(CameraCommand.setMode(.video))
        for spec in [CameraCommand.takePhoto, CameraCommand.startRecording, CameraCommand.stopRecording, videoMode] {
            XCTAssertEqual(spec.cmdType, DUMLCmdType.request, "相机命令必须 flags 0x40")
            let b = DUML.build(senderType: 2, senderID: 0, receiverType: spec.receiverType, receiverID: 0,
                               cmdSet: spec.cmdSet, cmdID: spec.cmdID, payload: spec.payload, cmdType: spec.cmdType)
            XCTAssertEqual(b[8], 0x40)
            XCTAssertEqual(b[5], 0x01, "接收方 Camera(1,0)")
        }
        XCTAssertEqual(CameraCommand.recordCommand(start: true, mode: .video), CameraCommand.startRecording)
        XCTAssertEqual(CameraCommand.recordCommand(start: false, mode: .video), CameraCommand.stopRecording)
        XCTAssertEqual(CameraCommand.recordCommand(start: true, mode: .timelapse), CameraCommand.takePhoto)
        XCTAssertEqual(CameraCommand.recordCommand(start: false, mode: .timelapse), CameraCommand.shutterStop)
        XCTAssertEqual(CameraCommand.describeReply(cmdID: 1, payload: [0xD9]), "当前模式不支持（如在录像模式下拍照）")
        XCTAssertNil(CameraCommand.setMode(.livePhoto), "Pocket 3 不发送未知的实况模式号")
        XCTAssertEqual(CameraCommand.setMode(.photo, profile: .pocket4P)?.payload, [0x17])
        XCTAssertEqual(CameraCommand.setMode(.livePhoto, profile: .pocket4P)?.payload, [0x4D])
        XCTAssertEqual(CameraCommand.setMode(.video, profile: .pocket4P)?.payload, [0x01])
        XCTAssertEqual(CameraCommand.setMode(.slowMotion, profile: .pocket4P)?.payload, [0x00])
        XCTAssertEqual(CameraCommand.setMode(.timelapse, profile: .pocket4P)?.payload, [0x02])
        XCTAssertEqual(CameraCommand.setMode(.photo, profile: .pocket4)?.payload, [0x05], "Pocket 4 模式号未知，复用 Pocket 3")
        XCTAssertNil(CameraCommand.setMode(.livePhoto, profile: .pocket4))
        XCTAssertEqual(Pocket4PSuperPhoto.formatCommand, 0x12)
        XCTAssertEqual(Pocket4PSuperPhoto.superPhoto16x9, [0x04, 0x01])
        XCTAssertEqual(Pocket4PSuperPhoto.shutter, [0x0F])
        XCTAssertFalse(DeviceProfile.pocket4P.modeTable.wire.values.contains(0x12), "SuperPhoto 不是 0xE1 取值，不得当成模式号发送")
        let sent = DeviceProfile.pocket4P.modeTable.wire.values
        XCTAssertEqual(Set(sent).count, sent.count, "模式表里不能有重复的线上取值")
    }

    func testPocket4PStorageDoesNotParseSDFields() {
        var c = CameraStatus()
        XCTAssertTrue(c.apply(pkt(2, 0x80, log80), profile: .pocket4P))
        XCTAssertFalse(c.sdInserted)
        XCTAssertEqual(c.sdTotalMB, 0)
        XCTAssertEqual(c.sdFreeMB, 0)
        XCTAssertEqual(c.mode, .video, "@57 = 0x01 在 4P 表里仍是录像")
        var photo = log80; photo[57] = 0x17
        XCTAssertTrue(c.apply(pkt(2, 0x80, photo), profile: .pocket4P))
        XCTAssertEqual(c.mode, .photo)
        var live = log80; live[57] = 0x4D
        XCTAssertTrue(c.apply(pkt(2, 0x80, live), profile: .pocket4P))
        XCTAssertEqual(c.mode, .livePhoto)
        var plain = CameraStatus()
        XCTAssertTrue(plain.apply(pkt(2, 0x80, photo)))
        XCTAssertNil(plain.mode, "0x17 不是 Pocket 3 的拍照")
        XCTAssertTrue(plain.sdInserted, "Pocket 3 仍解析 SD 字段")
        var storage = CameraStatus()
        XCTAssertTrue(storage.apply(pkt(2, 0xDC, logDC), profile: .pocket4P))
        XCTAssertFalse(storage.hasStorageStatus)
        XCTAssertFalse(storage.sdInserted)
        XCTAssertFalse(storage.rawDC.isEmpty)
    }

    func testGimbalCommandPayloads() {
        XCTAssertEqual(GimbalProtocol.recenterPayload, [0xFE, 0x08])
        XCTAssertEqual(GimbalProtocol.flipPayload, [0xFE, 0x09])
        XCTAssertEqual(GimbalProtocol.setModePayload(.follow), [0x02, 0x08])
        XCTAssertEqual(GimbalProtocol.setModePayload(.fpv), [0x01, 0x08])
        XCTAssertEqual(GimbalProtocol.setModePayload(.directionLock), [0x00, 0x08])
        XCTAssertEqual(GimbalProtocol.speedSettingPayload(.slow), [0x00, 0x05, 0x01, 0x02])
    }

    func testRecenterSendsStopThen4C() {
        var sent: [DUMLPacket] = []
        let core = DJISessionCore(sessionID: 1) { _ in }
        core.onDUML = { p, d in if d == .tx { sent.append(p) } }
        core.recenterGimbal()
        XCTAssertEqual(sent.map(\.cmdID), [0x01, 0x14, 0x4C])
        XCTAssertEqual(sent[0].payload.le16(0), 1024); XCTAssertEqual(sent[0].payload.le16(4), 1024)
        XCTAssertEqual(sent[2].payload, [0xFE, 0x08]); XCTAssertEqual(sent[2].cmdType, DUMLCmdType.request)
        XCTAssertFalse(sent.contains { $0.cmdID == 0x14 && $0.payload.count == 8 && $0.payload[7] > 1 }, "不得再发 25.5s 的定时移动")
    }

    func testGimbalReadinessGate() {
        var t = 100.0
        var sent: [DUMLPacket] = []
        let core = DJISessionCore(sessionID: 1) { _ in }
        core.clock = { t }
        core.onDUML = { p, d in if d == .tx { sent.append(p) } }
        core.startVideo()
        XCTAssertEqual(sent.filter { $0.cmdID == 0xDA }.count, 1)
        sent = []
        core.setGimbalSpeed(yaw: 1, pitch: 0)
        core.tickGimbal()
        XCTAssertFalse(sent.contains { $0.cmdID == 1 && $0.payload.le16(4) != 1024 }, "未就绪不得发非零速度")
        core.noteGimbalAttitude()          // 姿态到了，但距视频启动不足 0.6s
        XCTAssertFalse(core.gimbalReady)
        t += 0.7; core.tickGimbal()
        XCTAssertTrue(core.gimbalReady)
        sent = []
        core.setGimbalSpeed(yaw: 1, pitch: 0)
        t += 0.05; core.tickGimbal()          // 速度由限速 tick 合并发送
        XCTAssertTrue(sent.contains { $0.cmdID == 1 && $0.payload.le16(4) == 2048 })
    }

    func testGimbalReadinessFallback() {
        var t = 0.0
        var sent: [DUMLPacket] = []
        let core = DJISessionCore(sessionID: 1) { _ in }
        core.clock = { t }
        core.onDUML = { p, d in if d == .tx { sent.append(p) } }
        core.startVideo()
        for _ in 0 ..< 45 { t += 0.1; core.tickGimbal() }
        XCTAssertTrue(core.gimbalReady, "4s 无姿态也要放行")
        XCTAssertGreaterThanOrEqual(sent.filter { $0.cmdID == 0xDA }.count, 3, "期间应补发初始化")
    }
}

/// 冻结修复：ACK 窗口游标 + 命令头 + 视频看门狗
nonisolated final class LinkRecoveryTests: XCTestCase {
    func ack(_ core: DJISessionCore) -> (UInt16, UInt16, UInt16) {
        let b = core.makeAck()
        return (b.le16(8), b.le16(16), b.le16(24))
    }

    /// 相机 seq 在我们随机种子「后面」时，旧实现的游标永远不前进 → 窗口卡死
    func testCursorsAdoptCameraSeqEvenIfBehindSeed() {
        let core = DJISessionCore(sessionID: 1) { _ in }
        _ = core.makeHandshake(seed: 0x9000)
        core.handle(datagram: DJIUDPFrame.header(length: 0, sessionID: 1, seq: 0x1000, type: DJIUDPType.video) + Bytes(repeating: 0, count: 13))
        core.handle(datagram: DJIUDPFrame.header(length: 8, sessionID: 1, seq: 0x2000, type: DJIUDPType.ackTelemetry))
        var (v, r, x) = ack(core)
        XCTAssertEqual(v, 0x1000); XCTAssertEqual(r, 0x2000); XCTAssertEqual(x, 0x9000, "组 2 无遥测时用 baseSeq")
        // 之后只前进，不倒退
        core.handle(datagram: DJIUDPFrame.header(length: 8, sessionID: 1, seq: 0x1FF8, type: DJIUDPType.ackTelemetry))
        core.handle(datagram: DJIUDPFrame.header(length: 8, sessionID: 1, seq: 0x2008, type: DJIUDPType.ackTelemetry))
        (v, r, x) = ack(core)
        XCTAssertEqual(r, 0x2008)
        // 发很多命令后组 2 不能跟着 cmdSeq 跑
        for _ in 0 ..< 5000 { core.sendReq(receiverType: 4, receiverID: 0, cmdSet: 4, cmdID: 1, payload: [0]) }
        XCTAssertEqual(ack(core).2, 0x9000)
        // 重新握手：游标回到「未同步」，再次采用相机值
        _ = core.makeHandshake(seed: 0x5000)
        core.handle(datagram: DJIUDPFrame.header(length: 8, sessionID: 1, seq: 0x0100, type: DJIUDPType.ackTelemetry))
        XCTAssertEqual(ack(core).1, 0x0100)
    }

    func testTelemetry34SeedsWindows() {
        let core = DJISessionCore(sessionID: 1) { _ in }
        _ = core.makeHandshake(seed: 0x9000)
        var t = DJIUDPFrame.header(length: 34, sessionID: 1, seq: 0, type: DJIUDPType.telemetry) + Bytes(repeating: 0, count: 26)
        t[18] = 0x40; t[19] = 0x12; t[26] = 0x80; t[27] = 0x33
        core.handle(datagram: t)
        XCTAssertEqual(ack(core).1, 0x1240); XCTAssertEqual(ack(core).2, 0x3380)
    }

    func testRoutingHeaderPocketLayout() {
        let p = DJIUDPFrame.commandPacket(sessionID: 1, seq: 0x100, msgSeq: 3, duml: [0x55])
        XCTAssertEqual(Array(p[8 ..< 20]), [0xF8, 0x00, 0x00, 0x01, 0, 0, 0, 0, 3, 0x01, 0x00, 0x00])
        let l = DJIUDPFrame.commandPacket(sessionID: 1, seq: 0x100, msgSeq: 3, duml: [0x55], legacy: true)
        XCTAssertEqual(Array(l[8 ..< 20]), [0xE0, 0x00, 0x00, 0x01, 0, 0, 0, 0, 3, 0x01, 0x60, 0x00])
    }

    func testRequestKeyframeAndReRegister() {
        var sent: [DUMLPacket] = []
        let core = DJISessionCore(sessionID: 1) { _ in }
        core.onDUML = { p, d in if d == .tx { sent.append(p) } }
        core.requestKeyframe(); core.reRegister()
        XCTAssertEqual(sent[0].cmdSet, 0x09); XCTAssertEqual(sent[0].cmdID, 0xA8); XCTAssertEqual(sent[0].receiverType, 8)
        XCTAssertEqual(sent[0].cmdType, DUMLCmdType.request)
        XCTAssertEqual(sent[1].cmdSet, 2); XCTAssertEqual(sent[1].cmdID, 0xB3)
        XCTAssertEqual(sent[1].receiverType, DUMLDevice.camera); XCTAssertEqual(sent[1].receiverID, 0)
        XCTAssertEqual(sent[1].payload, [])
        XCTAssertEqual(sent[1].cmdType, DUMLCmdType.request)
        XCTAssertEqual(sent.dropFirst(2).map(\.cmdID), [0x88, 0x81, 0x82])
    }

    private func ev(_ m: inout VideoHealthMonitor, _ now: Double, v: Double?, d: Double?, t: Double?, r: Double? = nil, busy: Bool = false) -> VideoRecoveryAction {
        m.evaluate(VideoHealthInput(now: now, connectedAt: 0, lastVideoPacket: v, lastDecoded: d, lastTelemetry: t, lastReply: r, cameraBusy: busy))
    }

    /// 13:33:54 日志场景：丢包解码失败，但视频 546 片段/s、应答 12/s → 只能重建解码器，绝不能动链路
    func testWatchdogNeverTouchesLinkWhileVideoFlows() {
        var m = VideoHealthMonitor()
        XCTAssertEqual(ev(&m, 1, v: nil, d: nil, t: 1), .none) // 宽限期
        XCTAssertEqual(ev(&m, 12, v: 11.9, d: 10, t: 12, r: 12), .resetDecoder)
        for t in stride(from: 13.0, to: 60, by: 0.5) {
            let a = ev(&m, t, v: t - 0.05, d: 10, t: t, r: t)
            XCTAssertTrue(a == .none || a == .resetDecoder, "t=\(t) \(a)")
        }
        XCTAssertEqual(ev(&m, 61, v: 61, d: 61, t: 61, r: 61), .recovered)
    }

    /// 13:35:04 日志场景：拍照后相机进入回放（忙），视频与应答都停 → 只等待，不重建
    func testWatchdogWaitsWhileCameraBusy() {
        var m = VideoHealthMonitor()
        XCTAssertEqual(ev(&m, 10, v: 7, d: 7, t: 10, r: 5, busy: true), .waitCameraBusy)
        XCTAssertEqual(ev(&m, 20, v: 7, d: 7, t: 20, r: 5, busy: true), .none)
        XCTAssertEqual(ev(&m, 21, v: 21, d: 21, t: 21, r: 21), .recovered)
    }

    /// 视频停 + 应答也停 → 重新注册 → 4s 后仍无 → 重建（只请求一次，之后交给 ReconnectPolicy）
    func testWatchdogEscalatesToRebuildOnce() {
        var m = VideoHealthMonitor()
        XCTAssertEqual(ev(&m, 10, v: 7, d: 7, t: 10, r: 7), .reRegister)
        XCTAssertEqual(ev(&m, 12, v: 7, d: 7, t: 12, r: 7), .none)
        XCTAssertEqual(ev(&m, 14.1, v: 7, d: 7, t: 14.1, r: 7), .commandStall)
        XCTAssertEqual(ev(&m, 30, v: 7, d: 7, t: 30, r: 7), .none)
        // 相机仍应答命令 → 只定期重新注册，不重建
        var n = VideoHealthMonitor()
        XCTAssertEqual(ev(&n, 10, v: 7, d: 7, t: 10, r: 10), .reRegister)
        XCTAssertEqual(ev(&n, 15, v: 7, d: 7, t: 15, r: 15), .none)
        XCTAssertEqual(ev(&n, 16.1, v: 7, d: 7, t: 16.1, r: 16), .reRegister)
        // 遥测也停 → linkLost 只报一次
        var k = VideoHealthMonitor()
        XCTAssertEqual(ev(&k, 40, v: 30, d: 30, t: 30), .linkLost)
        XCTAssertEqual(ev(&k, 41, v: 30, d: 30, t: 30), .none)
    }

    /// 13:51 日志：视频仍在（30fps）但命令应答停止 → 6s 判定命令通道卡死，只报一次
    func testCommandStallDetectedWhileVideoFlows() {
        var m = VideoHealthMonitor()
        XCTAssertEqual(ev(&m, 10, v: 10, d: 10, t: 10, r: 9), .none)
        XCTAssertEqual(ev(&m, 14, v: 14, d: 14, t: 14, r: 9), .none)
        XCTAssertEqual(ev(&m, 15.1, v: 15, d: 15, t: 15, r: 9), .commandStall)
        XCTAssertEqual(ev(&m, 17, v: 17, d: 17, t: 17, r: 9), .none)
        // 相机忙（回放）时不判卡死
        var n = VideoHealthMonitor()
        XCTAssertEqual(ev(&n, 20, v: 20, d: 20, t: 20, r: 9, busy: true), .none)
    }

    func testReconnectPolicyBackoff() {
        var p = ReconnectPolicy()
        XCTAssertEqual(p.next()?.level, .fullReconnect)   // 13:51 日志：UDP 重建 0/5，蓝牙唤醒 5/5
        XCTAssertGreaterThanOrEqual(p.next()!.delay, 1.0)
        p.recordFailure()
        XCTAssertEqual(p.next()?.level, .fullReconnect)
        var last = 0.0
        while let n = p.next() { XCTAssertGreaterThanOrEqual(n.delay, last); last = n.delay; p.recordFailure() }
        XCTAssertEqual(p.failures, p.maxAttempts)
        p.reset(); XCTAssertNotNil(p.next())
    }

    func testShutterFollowsMode() {
        XCTAssertEqual(Shutter.action(mode: .photo, recording: false), .takePhoto)
        XCTAssertEqual(Shutter.action(mode: .video, recording: false), .startRecording)
        XCTAssertEqual(Shutter.action(mode: .video, recording: true), .stopRecording)
        XCTAssertEqual(Shutter.action(mode: .photo, recording: true), .stopRecording)
        XCTAssertEqual(Shutter.style(mode: .photo, recording: false), .photo)
        XCTAssertEqual(Shutter.style(mode: .slowMotion, recording: false), .record(symbol: "slowmo"))
        XCTAssertEqual(Shutter.style(mode: .timelapse, recording: true), .stop)
        XCTAssertEqual(Shutter.segments, [.slowMotion, .video, .photo, .timelapse])
    }

    func testCaptureModeOptimisticThenReconcile() {
        var s = CaptureModeState()
        s.report(.video, now: 0)
        s.request(.photo, now: 1)
        XCTAssertEqual(s.displayed, .photo)       // 乐观
        s.report(.video, now: 1.5)                 // 旧状态推送还没变
        XCTAssertEqual(s.displayed, .photo)
        s.report(.photo, now: 2)                   // 确认
        XCTAssertNil(s.pending); XCTAssertEqual(s.displayed, .photo)
        s.request(.timelapse, now: 3); s.ack(success: false)
        XCTAssertEqual(s.displayed, .photo)        // 失败回退
        s.request(.slowMotion, now: 4); s.tick(now: 8)
        XCTAssertEqual(s.displayed, .photo)        // 超时回到相机报告值
    }

    func testPlaybackFlagAndExitCommand() {
        var c = CameraStatus()
        var p = Bytes(repeating: 0, count: 60)
        p[1] = 0x02; p[2] = 0x80; p[3] = 0x40; p[57] = 0x05
        _ = c.apply(DUML.parse(DUML.build(senderType: 1, senderID: 0, receiverType: 2, receiverID: 0, cmdSet: 2, cmdID: 0x80, payload: p, seq: 1, cmdType: 0))[0])
        XCTAssertTrue(c.inPlayback); XCTAssertEqual(c.mode, .photo)
        p[3] = 0; _ = c.apply(DUML.parse(DUML.build(senderType: 1, senderID: 0, receiverType: 2, receiverID: 0, cmdSet: 2, cmdID: 0x80, payload: p, seq: 1, cmdType: 0))[0])
        XCTAssertFalse(c.inPlayback)
        XCTAssertEqual(CameraCommand.exitPlayback.cmdID, 0x0C)
        XCTAssertEqual(CameraCommand.exitPlayback.payload, [1, 1, 0, 0])
    }

    func testTCPPokeFrame() throws {
        let f = DJITCPPoke.frame
        let pk = try XCTUnwrap(DUML.parse(f).first)
        XCTAssertEqual(pk.cmdSet, 0x07); XCTAssertEqual(pk.cmdID, 0x45); XCTAssertEqual(pk.receiverType, 0x07)
        XCTAssertEqual(pk.cmdType, DUMLCmdType.request)
        XCTAssertEqual(Array(pk.payload.suffix(5)), [4] + Array("mbln".utf8))
    }
}
