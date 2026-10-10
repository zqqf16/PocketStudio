// VideoHealthMonitor.swift — 视频看门狗 + 重连退避策略（纯逻辑，Linux 单测覆盖）
//
// v2（2026-10-10 13:33 实机日志后重写）：v1 太激进，亲手杀死了健康链路：
//   13:33:54 丢包导致 -12909 → 等 IDR；但 Pocket 3 实时流几乎不发 IDR（GOP 计数 716 帧 ≈ 24s），
//   视频 546 片段/s、相机应答 12/s 都正常，v1 仍在 13:33:59 原地重新握手、13:34:02 重建链路 → 握手超时 → 彻底断开。
//   另外原地重新握手在三份日志里（11:41:49、13:33:59、13:35:08）从未恢复过画面 → 删除该阶段。
//
// 规则：
//  * 视频包仍在到（或相机仍在应答）→ 只是解码问题：重建解码器（≥5s 一次），绝不动链路。
//  * 相机在回放 / 拍照处理中 → 不升级，交给上层发「退出回放」，等相机忙完。
//  * 遥测在、视频与应答都停 → 重新注册 + 请求关键帧；仍无画面 4s 后 → 重建链路（交给 ReconnectPolicy 退避）。
//  * 遥测也停（≥4s）→ 链路中断 → 上层走重连流程。

nonisolated public enum VideoRecoveryAction: Equatable, Sendable {
    case none
    case resetDecoder
    case reRegister
    /// 相机忙（回放 / 拍照处理）：暂停升级
    case waitCameraBusy
    case rebuildLink
    /// 相机命令通道停止应答（遥测仍在）→ 需完整重连
    case commandStall
    case recovered
    case linkLost
}

nonisolated public struct VideoHealthInput: Sendable {
    public var now: Double
    public var connectedAt: Double
    public var lastVideoPacket: Double?
    public var lastDecoded: Double?
    public var lastTelemetry: Double?
    public var lastReply: Double?
    public var cameraBusy: Bool
    public init(now: Double, connectedAt: Double, lastVideoPacket: Double?, lastDecoded: Double?,
                lastTelemetry: Double?, lastReply: Double? = nil, cameraBusy: Bool = false) {
        self.now = now; self.connectedAt = connectedAt; self.lastVideoPacket = lastVideoPacket
        self.lastDecoded = lastDecoded; self.lastTelemetry = lastTelemetry; self.lastReply = lastReply
        self.cameraBusy = cameraBusy
    }
}

nonisolated public struct VideoHealthMonitor: Sendable {
    public var startupGrace = 4.0
    public var stallAfter = 2.0
    public var decoderResetInterval = 5.0
    public var rebuildAfterReRegister = 4.0
    public var linkLostAfter = 4.0
    /// 命令通道停止应答（视频可能仍在）多久后判定卡死。13:51 日志：应答停止后 8–10s 视频必然停止，且从未自愈。
    public var commandStallAfter = 6.0
    public private(set) var commandStallReported = false

    public private(set) var stalled = false
    public private(set) var reRegisteredAt: Double? = nil
    public private(set) var busyReported = false
    private var lastDecoderReset = -100.0
    private var linkLostReported = false
    private var rebuildRequested = false

    public init() {}
    public var isStalled: Bool { stalled }

    public mutating func evaluate(_ i: VideoHealthInput) -> VideoRecoveryAction {
        let decodedAge = i.now - (i.lastDecoded ?? i.connectedAt)
        let videoAge = i.now - (i.lastVideoPacket ?? i.connectedAt)
        let telemAge = i.now - (i.lastTelemetry ?? i.connectedAt)
        let replyAge = i.now - (i.lastReply ?? i.connectedAt)

        if stalled, i.lastDecoded != nil, decodedAge < stallAfter {
            reset(); return .recovered
        }
        if i.now - i.connectedAt < startupGrace { return .none }
        if telemAge >= linkLostAfter {
            if !linkLostReported { linkLostReported = true; stalled = true; return .linkLost }
            return .none
        }
        linkLostReported = false
        if replyAge < 1.5 { commandStallReported = false }
        if replyAge >= commandStallAfter, !i.cameraBusy, i.lastReply != nil, !commandStallReported, !rebuildRequested {
            commandStallReported = true; rebuildRequested = true
            return .commandStall
        }
        guard decodedAge >= stallAfter else { return .none }
        stalled = true

        // 视频包仍在到达 → 解码层问题，不碰链路
        if videoAge < 1.5 {
            reRegisteredAt = nil
            if i.now - lastDecoderReset >= decoderResetInterval { lastDecoderReset = i.now; return .resetDecoder }
            return .none
        }
        // 相机忙：等
        if i.cameraBusy {
            reRegisteredAt = nil
            if !busyReported { busyReported = true; return .waitCameraBusy }
            return .none
        }
        busyReported = false
        // 视频停了，但相机仍在应答命令 → 命令通道活着，重新注册即可，别重建
        guard let at = reRegisteredAt else { reRegisteredAt = i.now; return .reRegister }
        if replyAge < 1.5 {
            if i.now - at >= 6 { reRegisteredAt = i.now; return .reRegister }
            return .none
        }
        if !rebuildRequested, i.now - at >= rebuildAfterReRegister { rebuildRequested = true; return .rebuildLink }
        return .none
    }

    public mutating func reset() {
        commandStallReported = false
        stalled = false; reRegisteredAt = nil; busyReported = false; linkLostReported = false; rebuildRequested = false
    }
}

/// 重连退避：前两次只重建 UDP 链路（TCP 7001 戳 + 新 socket），之后走完整重连（蓝牙唤醒 → Wi-Fi → UDP）。
/// 实机日志：两次「重建链路」都握手超时（13:34:11、13:35:21），而手动重连（蓝牙配对后再握手）一次成功（13:34:30）。
nonisolated public enum ReconnectLevel: Equatable, Sendable { case rebuildLink, fullReconnect }

nonisolated public struct ReconnectPolicy: Sendable {
    public var delays: [Double] = [1.0, 3, 5, 8, 15, 30]
    /// 13:51 日志：UDP 重建 5/5 次握手超时，蓝牙重新唤醒 5/5 次成功 → 直接蓝牙唤醒
    public var rebuildAttempts = 0
    public var maxAttempts = 8
    public private(set) var failures = 0
    public init() {}

    /// 第 n 次尝试（从 0 开始）的等待时间与级别；超过上限返回 nil（放弃，提示用户）
    public func next() -> (delay: Double, level: ReconnectLevel)? {
        guard failures < maxAttempts else { return nil }
        let d = delays[min(failures, delays.count - 1)]
        return (d, failures < rebuildAttempts ? .rebuildLink : .fullReconnect)
    }
    public mutating func recordFailure() { failures += 1 }
    public mutating func reset() { failures = 0 }
}
