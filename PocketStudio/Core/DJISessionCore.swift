// DJISessionCore.swift — UDP 会话状态机（移植自 pocket3/udp_protocol.py + camera.py + gimbal.py 的发包逻辑）
//
// 与传输层无关：只负责「收到的数据报 → 解析/分发」与「需要发出的数据报 → send 闭包」。
// 非线程安全：调用方必须在同一个串行队列上使用（macOS 端为 CameraLink.queue）。
// 定时调用约定（与原项目一致）：
//   tickAck()             每 20ms
//   tickGimbal()          每 40ms（25Hz 上限；静止不发）
//   tickCameraHeartbeat() 每 1s（Camera:0x8E，附带 0xA0 / 0x61）
//   tickLinkHeartbeat()   每 1s（与相机心跳同一拍；仅 mimo 模式发 General:0x0E）
//   tickVideoHeartbeat()  每 200ms（startVideo() 之后：0x88 每 5 拍；0x4F 仅 legacy）

import Foundation

nonisolated public enum DUMLDirection: String, Sendable { case rx = "RX", tx = "TX" }

nonisolated public struct DJISessionStats: Equatable, Sendable {
    public var rxPackets = 0, txPackets = 0, rxBytes = 0, txBytes = 0
    public var videoFrames = 0, dumlPackets = 0
    public var rxTypeCounts: [UInt8: Int] = [:]
    public init() {}
}

