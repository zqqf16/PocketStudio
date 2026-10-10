// CameraLink.swift — 相机 UDP 会话：传输 + DJISessionCore + 定时器 + 状态聚合
// （对应原项目 DjiUdpClient.connect/start + GimbalController + CameraController 的线程部分）
//
// 线程模型：所有协议状态只在 `queue`（串行）上访问。对外回调也在 `queue` 上发生，
// UI 层需自行切回主线程。

import Foundation
import Dispatch

nonisolated public struct LinkSnapshot: Equatable, Sendable {
    public var camera = CameraStatus()
    public var gimbal = GimbalState()
    public var stats = DJISessionStats()
    public var sessionID: UInt16 = 0
    public var videoBytes = 0
    /// 云台已就绪（可接受速度控制）
    public var gimbalReady = false
    /// 诊断：最近收到视频 / 遥测 / 可靠应答的时刻（ProcessInfo.systemUptime；nil = 尚未收到）
    public var lastVideoAt: Double? = nil
    public var lastTelemetryAt: Double? = nil
    public var lastReliableAt: Double? = nil
    /// 诊断：ACK 三组游标与是否已从相机同步
    public var ackVideo: UInt16 = 0, ackReliable: UInt16 = 0, ackExtra: UInt16 = 0
    public var ackVideoSeen = false, ackReliableSeen = false, ackExtraSeen = false
    public var handshakeCount = 0
    /// 收到的应答总数（flags 0x80/0xC0）；冻结时为 0/s —— 命令通道卡死的标志
    public var repliesRx = 0
    public init() {}
}

nonisolated public enum LinkError: Error, Sendable, CustomStringConvertible {
    case transport(String), handshakeTimeout, notConnected
    public var description: String {
        switch self {
        case let .transport(s): return "网络错误：\(s)"
        case .handshakeTimeout: return "UDP 握手超时（相机无应答）"
        case .notConnected: return "尚未连接相机"
        }
    }
}

