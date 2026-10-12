// GimbalProtocol.swift — 云台 (PTZ) 控制（移植自 pocket3/gimbal.py，
// 载荷在 Pocket 4 / 4P 上保持不变。轴顺序与正负方向只在 Pocket 3 上实机确认，4/4P 未验证。
// 不实现长焦镜头切换。

import Foundation
// 并参考 lib-osmo-ble PROTOCOL.md 增加回中 / 模式等实验命令）

nonisolated public struct GimbalState: Equatable, Sendable {
    public var yaw = 0.0, pitch = 0.0, roll = 0.0
    public var timestamp: UInt16 = 0
    public var modeByte: UInt8? = nil
    public var nativePitch = 0.0
    public var valid = false
    public init() {}

    /// Gimbal:0x05 姿态推送（Pocket 3 实机约 10Hz、49–50 字节）。
    /// OpenPocketCine 抓包结论：i16 @4 = yaw（0.1°）；i16 @20 = 俯仰（0.1°，**正值 = 向下**，取反后上为正）；
    /// i16 @0 = 原生 pitch（= 180° − 抬头角，供 0x14 使用）；@6 高 2 位 = 模式族（0 方向锁定 / 1 FPV / 2 跟随）。
    /// 原 Python 项目按 @0=yaw @2=roll @4=pitch 解析 —— 实机日志里 @0 = 0xFA07(−152.9°) 显然不是 yaw。
    /// `legacyLayout` = true 时沿用原项目解析（设置项「旧版姿态解析」）。
    public mutating func update(payload p: Bytes, legacyLayout: Bool = false) {
        if !legacyLayout, p.count >= 22 {
            yaw = Double(p.le16s(4)) / 10.0
            pitch = -Double(p.le16s(20)) / 10.0
            roll = Double(p.le16s(2)) / 10.0   // 未证实；OPC 用四元数求 roll
            nativePitch = Double(p.le16s(0)) / 10.0
            modeByte = p[6]
            valid = true
            return
        }
        guard p.count >= 6 else { return }
        yaw = Double(p.le16s(0)) / 10.0
        roll = Double(p.le16s(2)) / 10.0
        pitch = Double(p.le16s(4)) / 10.0
        if p.count >= 7 { modeByte = p[6] }
        if p.count >= 14 { timestamp = p.le16(12) }
        valid = true
    }

    /// 由 @6 高 2 位推断的当前云台模式
    public var mode: GimbalMode? {
        guard let b = modeByte else { return nil }
        switch b >> 6 { case 0: return .directionLock; case 1: return .fpv; case 2: return .follow; default: return nil }
    }

    public var description: String {
        String(format: "Gimbal(yaw=%.1f° pitch=%.1f° roll=%.1f°)", yaw, pitch, roll)
    }
}

/// 云台模式：0x04/0x4C [mode, 0x08]（OpenPocketCine Pocket 3 实机）
nonisolated public enum GimbalMode: UInt8, CaseIterable, Sendable, Identifiable {
    case directionLock = 0x00, fpv = 0x01, follow = 0x02
    public var id: UInt8 { rawValue }
    public var displayName: String {
        switch self { case .directionLock: return "方向锁定"; case .follow: return "跟随"; case .fpv: return "FPV" }
    }
}

/// 云台转动速度：0x04/0x50 SET 00 05 01 <v>
nonisolated public enum GimbalSpeedSetting: UInt8, CaseIterable, Sendable {
    case fast = 0, normal = 1, slow = 2
    public var displayName: String { self == .fast ? "快" : self == .normal ? "默认" : "慢" }
}

nonisolated public enum GimbalProtocol {
    public static let cmdControl: UInt8 = 0x01
    public static let cmdAttitude: UInt8 = 0x05
    public static let cmdSuspendResume: UInt8 = 0x0D
    public static let cmdAbsAngle: UInt8 = 0x14
    public static let cmdSetMode: UInt8 = 0x4C

    public static let speedCenter = 1024
    public static let speedMin = 0
    public static let speedMax = 2048
    public static let controlFlags: UInt16 = 0x8000
    public static let controlExtra: UInt16 = 0x0042
    /// 原项目约 30Hz 持续发送
    /// 25Hz（OPC GimbalStick.streamInterval = 0.04）
    public static let sendInterval = 0.04
    public static let minInterval = 0.04

    /// -1…1 → 0…2048（与 Python int() 一样向零截断）
    public static func speedValue(_ normalized: Double) -> UInt16 {
        let n = max(-1.0, min(1.0, normalized))
        let v = Int(Double(speedCenter) + n * Double(speedMax - speedCenter))
        return UInt16(max(speedMin, min(speedMax, v)))
    }

    /// Gimbal:0x01 速度控制负载（10 字节）：[字段0, roll(=0), 字段2, 0x8000, 0x0042]
    /// 字段0/字段2 对应哪个轴由 GimbalAxisOrder 决定（见 GimbalSpeedController）。
    /// roll 字段与原项目一致写 0。
    public static func controlPayload(first: Double, third: Double) -> Bytes {
        var p = Bytes()
        p.appendLE16(speedValue(first))
        p.appendLE16(0)
        p.appendLE16(speedValue(third))
        p.appendLE16(controlFlags)
        p.appendLE16(controlExtra)
        return p
    }

    // MARK: 模式 / 回中 / 翻转（0x04/0x4C，flags 0x40，相机应答 0x80 00）
    // 来源：OpenPocketCine Commands.swift（Mimo 抓包，Pocket 3 实机验证）。
    // ⚠️ 旧版用 lib-osmo-ble 的 0x14「绝对角度 (0,0,0)，时长 25.5s」当回中：
    //    0x14 的字段实为 [yaw, roll, 原生pitch]，原生 pitch 0 ≈ 抬头到极限，于是云台持续上仰 25 秒 —— 实机 bug 的根因。

    public static let cmdParams: UInt8 = 0x50
    public static var recenterPayload: Bytes { [0xFE, 0x08] }
    public static var flipPayload: Bytes { [0xFE, 0x09] }
    public static func setModePayload(_ mode: GimbalMode) -> Bytes { [mode.rawValue, 0x08] }
    public static func speedSettingPayload(_ s: GimbalSpeedSetting) -> Bytes { [0x00, 0x05, 0x01, s.rawValue] }
    /// 0x14 定时移动的「打断」：零角度、模式 04、0.1 秒 —— 用于确保没有残留的定时运动
    public static var timedMoveStopPayload: Bytes { [0, 0, 0, 0, 0, 0, 0x04, 0x01] }
    /// 0x03/0xDA 云台初始化（OpenPocketCine register() 在握手后发送）→ 接收方 type 3 id 0
    public static let initCmdSet: UInt8 = 0x03, initCmdID: UInt8 = 0xDA, initReceiverType: UInt8 = 0x03
    public static var initPayload: Bytes { [0x05, 0xFF, 0xFF, 0xFF, 0xFF] }
}
