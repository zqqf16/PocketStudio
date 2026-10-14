// CoreProtocolTests.swift — 平台无关协议层单元测试
// 参考向量由原 Python 项目 (sniffingpickles/DJI-Wifi-Connect) 直接生成，确保逐字节一致。
// Xcode 中作为 PocketStudioTests 运行；Linux 上通过 Tools/run-linux-tests.sh 运行。

import XCTest
#if canImport(PocketStudio)
@testable import PocketStudio
#else
@testable import PocketStudioCore
#endif

nonisolated final class CoreProtocolTests: XCTestCase {
    func hex(_ s: String) -> Bytes { Bytes(hexString: s)! }

    func testCRC() {
        let d = Array("123456789".utf8)
        XCTAssertEqual(DJICRC.crc8(d), 0xFB)
        XCTAssertEqual(DJICRC.crc16(d), 0x7109)
    }

    func testDUMLBuildMatchesPython() {
        // 与原 Python 包一致的字节：第一个字段 0.3 → 0x0533
        let p = GimbalProtocol.controlPayload(first: 0.3, third: 0)
        let b = DUML.build(senderType: 2, senderID: 0, receiverType: 4, receiverID: 0, cmdSet: 4, cmdID: 1, payload: p, seq: 0x1238)
        XCTAssertEqual(b.hexString(), "551704380204381200040133050000000400804200ede4")
        let w = DUML.build(senderType: 2, senderID: 0, receiverType: 8, receiverID: 2, cmdSet: 0, cmdID: 0x82, payload: [0], seq: 8, cmdType: DUMLCmdType.write)
        XCTAssertEqual(w.hexString(), "550e046602480800800082004bf0")
    }

    func testDUMLParseRoundTripWithGarbage() {
        let a = DUML.build(senderType: 1, senderID: 0, receiverType: 2, receiverID: 0, cmdSet: 2, cmdID: 0x80, payload: Bytes(repeating: 0x11, count: 60), seq: 7, cmdType: DUMLCmdType.request)
        let b = DUML.build(senderType: 4, senderID: 0, receiverType: 2, receiverID: 0, cmdSet: 4, cmdID: 5, payload: [1, 2, 3, 4, 5, 6], seq: 9)
        var corrupt = b; corrupt[12] ^= 0xFF
        let stream: Bytes = [0x00, 0x55, 0x99] + a + [0x55] + corrupt + b + [0x01]
        let pk = DUML.parse(stream)
        XCTAssertEqual(pk.count, 2)
        XCTAssertEqual(pk[0].cmdID, 0x80); XCTAssertEqual(pk[0].cmdType, DUMLCmdType.request); XCTAssertEqual(pk[0].seq, 7)
        XCTAssertEqual(pk[0].payload.count, 60)
        XCTAssertEqual(pk[1].senderType, 4); XCTAssertEqual(pk[1].payload, [1, 2, 3, 4, 5, 6])
    }

    func testBLEMessage() throws {
        let m = DJIBLE.build(DJIBLE.pairMessage)
        XCTAssertEqual(m.hexString(), "553304c202079280400745203238346165356238643736623333373561303461363431376164373162656133046d626c6ece5a")
        let p = try DJIBLE.parse(m)
        XCTAssertEqual(p, DJIBLE.pairMessage)
        XCTAssertEqual(DJIBLE.build(target: 0x0802, id: 0x8C2C, type: 0x780840, payload: [0x78]).hexString(), "550e046602082c8c4008787848dc")
        var bad = m; bad[20] ^= 1
        XCTAssertThrowsError(try DJIBLE.parse(bad))
        XCTAssertEqual(DJIBLE.identify(manufacturerData: [0xAA, 0x08, 0x20, 0x00, 0x01]).model, "OsmoPocket3")
        XCTAssertEqual(DJIBLE.identify(manufacturerData: [0xAA, 0x08, 0x21, 0x00]).model, "OsmoPocket4")
        XCTAssertEqual(DJIBLE.identify(manufacturerData: [0xAA, 0x08, 0x22, 0x00]).model, "OsmoPocket4P")
        XCTAssertFalse(DJIBLE.identify(manufacturerData: [0x4C, 0x00, 0x20, 0x00]).isDJI)
        let osmo = DJIBLE.pairMessage(pin: DJIBLE.pairPINOsmo)
        XCTAssertEqual(Array(osmo.payload.suffix(5)), [4] + Array("osmo".utf8))
        XCTAssertEqual(try DJIBLE.parse(DJIBLE.build(osmo)), osmo)
        XCTAssertEqual(DJIBLE.interpretPairReply(pin: "osmo", payload: [0x00, 0x01]), .alreadyPaired)
        XCTAssertEqual(DJIBLE.interpretPairReply(pin: "osmo", payload: [0x00, 0x02]), .approveOnCamera)
        XCTAssertEqual(DJIBLE.interpretPairReply(pin: "osmo", payload: [0x00, 0x06]), .notApproval)
        XCTAssertEqual(DJIBLE.interpretPairReply(pin: "mbln", payload: [0x00, 0x06]), .approveOnCamera)
        XCTAssertEqual(DJIBLE.interpretPairReply(pin: "mbln", payload: [0x00, 0x01]), .alreadyPaired)
        var r = DJIBLEReassembler()
        XCTAssertEqual(r.push(Array(m[0 ..< 20])).count, 0)
        XCTAssertEqual(r.push(Array(m[20...])), [m])
    }

    func testUDPHeaders() {
        XCTAssertEqual(DJIUDPFrame.header(length: 48, sessionID: 0x1234, seq: 0, type: 0).hexString(), "3080341200000096")
        XCTAssertEqual(DJIUDPFrame.header(length: 34, sessionID: 0xBEEF, seq: 0, type: 4).hexString(), "2280efbe000004f7")
        let h = DJIUDPFrame.parse(hex("3080341200000096") + [9])!
        XCTAssertTrue(h.xorOK); XCTAssertEqual(h.length, 48); XCTAssertEqual(h.sessionID, 0x1234); XCTAssertEqual(h.body, [9])
        XCTAssertEqual(DJIUDPFrame.handshakePacket(sessionID: 1, seed: 0x1000).count, 48)
        XCTAssertTrue(DJIUDPFrame.seqAhead(2, 0xFFF0)); XCTAssertFalse(DJIUDPFrame.seqAhead(5, 5)); XCTAssertFalse(DJIUDPFrame.seqAhead(1, 2))
    }

    func testSessionCoreMatchesPython() {
        var sent: [Bytes] = []
        let core = DJISessionCore(sessionID: 0x1234) { sent.append($0) }
        core.legacyFraming = true   // 与原 Python 逐字节对照
        _ = core.makeHandshake(seed: 0x1000)
        core.handle(datagram: DJIUDPFrame.header(length: 8, sessionID: 0x1234, seq: 0x1008, type: DJIUDPType.ackTelemetry))
        core.sendPush(receiverType: 8, receiverID: 2, cmdSet: 0, cmdID: 0x4F, payload: [1, 0, 0, 0, 0, 0xFF, 0xFF, 0xFF, 0xFF])
        core.tickAck()
        XCTAssertEqual(sent[0].hexString(), "2a80341200100599e00f00100000000001016000551604fc0248001040004f0100000000ffffffff2e88")
        XCTAssertEqual(sent[1].hexString(), "22803412000004800010001000000000081008100000000008100810000000000000")
    }

    func testHandshakeAdoptsCameraSession() {
        let core = DJISessionCore(sessionID: 0x1111) { _ in }
        XCTAssertFalse(core.handleHandshakeResponse(DJIUDPFrame.header(length: 8, sessionID: 0x2222, seq: 0, type: 1)))
        XCTAssertTrue(core.handleHandshakeResponse(DJIUDPFrame.header(length: 8, sessionID: 0x2222, seq: 0, type: 0)))
        XCTAssertEqual(core.sessionID, 0x2222)
    }

    func testVideoDispatchAndStatus() {
        let core = DJISessionCore(sessionID: 1) { _ in }
        var video: [Bytes] = []
        var cam = CameraStatus(); var gim = GimbalState()
        core.onVideo = { video.append($0) }
        core.onDUML = { p, _ in if !cam.apply(p), p.cmdSet == 4, p.cmdID == 5 { gim.update(payload: p.payload) } }
        _ = core.makeHandshake(seed: 0)
        core.handle(datagram: DJIUDPFrame.header(length: 0, sessionID: 1, seq: 8, type: 2) + Bytes(repeating: 0, count: 12) + [0, 0, 0, 1, 0x67])
        XCTAssertEqual(video, [[0, 0, 0, 1, 0x67]])
        XCTAssertEqual(core.videoRxSeq, 8)
        var p80 = Bytes(repeating: 0, count: 60); p80[0] = 0x81; p80[57] = 0x01
        var bat = Bytes(repeating: 0, count: 34); bat[1] = 0x10; bat[2] = 0x0F; bat[20] = 87
        var att = Bytes(repeating: 0, count: 49); att[4] = 0x9C; att[5] = 0xFF; att[20] = 0xCE; att[21] = 0xFF
        let tele = [DUML.build(senderType: 1, senderID: 0, receiverType: 2, receiverID: 0, cmdSet: 2, cmdID: 0x80, payload: p80, cmdType: 2),
                    DUML.build(senderType: 13, senderID: 0, receiverType: 2, receiverID: 0, cmdSet: 13, cmdID: 2, payload: bat, cmdType: 2),
                    DUML.build(senderType: 4, senderID: 0, receiverType: 2, receiverID: 0, cmdSet: 4, cmdID: 5, payload: att, cmdType: 2)].flatMap { $0 }
        core.handle(datagram: DJIUDPFrame.header(length: 8 + tele.count, sessionID: 1, seq: 0, type: 1) + tele)
        XCTAssertEqual(cam.mode, .video); XCTAssertTrue(cam.recording)
        XCTAssertEqual(cam.batteryPercent, 87); XCTAssertEqual(cam.batteryMilliVolt, 0x0F10)
        XCTAssertEqual(gim.yaw, -10.0, accuracy: 0.001); XCTAssertEqual(gim.pitch, 5.0, accuracy: 0.001)
    }

    func testHeartbeatSchedules() {
        var sent: [DUMLPacket] = []
        let core = DJISessionCore(sessionID: 1) { _ in }
        core.onDUML = { p, d in if d == .tx { sent.append(p) } }
        core.linkKeepalive = .legacy
        _ = core.makeHandshake(seed: 0)
        core.startVideo()
        XCTAssertEqual(sent.map(\.cmdID), [0x88, 0x81, 0x82, 0xDA])
        XCTAssertEqual(sent[1].cmdType, DUMLCmdType.write); XCTAssertEqual(sent[1].payload.count, 64)
        sent = []
        for _ in 0 ..< 26 { core.tickVideoHeartbeat() }
        let hbs = sent.filter { $0.cmdID == 0x4F }
        XCTAssertEqual(hbs.count, 6)                               // 1Hz：tick 0/5/10/15/20/25
        XCTAssertEqual(hbs.map { $0.payload[2] }.prefix(5), [0, 1, 2, 3, 4])
        XCTAssertEqual(sent.filter { $0.cmdID == 0x81 }.count, 1) // 每 5s：tick 25
        XCTAssertEqual(sent.filter { $0.cmdID == 0x88 }.count, 5) // 1Hz：tick 5/10/15/20/25
        sent = []
        for _ in 0 ..< 10 { core.tickCameraHeartbeat() }
        XCTAssertEqual(sent.filter { $0.cmdID == 0x8E }.count, 10)
        XCTAssertEqual(sent.filter { $0.cmdID == 0xA0 }.count, 5)
        XCTAssertEqual(sent.filter { $0.cmdID == 0x61 }.count, 2)
        // seq 每命令 +8
        XCTAssertEqual(sent[1].seq &- sent[0].seq, 8)
        sent = []
        for _ in 0 ..< 5 { core.tickLinkHeartbeat() }
        XCTAssertEqual(sent.count, 0, "旧版保活不发 General:0x0E")
    }

    /// 默认：启动与 5s 视频 tick 都不发 0x4F；0x88/0x81 节奏不变；0x0E 为 1Hz 空负载 request → Camera。
    func testMimoKeepaliveSkipsVersionConfig() {
        var sent: [DUMLPacket] = []
        let core = DJISessionCore(sessionID: 1) { _ in }
        core.onDUML = { p, d in if d == .tx { sent.append(p) } }
        XCTAssertEqual(core.linkKeepalive, .mimo)
        _ = core.makeHandshake(seed: 0)
        core.startVideo()
        XCTAssertFalse(sent.contains { $0.cmdID == 0x4F }, "启动序列不含版本配置读取")
        XCTAssertEqual(sent.map(\.cmdID), [0x88, 0x81, 0x82, 0xDA])
        sent = []
        for _ in 0 ..< 26 { core.tickVideoHeartbeat() }
        XCTAssertEqual(sent.filter { $0.cmdID == 0x4F }.count, 0)
        XCTAssertEqual(sent.filter { $0.cmdID == 0x88 }.count, 5)
        XCTAssertEqual(sent.filter { $0.cmdID == 0x81 }.count, 1)
        sent = []
        for _ in 0 ..< 10 {
            core.tickLinkHeartbeat()
            core.tickCameraHeartbeat()
        }
        let hb = sent.filter { $0.cmdSet == 0 && $0.cmdID == 0x0E }
        XCTAssertEqual(hb.count, 10)
        XCTAssertTrue(hb.allSatisfy {
            $0.receiverType == DUMLDevice.camera && $0.receiverID == 0
                && $0.payload.isEmpty && $0.cmdType == DUMLCmdType.request
        })
        XCTAssertEqual(sent.filter { $0.cmdID == 0x8E }.count, 10, "相机参数轮询仍在")
        XCTAssertEqual(sent.filter { $0.cmdID == 0x4F }.count, 0)
        // 切回旧版后，同一节拍改为 0x4F，0x0E 停止
        core.linkKeepalive = .legacy
        sent = []
        core.tickLinkHeartbeat()
        core.tickVideoHeartbeat() // videoHBTick == 26，26 % 5 != 0，这一拍不发 0x4F
        XCTAssertTrue(sent.isEmpty)
        for _ in 0 ..< 4 { core.tickVideoHeartbeat() } // tick 27…30，30 % 5 == 0
        let cfg = sent.filter { $0.cmdID == 0x4F }
        XCTAssertEqual(cfg.count, 1)
        XCTAssertEqual(cfg[0].receiverType, DUMLDevice.dm368)
        XCTAssertEqual(cfg[0].receiverID, 2)
        XCTAssertEqual(cfg[0].payload, [0x01, 0x00, 0x00, 0x00, 0x00, 0xFF, 0xFF, 0xFF, 0xFF])
        XCTAssertEqual(cfg[0].cmdType, DUMLCmdType.request)
    }

    func testGimbalSpeedMatchesPython() {
        XCTAssertEqual(GimbalProtocol.speedValue(0.3), 1331)
        XCTAssertEqual(GimbalProtocol.speedValue(-0.3), 716)
        XCTAssertEqual(GimbalProtocol.speedValue(-0.03), 993)
        XCTAssertEqual(GimbalProtocol.speedValue(5), 2048)
        XCTAssertEqual(GimbalProtocol.speedValue(-5), 0)
        XCTAssertEqual(GimbalProtocol.recenterPayload, [0xFE, 0x08])
    }

    func testAnnexBAcrossChunks() {
        let sps: Bytes = [0x67, 0x42, 0x00, 0x1F], pps: Bytes = [0x68, 0xCE, 0x3C, 0x80]
        let idr: Bytes = [0x65, 0x88, 0x84, 0x00, 0x21], p1: Bytes = [0x41, 0x9A, 0x00, 0x00, 0x05], p2: Bytes = [0x41, 0x9B, 0x01]
        let sc4: Bytes = [0, 0, 0, 1], sc3: Bytes = [0, 0, 1], aud: Bytes = [0x09, 0xF0]
        var stream = Bytes()
        for part in [sc4, sps, sc4, pps, sc3, idr, sc4, p1, sc4, p2, sc4, aud] { stream += part }
        for chunk in [1, 2, 3, 5, 7, 64] {
            var parser = AnnexBParser(); var asm = H264AccessUnitAssembler()
            var nals: [Bytes] = []; var aus: [H264AccessUnit] = []
            var i = 0
            while i < stream.count {
                let n = parser.push(Array(stream[i ..< min(stream.count, i + chunk)]))
                nals += n
                for x in n { aus += asm.push(x) }
                i += chunk
            }
            XCTAssertEqual(nals, [sps, pps, idr, p1, p2], "chunk \(chunk)")
            XCTAssertEqual(aus.count, 2) // p2 仍在等待下一个 AU 起点
            if let last = parser.flush() { aus += asm.push(last) } // AUD 结束 p2
            XCTAssertEqual(aus.count, 3)
            XCTAssertTrue(aus[0].isKeyframe); XCTAssertFalse(aus[1].isKeyframe)
            XCTAssertEqual(asm.sps, sps); XCTAssertEqual(asm.pps, pps)
            XCTAssertEqual(aus[1].avcc, [0, 0, 0, 5] + p1)
        }
    }

    func testDeviceProfileDetection() {
        XCTAssertEqual(DeviceProfile.detect(manufacturerData: [0xAA, 0x08, 0x20, 0x00], localName: nil).model, .pocket3)
        XCTAssertEqual(DeviceProfile.detect(manufacturerData: [0xAA, 0x08, 0x21, 0x00], localName: "OsmoPocket3-AAAA").model, .pocket4)
        XCTAssertEqual(DeviceProfile.detect(manufacturerData: [0xAA, 0x08, 0x22, 0x00], localName: nil).model, .pocket4P)
        XCTAssertEqual(DeviceProfile.detect(manufacturerData: [0xAA, 0x08, 0x20, 0x00], localName: nil).udpPort, 9004)
        XCTAssertEqual(DeviceProfile.detect(manufacturerData: [0xAA, 0xF7, 0x22, 0x00], localName: nil).udpPort, 10004)
        XCTAssertEqual(DeviceProfile.detect(manufacturerData: [0xAA, 0xF7, 0x22, 0x00], localName: nil).vendor, .xtra)
        XCTAssertFalse(DeviceProfile.detect(manufacturerData: [0xAA, 0xF7, 0x22, 0x00], localName: nil).parsesSDCapacity)
        let named = DeviceProfile.detect(manufacturerData: nil, localName: "OsmoPocket4P-AB12")
        XCTAssertEqual(named.model, .pocket4P)
        XCTAssertTrue(named.isDJI)
        XCTAssertEqual(named.udpPort, 9004)
        XCTAssertEqual(DeviceProfile.detect(manufacturerData: nil, localName: "Osmo Pocket 4 Pro").model, .pocket4P)
        XCTAssertEqual(DeviceProfile.detect(manufacturerData: nil, localName: "OsmoPocket4-ZZZZ").model, .pocket4)
        XCTAssertEqual(DeviceProfile.detect(manufacturerData: nil, localName: "OsmoPocket3-D6B1").model, .pocket3)
        XCTAssertFalse(DeviceProfile.detect(manufacturerData: nil, localName: "iPhone").isDJI)
        XCTAssertFalse(DeviceProfile.detect(manufacturerData: [0x4C, 0x00, 0x20, 0x00], localName: "Something").isDJI)
        XCTAssertTrue(DeviceProfile.pocket3.parsesSDCapacity)
        XCTAssertFalse(DeviceProfile.pocket4.parsesSDCapacity)
        XCTAssertTrue(DeviceProfile.pocket4.hasInternalStorage)
        XCTAssertEqual(DeviceProfile.pocket4.modeTable.wireID(for: .photo), 0x05)
        XCTAssertEqual(DeviceProfile.pocket4P.modeTable.wireID(for: .photo), 0x17)
        XCTAssertEqual(DeviceProfile.pocket4P.modeTable.wireID(for: .livePhoto), 0x4D)
        XCTAssertEqual(DeviceProfile.pocket3.modeTable.wireID(for: .photo), 0x05)
        XCTAssertNil(DeviceProfile.pocket3.modeTable.wireID(for: .livePhoto))
        XCTAssertEqual(Shutter.segments(for: .pocket3), [.slowMotion, .video, .photo, .timelapse])
        XCTAssertEqual(Shutter.segments(for: .pocket4P), [.slowMotion, .video, .photo, .livePhoto, .timelapse])
        XCTAssertEqual(DeviceProfile.pocket4.documentedPreviewCodec, .hevc)
        XCTAssertEqual(DeviceProfile.pocket3.documentedPreviewCodec, .h264)
    }

    func testCodecHintDoesNotLatchOnAmbiguousHeaders() {
        XCTAssertEqual(VideoCodec.hint(nalHeader: 0x40), .hevc)
        XCTAssertEqual(VideoCodec.hint(nalHeader: 0x42), .hevc)
        XCTAssertEqual(VideoCodec.hint(nalHeader: 0x44), .hevc)
        XCTAssertEqual(VideoCodec.hint(nalHeader: 0x67), .h264)
        XCTAssertEqual(VideoCodec.hint(nalHeader: 0x68), .h264)
        XCTAssertNil(VideoCodec.hint(nalHeader: 0x28))
        XCTAssertNil(VideoCodec.hint(nalHeader: 0x41))
        XCTAssertNil(VideoCodec.hint(nalHeader: 0x20))
        XCTAssertTrue(HEVCNALType.isIRAP(16))
        XCTAssertTrue(HEVCNALType.isIRAP(20))
        XCTAssertTrue(HEVCNALType.isIRAP(21))
        XCTAssertFalse(HEVCNALType.isIRAP(1))
        XCTAssertEqual(HEVCNALType.of([0x20, 0x01]), 16)
        XCTAssertEqual(HEVCNALType.of([0x28, 0x01]), 20)
    }

    func testHEVCAccessUnitTreatsIRAPAsKeyframe() {
        var asm = H264AccessUnitAssembler()
        XCTAssertEqual(asm.push([0x28, 0x01, 0x00]), [])
        XCTAssertNil(asm.codec)
        XCTAssertNil(asm.pps)
        XCTAssertEqual(asm.push([0x41, 0x9A, 0x80]), [], "H.264 P 片首字节不得当成 HEVC VPS")
        let vps: Bytes = [0x40, 0x01, 0x0C]
        let sps: Bytes = [0x42, 0x01, 0x01]
        let pps: Bytes = [0x44, 0x01, 0xC1]
        let bla: Bytes = [0x20, 0x01, 0x80, 0x11]
        let trail: Bytes = [0x02, 0x01, 0x80, 0x22]
        let aud: Bytes = [0x46, 0x01]
        var aus: [H264AccessUnit] = []
        for nal in [vps, sps, pps, bla, trail, aud] { aus += asm.push(nal) }
        XCTAssertEqual(asm.codec, .hevc)
        XCTAssertEqual(asm.vps, vps)
        XCTAssertEqual(asm.sps, sps)
        XCTAssertEqual(asm.pps, pps)
        XCTAssertEqual(aus.count, 2)
        XCTAssertTrue(aus[0].isKeyframe)
        XCTAssertEqual(aus[0].codec, .hevc)
        XCTAssertFalse(aus[1].isKeyframe)
        XCTAssertEqual(aus[0].nals, [bla])
    }

    func testLiveViewFrameHeaderStrippedOnlyWhenPresent() {
        let payload: Bytes = [0x00, 0x00, 0x00, 0x01, 0x40, 0x01, 0x0C, 0x01]
        var header = Bytes([0x00, 0x00, 0x01, 0xFF])
        header.appendLE32(UInt32(payload.count))
        header += Bytes(repeating: 0xAB, count: 8)
        XCTAssertEqual(header.count, 16)
        var framed = DJILiveViewDeframer()
        let whole = framed.push(header + payload)
        XCTAssertTrue(whole.resetParser)
        XCTAssertTrue(framed.usesFrameHeader)
        XCTAssertEqual(whole.bytes, payload)
        XCTAssertEqual(framed.frames, 1)

        var split = DJILiveViewDeframer()
        let all = header + payload + header + payload
        let first = split.push(Array(all.prefix(3)))
        XCTAssertFalse(split.usesFrameHeader)
        XCTAssertTrue(first.bytes.isEmpty)
        let rest = split.push(Array(all.dropFirst(3)))
        XCTAssertTrue(split.usesFrameHeader)
        XCTAssertEqual(rest.bytes, payload + payload)
        XCTAssertEqual(split.frames, 2)

        let annex: Bytes = [0, 0, 0, 1, 0x67, 0x42, 0x00, 0x1F, 0, 0, 0, 1, 0x68, 0xCE, 0x38, 0x80]
        var raw = DJILiveViewDeframer()
        var got = Bytes()
        for byte in annex { got += raw.push([byte]).bytes }
        got += raw.flush()
        XCTAssertEqual(got, annex)
        XCTAssertFalse(raw.usesFrameHeader)

        var bogus = DJILiveViewDeframer()
        let huge = Bytes([0x00, 0x00, 0x01, 0xFF, 0xFF, 0xFF, 0xFF, 0x7F]) + annex
        let passed = bogus.push(huge)
        XCTAssertFalse(bogus.usesFrameHeader)
        XCTAssertEqual(passed.bytes + bogus.flush(), huge)
    }

    func testHexParsing() {
        XCTAssertEqual(Bytes(hexString: "0x01 ff:AB"), [1, 0xFF, 0xAB])
        XCTAssertNil(Bytes(hexString: "abc"))
    }
}
