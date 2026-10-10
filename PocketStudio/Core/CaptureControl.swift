// CaptureControl.swift — 统一快门 + 模式选择（纯逻辑，Linux 单测覆盖）

nonisolated public enum ShutterAction: Equatable, Sendable {
    case takePhoto, startRecording, stopRecording
}

nonisolated public enum ShutterStyle: Equatable, Sendable {
    /// 白色实心圆（拍照）
    case photo
    /// 红色圆（录像 / 慢动作 / 延时待机），symbol 为角标
    case record(symbol: String?)
    /// 红色圆角方块（录制中，点按停止）
    case stop
}

nonisolated public enum Shutter {
    /// 分段控件顺序（与 iOS 相机相同从左到右）
    public static let segments: [CameraMode] = [.slowMotion, .video, .photo, .timelapse]

    public static func action(mode: CameraMode?, recording: Bool) -> ShutterAction {
        if recording { return .stopRecording }
        if mode?.isStill == true { return .takePhoto }
        return .startRecording
    }

    public static func style(mode: CameraMode?, recording: Bool) -> ShutterStyle {
        switch action(mode: mode, recording: recording) {
        case .takePhoto: return .photo
        case .stopRecording: return .stop
        case .startRecording:
            switch mode {
            case .slowMotion: return .record(symbol: "slowmo")
            case .timelapse, .hyperlapse: return .record(symbol: "timelapse")
            case .lowLight: return .record(symbol: "moon.fill")
            default: return .record(symbol: nil)
            }
        }
    }

    public static func tooltip(mode: CameraMode?, recording: Bool) -> String {
        switch action(mode: mode, recording: recording) {
        case .takePhoto: return "拍照（空格 / P）"
        case .startRecording: return "开始\(mode?.displayName ?? "录制")（空格 / O）"
        case .stopRecording: return "停止相机录制（空格 / O）"
        }
    }
}

/// 模式选择：乐观更新 → 由状态推送（0x80 @57）/ 应答核对
nonisolated public struct CaptureModeState: Sendable {
    public private(set) var reported: CameraMode? = nil
    public private(set) var pending: CameraMode? = nil
    private var pendingAt = 0.0
    /// 乐观显示的最长时间；超时仍未被状态确认则回到相机报告的模式
    public var pendingTimeout = 3.0
    public init() {}

    public mutating func request(_ m: CameraMode, now: Double) { pending = m; pendingAt = now }

    /// 状态推送到达
    public mutating func report(_ m: CameraMode?, now: Double) {
        reported = m
        if let p = pending, p == m { pending = nil }
        else if pending != nil, now - pendingAt > pendingTimeout { pending = nil }
    }

    /// 切换模式的应答：失败立即回退
    public mutating func ack(success: Bool) { if !success { pending = nil } }

    public mutating func tick(now: Double) { if pending != nil, now - pendingAt > pendingTimeout { pending = nil } }

    public var displayed: CameraMode? { pending ?? reported }
}