nonisolated public final class CameraLink: @unchecked Sendable {
    public let queue = DispatchQueue(label: "pocketstudio.link", qos: .userInteractive)
    public let host: String
    public let port: UInt16
    private let transport: DatagramTransport
    private var core: DJISessionCore!
    private var timers: [DispatchSourceTimer] = []
    private var handshakeCompletion: (@Sendable (Result<Void, LinkError>) -> Void)?
    private var handshakeTimer: DispatchSourceTimer?
    private var snapshotState = LinkSnapshot()
    private var dirty = false
    public private(set) var running = false

    /// 旧版（原 Python）姿态解析布局（见 GimbalState.update）
    public var legacyAttitudeLayout = false
    /// 相机/云台对我们 request 的应答（flags 0x80/0xC0；queue 上回调）
    public var onReply: (@Sendable (DUMLPacket) -> Void)?
    /// H.264 片段（queue 上回调）
    public var onVideo: (@Sendable (Bytes) -> Void)?
    /// 所有 DUML（queue 上回调）
    public var onDUML: (@Sendable (DUMLPacket, DUMLDirection) -> Void)?
    /// 状态快照，约 10Hz（queue 上回调）
    public var onSnapshot: (@Sendable (LinkSnapshot) -> Void)?
    public var onError: (@Sendable (String) -> Void)?

    public init(host: String = DJIUDPFrame.cameraIP, port: UInt16 = DJIUDPFrame.cameraPort, transport: DatagramTransport) {
        self.host = host; self.port = port; self.transport = transport
        core = DJISessionCore { [weak self] b in self?.transport.send(b) }
        core.onVideo = { [weak self] b in
            guard let self else { return }
            self.snapshotState.videoBytes += b.count
            self.onVideo?(b)
        }
        core.onDUML = { [weak self] p, d in self?.handleDUML(p, d) }
        core.onGimbalReadyChanged = { [weak self] v in self?.snapshotState.gimbalReady = v; self?.dirty = true }
    }

    private func handleDUML(_ p: DUMLPacket, _ d: DUMLDirection) {
        if d == .rx {
            if snapshotState.camera.apply(p) { dirty = true }
            else if p.cmdSet == DUMLCmdSet.gimbal, p.cmdID == GimbalProtocol.cmdAttitude {
                snapshotState.gimbal.update(payload: p.payload, legacyLayout: legacyAttitudeLayout); dirty = true
                core.noteGimbalAttitude()
            }
            if DUMLCmdType.isReply(p.cmdType) { snapshotState.repliesRx += 1 }
            if DUMLCmdType.isReply(p.cmdType), p.cmdSet == DUMLCmdSet.camera || p.cmdSet == DUMLCmdSet.gimbal {
                onReply?(p)
            }
        }
        onDUML?(p, d)
    }

    // MARK: Connect / handshake

    /// 发送握手并等待相机应答；成功后自动启动所有循环（ACK / 云台 / 心跳），0.5 秒后发送视频启动序列。
    public func connect(timeout: TimeInterval = 10, completion: @escaping @Sendable (Result<Void, LinkError>) -> Void) {
        queue.async { [self] in
            transport.onReceive = { [weak self] d in self?.receive(d) }
            transport.onError = { [weak self] e in self?.onError?(e) }
            do { try transport.start(host: host, port: port, queue: queue) }
            catch { completion(.failure(.transport("\(error)"))); return }
            handshakeCompletion = completion
            let t = DispatchSource.makeTimerSource(queue: queue)
            t.schedule(deadline: .now() + timeout)
            t.setEventHandler { [weak self] in self?.finishHandshake(.failure(.handshakeTimeout)) }
            t.resume()
            handshakeTimer = t
            core.sendHandshake()
        }
    }

    private func finishHandshake(_ r: Result<Void, LinkError>) {
        handshakeTimer?.cancel(); handshakeTimer = nil
        guard let c = handshakeCompletion else { return }
        handshakeCompletion = nil
        if case .success = r { startLoops() } else { transport.stop() }
        c(r)
    }

    private func receive(_ d: Bytes) {
        if handshakeCompletion != nil {
            if core.handleHandshakeResponse(d) { finishHandshake(.success(())) }
            return
        }
        guard running else { return }
        core.handle(datagram: d)
    }

    private func every(_ interval: Double, _ block: @escaping @Sendable () -> Void) {
        let t = DispatchSource.makeTimerSource(flags: .strict, queue: queue)
        t.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(2))
        t.setEventHandler(handler: block)
        t.resume()
        timers.append(t)
    }

    private func startLoops() {
        running = true
        every(0.02) { [weak self] in self?.core.tickAck() }
        every(GimbalProtocol.sendInterval) { [weak self] in self?.core.tickGimbal() }
        // 降频：原 5Hz（Python 原版）。OPC：命令过密会让相机停止应答。
        every(1.0) { [weak self] in self?.core.tickCameraHeartbeat() }
        every(0.1) { [weak self] in self?.publish() }
        queue.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self, self.running else { return }
            self.core.startVideo()
            self.every(0.2) { [weak self] in self?.core.tickVideoHeartbeat() }
        }
    }

    private func publish() {
        snapshotState.stats = core.stats
        snapshotState.sessionID = core.sessionID
        snapshotState.lastVideoAt = core.lastVideoAt
        snapshotState.lastTelemetryAt = core.lastTelemetryAt
        snapshotState.lastReliableAt = core.lastReliableAt
        snapshotState.ackVideo = core.videoRxSeq; snapshotState.ackReliable = core.ackTelemRxSeq
        snapshotState.ackExtra = core.ackExtraCursor
        snapshotState.ackVideoSeen = core.videoSeen; snapshotState.ackReliableSeen = core.reliableSeen
        snapshotState.ackExtraSeen = core.extraSeen
        snapshotState.handshakeCount = core.handshakeCount
        onSnapshot?(snapshotState)
        dirty = false
    }

    public func stop() {
        queue.sync {
            // 断开前连发 3 次零速（定时器即将取消，不能依赖 tick 补发）
            if running { for _ in 0 ..< 3 { core.stopGimbal() } }
            running = false
            timers.forEach { $0.cancel() }; timers = []
            handshakeTimer?.cancel(); handshakeTimer = nil
            handshakeCompletion = nil
            core.stopVideoHeartbeat()
            transport.stop()
        }
    }

    // MARK: Commands（线程安全，可在任意线程调用）

    /// 重新握手以触发新的视频突发（原项目 reconnect()）
    /// 注意：会把 ACK 窗口游标重置为「未同步」，下一包相机数据重新采用。
    public func rehandshake() { queue.async { [self] in if running { core.sendHandshake() } } }

    /// 重新注册（不重新握手）
    public func reRegister() { queue.async { [self] in if running { core.reRegister() } } }

    private var lastKeyframeRequest = -100.0
    /// 请求关键帧（0x09/0xA8），≥3s 限频（频繁发送会让 IDR 永远到不了）。返回是否真的发送。
    public func requestKeyframe(completion: (@Sendable (Bool) -> Void)? = nil) {
        queue.async { [self] in
            guard running else { completion?(false); return }
            let now = core.clock()
            guard now - lastKeyframeRequest >= 3 else { completion?(false); return }
            lastKeyframeRequest = now
            core.requestKeyframe()
            completion?(true)
        }
    }

    // 所有云台调用都 async 投递到同一串行 queue，因此与 30Hz tick 严格串行、按调用顺序生效：
    // stop 之后的 tick 只会发零速（GimbalSpeedController 已清零），不存在回发旧速度的竞态。
    public func setGimbalSpeed(yaw: Double, pitch: Double) {
        queue.async { [self] in if running { core.setGimbalSpeed(yaw: yaw, pitch: pitch) } }
    }

    public func stopGimbal() { queue.async { [self] in if running { core.stopGimbal() } } }

    /// 轴映射与方向（设置页）
    public func configureGimbal(order: GimbalAxisOrder, invertYaw: Bool, invertPitch: Bool) {
        queue.async { [self] in
            core.gimbal.axisOrder = order; core.gimbal.invertYaw = invertYaw; core.gimbal.invertPitch = invertPitch
        }
    }

    /// 短暂移动后停止（原项目 nudge）
    public func nudge(yaw: Double, pitch: Double, duration: Double = 0.5) {
        queue.async { [self] in if running { core.nudgeGimbal(yaw: yaw, pitch: pitch, duration: duration) } }
    }

    public func setLegacyFraming(_ on: Bool) { queue.async { [self] in core.legacyFraming = on } }

    public func setGimbalStreaming(_ on: Bool) { queue.async { [self] in core.gimbal.streaming = on } }

    /// 用户命令限速：相邻两条至少间隔 300ms（连点模式 / 快门不会形成突发）
    private var nextUserSendAt = 0.0
    public func send(_ spec: CameraCommand.Spec) {
        queue.async { [self] in
            let now = ProcessInfo.processInfo.systemUptime
            let at = max(now, nextUserSendAt)
            nextUserSendAt = at + 0.3
            queue.asyncAfter(deadline: .now() + (at - now)) { [self] in if running { core.send(spec) } }
        }
    }
    public func takePhoto() { send(CameraCommand.takePhoto) }
    public func sendCamera(_ spec: CameraCommand.Spec) { send(spec) }
    public func startRecording() { send(CameraCommand.recordCommand(start: true, mode: nil)) }
    public func stopRecording() { send(CameraCommand.recordCommand(start: false, mode: nil)) }
    /// 根据相机 0x80 状态（@0 bit7 = 录制中，@57 = 模式）选择开始或停止；返回实际动作（true = 开始）
    public func toggleRecording(completion: (@Sendable (Bool, CameraMode?) -> Void)? = nil) {
        queue.async { [self] in
            guard running else { return }
            let st = snapshotState.camera
            let start = !st.recording
            core.send(CameraCommand.recordCommand(start: start, mode: st.mode))
            completion?(start, st.mode)
        }
    }
    public func setMode(_ m: CameraMode) { send(CameraCommand.setMode(m)) }

    public func sendRaw(cmdSet: UInt8, cmdID: UInt8, payload: Bytes, receiverType: UInt8 = 1, receiverID: UInt8 = 0, cmdType: UInt8 = DUMLCmdType.request) {
        send(CameraCommand.Spec(receiverType: receiverType, receiverID: receiverID, cmdSet: cmdSet, cmdID: cmdID, payload: payload, cmdType: cmdType))
    }

    // 云台：0x04/0x4C / 0x50（OpenPocketCine 实机载荷）
    public func gimbalRecenter() { queue.async { [self] in if running { core.recenterGimbal() } } }
    public func gimbalFlip() {
        queue.async { [self] in if running { core.sendGimbalCommand(cmdID: GimbalProtocol.cmdSetMode, payload: GimbalProtocol.flipPayload) } }
    }
    public func setGimbalMode(_ m: GimbalMode) {
        queue.async { [self] in if running { core.sendGimbalCommand(cmdID: GimbalProtocol.cmdSetMode, payload: GimbalProtocol.setModePayload(m)) } }
    }
    public func setGimbalSpeedSetting(_ v: GimbalSpeedSetting) {
        queue.async { [self] in if running { core.sendGimbalCommand(cmdID: GimbalProtocol.cmdParams, payload: GimbalProtocol.speedSettingPayload(v)) } }
    }

    public func currentSnapshot() -> LinkSnapshot { queue.sync { snapshotState } }
}
