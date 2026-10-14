// GimbalSpeedController.swift — 云台速度状态机（纯逻辑，可在 Linux 单测）
//
// 负责：
//  • 轴映射：把 UI 的 (yaw=右正, pitch=上正) 写进 Gimbal:0x01 负载的正确字段；
//  • 方向反转（每轴独立）；
//  • 可靠停止：stop() 立即发零速，并在随后的 tick 里再补发若干次零速（抵御 UDP 丢包）；
//  • 竞态保护：停止后不会再发出旧的非零速度，除非收到新的非零输入；
//  • 看门狗：连续手势超过 watchdog 秒没有新输入 → 自动归零；
//  • nudge：在截止时间后自动停止（同样走可靠停止）。
// 所有方法只在 CameraLink 的串行 queue 上调用；时间由调用方传入（便于测试）。

import Foundation

/// Gimbal:0x01 速度负载里前后两个 int16 字段分别是哪个轴
nonisolated public enum GimbalAxisOrder: String, CaseIterable, Sendable {
    /// [pitch, roll, yaw] —— 实机 Pocket 3 验证（与 lib-osmo-ble PROTOCOL.md 一致）。默认。
    /// Pocket 4 / 4P 仍用这一载荷；轴顺序和正负方向没有在 4/4P 上验证。不发送长焦镜头切换。
    case pitchRollYaw
    /// [yaw, roll, pitch] —— 原 Python gimbal.py 的字段命名（实测轴向互换）。
    case yawRollPitch
}

nonisolated public struct GimbalSpeedController: Sendable {
    public var axisOrder: GimbalAxisOrder = .pitchRollYaw
    public var invertYaw = false
    public var invertPitch = false
    /// 连续手势无输入的自动归零阈值（秒）
    public var watchdog: Double = 0.3
    /// 一次停止总共发送的零速包数（立即 1 次 + 后续 tick 补发），30Hz 下 4 次 ≈ 100ms
    public var stopRepeats = 4
    /// 是否像原项目那样以 30Hz 持续发送（居中时也发）
    /// 静止时是否持续发零速。默认关（OPC/Mimo 只在摇杆按住时发，松手补发几次零速）；
    /// 13:51 日志：常开 30Hz 零速 + 10Hz 心跳请求 ≈ 47 条命令/s，相机命令通道多次「停止应答」。
    public var streaming = false

    public private(set) var yaw = 0.0
    public private(set) var pitch = 0.0
    public private(set) var pendingStops = 0
    private var lastInput: Double = 0
    private var holdUntil: Double?

    public init() {}

    public var isMoving: Bool { yaw != 0 || pitch != 0 }

    /// 当前速度对应的负载（已应用轴顺序与反转）
    public func payload() -> Bytes { Self.payload(yaw: yaw, pitch: pitch, order: axisOrder, invertYaw: invertYaw, invertPitch: invertPitch) }

    public static func payload(yaw: Double, pitch: Double, order: GimbalAxisOrder, invertYaw: Bool = false, invertPitch: Bool = false) -> Bytes {
        let y = invertYaw ? -yaw : yaw, p = invertPitch ? -pitch : pitch
        switch order {
        case .pitchRollYaw: return GimbalProtocol.controlPayload(first: p, third: y)
        case .yawRollPitch: return GimbalProtocol.controlPayload(first: y, third: p)
        }
    }

    private static func clamp(_ v: Double) -> Double {
        let c = max(-1, min(1, v))
        return abs(c) < 0.001 ? 0 : c
    }

    /// 连续输入（摇杆/拖动/键盘/滚动）。返回需要立即发送的负载。
    @discardableResult
    public mutating func set(yaw: Double, pitch: Double, now: Double) -> Bytes {
        let y = Self.clamp(yaw), p = Self.clamp(pitch)
        if y == 0 && p == 0 { return stop() }
        self.yaw = y; self.pitch = p
        lastInput = now; holdUntil = nil; pendingStops = 0
        return payload()
    }

    /// 定时移动（nudge）：duration 秒后自动可靠停止，期间不触发看门狗
    @discardableResult
    public mutating func nudge(yaw: Double, pitch: Double, duration: Double, now: Double) -> Bytes {
        let b = set(yaw: yaw, pitch: pitch, now: now)
        if isMoving { holdUntil = now + duration }
        return b
    }

    /// 可靠停止：立即返回零速负载，并安排后续 tick 再补发 stopRepeats-1 次
    @discardableResult
    public mutating func stop() -> Bytes {
        yaw = 0; pitch = 0; holdUntil = nil
        pendingStops = max(0, stopRepeats - 1)
        return payload()
    }

    /// 立即发送被限速推迟时，补一次待发零速
    public mutating func addPendingStop() { pendingStops += 1 }

    /// 每 40ms 调用一次。返回本拍要发送的负载（nil = 不发）。
    public mutating func tick(now: Double) -> Bytes? {
        if isMoving {
            if let h = holdUntil {
                if now >= h { return stop() }
            } else if now - lastInput > watchdog {
                return stop()
            }
        }
        if pendingStops > 0 { pendingStops -= 1; return payload() }
        if streaming || isMoving { return payload() }
        return nil
    }
}