nonisolated public final class DJISessionCore {
    public private(set) var sessionID: UInt16
    public private(set) var cmdSeq: UInt16 = 0
    public private(set) var msgSeq: UInt16 = 1
    public private(set) var videoRxSeq: UInt16 = 0
    public private(set) var ackTelemRxSeq: UInt16 = 0
    public private(set) var cmdRxSeq: UInt16 = 0
    public private(set) var handshakeDone = false
    // ACK 窗口游标（OpenPocketCine DumlTransport.AckWindows）：
    //  组 0 = 最新视频包 seq；组 1 = 可靠数据（pktType 0x03 应答 + 34B 遥测 @18）；组 2 = 34B 遥测 @26（无则沿用原项目的 cmdSeq）。
    //  ⚠️ 旧实现把游标初始化为我们自己的握手随机种子，并且只接受「比种子靠前」的 seq：相机的 seq 空间与种子无关时，
    //  约一半概率游标永远不前进 → 相机的可靠窗口（100）被填满 → 视频与命令一起停，而 0x01 遥测照常 —— 正是「画面冻结 + 云台失灵 + 姿态照常」。
    public private(set) var videoSeen = false
    public private(set) var reliableSeen = false
    public private(set) var extraSeen = false
    public private(set) var extraCursor: UInt16 = 0
    /// 最近收到各类包的时刻（clock()）
    public private(set) var lastVideoAt: Double? = nil
    public private(set) var lastTelemetryAt: Double? = nil
    public private(set) var lastReliableAt: Double? = nil
    public private(set) var handshakeCount = 0
    public private(set) var baseSeq: UInt16 = 0
    /// 使用原 Python 命令头 / ACK 组 2 布局（设置项，仅用于对比）
    public var legacyFraming = false
    /// 链路保活。默认 Mimo：General:0x0E，不周期发送 0x4F。设置可切回旧版 0x4F。
    public var linkKeepalive: LinkKeepalive = .mimo
    public private(set) var stats = DJISessionStats()

    /// 发出数据报
    public var output: (Bytes) -> Void
    /// H.264 字节流片段（已去掉 12 字节视频窗口/帧信息）
    public var onVideo: ((Bytes) -> Void)?
    /// 所有 DUML 包（含发送方向）
    public var onDUML: ((DUMLPacket, DUMLDirection) -> Void)?

    /// 云台速度状态机（轴映射 / 反转 / 可靠停止 / 看门狗），见 GimbalSpeedController
    public var gimbal = GimbalSpeedController()
    /// 单调时钟（秒），测试可注入
    public var clock: () -> Double = { ProcessInfo.processInfo.systemUptime }

    private var videoHeartbeatRunning = false
    private var videoHBCounter = 0
    private var videoHBTick = 0
    private var cameraHBTick = 0
    private var rng: () -> UInt16

    public init(sessionID: UInt16? = nil, random: (() -> UInt16)? = nil, send: @escaping (Bytes) -> Void) {
        let r = random ?? { UInt16.random(in: 0 ... 0xFFFF) }
        self.rng = r
        self.sessionID = sessionID ?? r()
        self.output = send
    }

    private func transmit(_ b: Bytes) {
        stats.txPackets += 1
        stats.txBytes += b.count
        output(b)
    }

    // MARK: Handshake

    /// 生成握手包并重置序号计数器（connect() / reconnect() 共用）
    public func makeHandshake(seed: UInt16? = nil) -> Bytes {
        let s = (seed ?? rng()) & 0xFFF8
        videoRxSeq = s; ackTelemRxSeq = s; cmdSeq = s; msgSeq = 1; cmdRxSeq = s
        videoSeen = false; reliableSeen = false; extraSeen = false; extraCursor = s; baseSeq = s
        handshakeCount += 1
        return DJIUDPFrame.handshakePacket(sessionID: sessionID, seed: s)
    }

    public func sendHandshake(seed: UInt16? = nil) {
        transmit(makeHandshake(seed: seed))
    }

    /// 处理握手阶段收到的数据报。是握手响应则采用相机的 session id 并返回 true。
    @discardableResult
    public func handleHandshakeResponse(_ data: Bytes) -> Bool {
        stats.rxPackets += 1; stats.rxBytes += data.count
        guard let h = DJIUDPFrame.parse(data), h.type == DJIUDPType.handshake else { return false }
        sessionID = h.sessionID
        handshakeDone = true
        return true
    }

    // MARK: Receive

    public func handle(datagram data: Bytes) {
        stats.rxPackets += 1
        stats.rxBytes += data.count
        guard let h = DJIUDPFrame.parse(data) else { return }
        stats.rxTypeCounts[h.type, default: 0] += 1
        if h.type != DJIUDPType.video { lastTelemetryAt = clock() }   // 任何非视频包都说明链路活着

        switch h.type {
        case DJIUDPType.handshake:
            // 重新握手的应答：同步 session
            sessionID = h.sessionID
        case DJIUDPType.video:
            stats.videoFrames += 1
            lastVideoAt = clock()
            // 组 0：第一次见到直接采用，之后只前进
            if !videoSeen || DJIUDPFrame.seqAhead(h.seq, videoRxSeq) { videoRxSeq = h.seq; videoSeen = true }
            // body: 窗口信息(8) + 帧信息(4) + H.264
            if h.body.count > 12 { onVideo?(Array(h.body[12...])) }
        case DJIUDPType.telemetry:
            // 34 字节 0x01 = 相机广播的窗口游标（@10 视频 / @18 可靠 / @26 额外）
            if data.count == 34, data[8] != 0x55 {
                let rel = data.le16(18), ext = data.le16(26)
                if !reliableSeen || DJIUDPFrame.seqAhead(rel, ackTelemRxSeq) { ackTelemRxSeq = rel; reliableSeen = true }
                extraCursor = ext; extraSeen = true
                if !videoSeen { videoRxSeq = data.le16(10) }
            }
            processDUML(h.body, .rx)
        case DJIUDPType.ackTelemetry:
            lastReliableAt = clock()
            if !reliableSeen || DJIUDPFrame.seqAhead(h.seq, ackTelemRxSeq) { ackTelemRxSeq = h.seq; reliableSeen = true }
            processDUML(h.body, .rx)
        case DJIUDPType.command:
            if DJIUDPFrame.seqAhead(h.seq, cmdRxSeq) { cmdRxSeq = h.seq }
            processDUML(h.body, .rx)
        default:
            break // ACK / ACK6：无需处理
        }
    }

    private func processDUML(_ body: Bytes, _ dir: DUMLDirection) {
        for p in DUML.parse(body) {
            stats.dumlPackets += 1
            onDUML?(p, dir)
        }
    }

    // MARK: Send DUML

    private func nextCmdSeq() -> UInt16 { let s = cmdSeq; cmdSeq = cmdSeq &+ 8; return s }
    private func nextMsgSeq() -> UInt16 { let s = msgSeq; msgSeq = msgSeq &+ 1; return s }

    @discardableResult
    public func sendDUML(senderType: UInt8 = DUMLDevice.app, senderID: UInt8 = 0,
                         receiverType: UInt8, receiverID: UInt8,
                         cmdSet: UInt8, cmdID: UInt8, payload: Bytes = [],
                         cmdType: UInt8 = DUMLCmdType.notify) -> UInt16 {
        let seq = nextCmdSeq()
        let duml = DUML.build(senderType: senderType, senderID: senderID,
                              receiverType: receiverType, receiverID: receiverID,
                              cmdSet: cmdSet, cmdID: cmdID, payload: payload,
                              seq: seq, cmdType: cmdType)
        let pkt = DJIUDPFrame.commandPacket(sessionID: sessionID, seq: seq, msgSeq: nextMsgSeq(), duml: duml, legacy: legacyFraming)
        if let cb = onDUML { for p in DUML.parse(duml) { cb(p, .tx) } }
        transmit(pkt)
        return seq
    }

    @discardableResult
    public func send(_ spec: CameraCommand.Spec) -> UInt16 {
        sendDUML(receiverType: spec.receiverType, receiverID: spec.receiverID,
                 cmdSet: spec.cmdSet, cmdID: spec.cmdID, payload: spec.payload, cmdType: spec.cmdType)
    }

    @discardableResult
    /// flags 0x40（需应答）。原项目称之为 PUSH。
    public func sendPush(receiverType: UInt8, receiverID: UInt8, cmdSet: UInt8, cmdID: UInt8, payload: Bytes = []) -> UInt16 {
        sendDUML(receiverType: receiverType, receiverID: receiverID, cmdSet: cmdSet, cmdID: cmdID, payload: payload, cmdType: DUMLCmdType.request)
    }

    @discardableResult
    /// flags 0x00（notify，无应答）。原项目称之为 REQ；云台摇杆流使用它。
    public func sendReq(receiverType: UInt8, receiverID: UInt8, cmdSet: UInt8, cmdID: UInt8, payload: Bytes = []) -> UInt16 {
        sendDUML(receiverType: receiverType, receiverID: receiverID, cmdSet: cmdSet, cmdID: cmdID, payload: payload, cmdType: DUMLCmdType.notify)
    }

    /// 回应相机发来的 REQ/WRITE（原项目 _send_duml_ack，保留供调试）
    public func sendDUMLAck(for pkt: DUMLPacket) {
        sendDUML(senderType: pkt.receiverType, senderID: pkt.receiverID,
                 receiverType: pkt.senderType, receiverID: pkt.senderID,
                 cmdSet: pkt.cmdSet, cmdID: pkt.cmdID, payload: [0x00], cmdType: DUMLCmdType.ack)
    }

    // MARK: Timers

    public func makeAck() -> Bytes {
        DJIUDPFrame.ackPacket(sessionID: sessionID, videoRx: videoRxSeq, ackTelemRx: ackTelemRxSeq, cmdSeq: ackExtraCursor)
    }

    /// ACK 组 2：遥测给出的游标；没有时 OPC 用握手 baseSeq。
    /// ⚠️ 原 Python 填自己的 cmdSeq：它以 ~70 包/秒 × 8 飞速前进，约 1 分钟就跨过半个序号环，
    ///    相机按「前进/后退」判断会突然把它当成倒退 → 窗口卡死（与「过一会儿就冻结」吻合）。
    public var ackExtraCursor: UInt16 { extraSeen ? extraCursor : (legacyFraming ? cmdSeq : baseSeq) }

    /// 每 20ms
    public func tickAck() { transmit(makeAck()) }

    /// 每 33ms：持续发送云台速度
    public func tickGimbal() {
        updateGimbalReadiness()
        let now = clock()
        // 限速：距上次云台包不足 minInterval 就推迟到下一拍（tick 不消耗 pendingStops）
        guard now - lastGimbalTX >= GimbalProtocol.minInterval * 0.9 else { return }
        if let p = gimbal.tick(now: now), gimbalReady || isZero(p) { sendGimbal(p) }
    }
    /// 云台摇杆包硬上限：任意输入路径合计 ≤ 1/minInterval（25Hz，与 OPC GimbalStick.streamInterval 0.04s 一致）。
    /// 14:17 日志：拖动时每个 mouseDragged 都立即发包 + 30Hz tick + 100ms 保活 → 同一毫秒重复包，峰值 84 包/s，
    /// 每次峰值 ≥70/s 的那一秒后相机命令通道即停止应答（2:17:22–23、2:17:37–38、2:17:59）。
    private var lastGimbalTX = -1.0
    public private(set) var gimbalTXCount = 0

    // MARK: 云台就绪门控（修复「首次连接云台不响应，断开重连才好」）
    // 实机日志：握手 → 视频启动后立即就有 30Hz 摇杆包，但当时尚未发送 OpenPocketCine/Mimo 的
    // 0x03/0xDA 云台初始化，也没有等云台首个 0x05 姿态推送。现在：
    //   * startVideo() 时发送 0x03/0xDA，1s / 3s 后各补发一次；
    //   * 收到首个 Gimbal:0x05 且距视频启动 ≥ 0.6s 才放行非零速度（零速始终放行）；
    //   * 4s 内都没收到姿态 → 每 2s 重发初始化并强制放行（避免永久锁死）。
    public private(set) var gimbalReady = false
    public private(set) var gimbalAttitudeSeen = false
    private var videoStartAt: Double? = nil
    private var gimbalInitSentAt: [Double] = []
    /// 准备就绪状态变化回调（queue 上）
    public var onGimbalReadyChanged: ((Bool) -> Void)?

    public func noteGimbalAttitude() { gimbalAttitudeSeen = true; updateGimbalReadiness() }

    public func sendGimbalInit() {
        sendDUML(receiverType: GimbalProtocol.initReceiverType, receiverID: 0, cmdSet: GimbalProtocol.initCmdSet,
                 cmdID: GimbalProtocol.initCmdID, payload: GimbalProtocol.initPayload, cmdType: DUMLCmdType.request)
        gimbalInitSentAt.append(clock())
    }

    private func updateGimbalReadiness() {
        guard let start = videoStartAt else { return }
        let now = clock(), dt = now - start
        if !gimbalReady {
            if (gimbalInitSentAt.count < 2 && dt >= 1.0) || (gimbalInitSentAt.count < 3 && dt >= 3.0) { sendGimbalInit() }
            if gimbalAttitudeSeen && dt >= 0.6 { setReady(true) }
            else if dt >= 4.0 { sendGimbalInit(); setReady(true) }
        }
    }

    private func setReady(_ v: Bool) {
        guard v != gimbalReady else { return }
        gimbalReady = v
        onGimbalReadyChanged?(v)
    }

    private func isZero(_ p: Bytes) -> Bool {
        p.count >= 6 && p.le16(0) == UInt16(GimbalProtocol.speedCenter) && p.le16(4) == UInt16(GimbalProtocol.speedCenter)
    }

    /// 云台 0x04/0x4C 等需应答命令
    @discardableResult
    public func sendGimbalCommand(cmdID: UInt8, payload: Bytes, cmdType: UInt8 = DUMLCmdType.request) -> UInt16 {
        sendDUML(receiverType: DUMLDevice.gimbal, receiverID: 0, cmdSet: DUMLCmdSet.gimbal, cmdID: cmdID,
                 payload: payload, cmdType: cmdType)
    }

    /// 回中：先停摇杆 + 打断残留 0x14 定时移动，再发 0x4C FE 08
    public func recenterGimbal() {
        sendGimbal(gimbal.stop())
        sendGimbalCommand(cmdID: GimbalProtocol.cmdAbsAngle, payload: GimbalProtocol.timedMoveStopPayload, cmdType: DUMLCmdType.notify)
        sendGimbalCommand(cmdID: GimbalProtocol.cmdSetMode, payload: GimbalProtocol.recenterPayload)
    }

    private func sendGimbal(_ payload: Bytes) {
        lastGimbalTX = clock(); gimbalTXCount += 1
        sendReq(receiverType: DUMLDevice.gimbal, receiverID: 0, cmdSet: DUMLCmdSet.gimbal,
                cmdID: GimbalProtocol.cmdControl, payload: payload)
    }

    /// 连续速度输入（-1…1；yaw 右正，pitch 上正）。立即发送一次，之后由 tickGimbal 维持。
    public func setGimbalSpeed(yaw: Double, pitch: Double) {
        let now = clock()
        let wasMoving = gimbal.isMoving
        let p = gimbal.set(yaw: yaw, pitch: pitch, now: now)
        // 只更新目标速度；仅在「开始移动 / 停止」且距上次发送 ≥ minInterval 时立即发一次，其余由 tick 合并发送最新值
        let edge = wasMoving != gimbal.isMoving
        if edge, now - lastGimbalTX >= GimbalProtocol.minInterval, gimbalReady || isZero(p) { sendGimbal(p) }
    }
    /// 可靠停止：限速允许则立即发零速，其余由 tick 补发（共 stopRepeats 次）
    public func stopGimbal() {
        let p = gimbal.stop()
        if clock() - lastGimbalTX >= GimbalProtocol.minInterval { sendGimbal(p) } else { gimbal.addPendingStop() }
    }
    public func nudgeGimbal(yaw: Double, pitch: Double, duration: Double) {
        let p = gimbal.nudge(yaw: yaw, pitch: pitch, duration: duration, now: clock())
        if gimbalReady { sendGimbal(p) }
    }

    /// 每 1s：Camera:0x8E 参数选项；每 2 拍 0xA0；每 5 拍 0x61（原 200ms / 1s / 2s，§5d 降频）
    public func tickCameraHeartbeat() {
        send(CameraCommand.heartbeat)
        if cameraHBTick % 2 == 0 { send(CameraCommand.stateQuery) }
        if cameraHBTick % 5 == 0 { send(CameraCommand.statusPoll) }
        cameraHBTick += 1
    }

    /// 每 1s，与 `tickCameraHeartbeat` 同一节拍。仅 `.mimo` 发送 General:0x0E。
    public func tickLinkHeartbeat() {
        guard linkKeepalive == .mimo else { return }
        send(LinkCommand.heartbeat)
    }

    // MARK: Video start (Mimo 启动序列)

    public static let dm368Reg88First: Bytes = [0x17, 0x00, 0x46, 0x23, 0x73, 0x41, 0x50, 0x50, 0x00, 0x00, 0x00, 0x00, 0x00, 0x02]
    public static let dm368Reg88Repeat: Bytes = [0x17, 0x00, 0x68, 0x23, 0x69, 0x41, 0x50, 0x50, 0x00, 0x00, 0x00, 0x00, 0x00, 0x02]

    /// 1) PUSH General:0x88 → DM368(1)  2) WRITE 0x81 / 0x82 → DM368(2)  3) 开始注册循环（0x88 1Hz）
    /// 启动序列不含 0x4F。原 Python 的前三步同样只有 0x88/0x81/0x82，0x4F 只出现在随后的循环里，
    /// 而且它是版本配置分块读取（Get Cfg File），不是视频门控。OPC 把画面寿命归因于 0x88/0x81。
    /// 周期 0x4F 仅在 `linkKeepalive == .legacy` 时由 tick 发送。
    public func startVideo() {
        sendPush(receiverType: DUMLDevice.dm368, receiverID: 1, cmdSet: DUMLCmdSet.general, cmdID: 0x88,
                 payload: Self.dm368Reg88First)
        sendDM368Register()
        sendGimbalInit()
        videoStartAt = clock()
        videoHeartbeatRunning = true
        videoHBCounter = 0
        videoHBTick = 0
    }

    public var isVideoHeartbeatRunning: Bool { videoHeartbeatRunning }

    // MARK: 视频恢复手段

    /// 重新注册（0x81/0x82 + 0x88）。OPC：相机停发视频后，重新注册可在同一 socket 上立即恢复。
    public func reRegister() {
        sendPush(receiverType: DUMLDevice.dm368, receiverID: 1, cmdSet: DUMLCmdSet.general, cmdID: 0x88,
                 payload: Self.dm368Reg88Repeat)
        sendDM368Register()
    }

    /// 请求关键帧。两条一起发，调用方须限频（CameraLink ≥3s）。
    /// 1) 0x09/0xA8 → DM368(type 8, id 0)：OPC 在 Pocket 家族上用作 live view / IDR。
    ///    ⚠️ 不要周期性发送：每秒重发会不断重置编码器 GOP，IDR 永远到不了（OPC 黑屏 bug）。
    /// 2) Camera:0xB3 空负载：Mimo `AppRequestIFrame`。负载未知，见 `CameraCommand.requestIFrame`。
    public func requestKeyframe() {
        sendPush(receiverType: DUMLDevice.dm368, receiverID: 0, cmdSet: 0x09, cmdID: 0xA8,
                 payload: [0x00, 0x04, 0x02, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])
        send(CameraCommand.requestIFrame)
    }

    public func stopVideoHeartbeat() { videoHeartbeatRunning = false }

    public func sendDM368Register() {
        var app = Bytes(repeating: 0, count: 64)
        app[1] = 0x41; app[2] = 0x50; app[3] = 0x50 // "APP"
        sendDUML(receiverType: DUMLDevice.dm368, receiverID: 2, cmdSet: DUMLCmdSet.general, cmdID: 0x81,
                 payload: app, cmdType: DUMLCmdType.write)
        sendDUML(receiverType: DUMLDevice.dm368, receiverID: 2, cmdSet: DUMLCmdSet.general, cmdID: 0x82,
                 payload: [0x00], cmdType: DUMLCmdType.write)
    }

    /// 每 200ms。0x81/0x82 每 5s；0x88 保持 1Hz（相机约 10s 无注册就停视频）。
    /// 0x4F 只在旧版保活里以 1Hz 发送：9 字节 = type(1) + offset u32le + length u32le(0xFFFFFFFF)，
    /// 计数器沿用 Python 写在 offset 的第 2 字节。这是 Get Cfg File，相机会回约 265 字节 XML。
    public func tickVideoHeartbeat() {
        guard videoHeartbeatRunning else { return }
        if linkKeepalive == .legacy, videoHBTick % 5 == 0 {
            let counter = UInt8(videoHBCounter & 0xFF)
            let hb: Bytes = [0x01, 0x00, counter, 0x00, 0x00, 0xFF, 0xFF, 0xFF, 0xFF]
            sendPush(receiverType: DUMLDevice.dm368, receiverID: 2, cmdSet: DUMLCmdSet.general, cmdID: 0x4F, payload: hb)
            videoHBCounter += 1
        }
        if videoHBTick % 25 == 0 && videoHBTick > 0 { sendDM368Register() }
        // OpenPocketCine：相机在最后一次注册 8–10s 后停发视频；Mimo 每秒重复注册 → 改为 1Hz（原项目 5s）
        if videoHBTick % 5 == 0 && videoHBTick > 0 {
            sendPush(receiverType: DUMLDevice.dm368, receiverID: 1, cmdSet: DUMLCmdSet.general, cmdID: 0x88,
                     payload: Self.dm368Reg88Repeat)
        }
        videoHBTick += 1
    }
}
