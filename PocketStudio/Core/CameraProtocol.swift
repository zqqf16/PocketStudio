// CameraProtocol.swift — 相机状态解析与命令（移植自 pocket3/camera.py）
//
// 相机推送：
//  Camera:0x80 (60B, ~12Hz) 主状态：byte0 低 4 位=模式，byte1 bit0=录制中
//  Camera:0xDC (22B, ~3Hz)  存储：byte0 bit0=SD 卡插入
//  Camera:0xA0 (28B)        状态：offset 6 LE16=录制秒数
//  ESC:0x02    (34B, ~1Hz)  电池：offset 1 LE16=毫伏，offset 20=电量百分比

/// 拍摄模式的语义名。线上字节（0x02/0xE1 与 Camera:0x80 @57）由 `DeviceProfile.modeTable` 决定，
/// 不再把 `rawValue` 当作所有机型共用的模式号。
/// ⚠️ 不要枚举/扫描其它取值：OpenPocketCine 报告扫描 0xE1 曾把 Nano 卡死需重启。
/// `rawValue` 只作稳定标识：Pocket 3 的取值与旧版一致；`livePhoto` 的 0x4D 仅在 Pocket 4P 的模式表里启用。
nonisolated public enum CameraMode: UInt8, CaseIterable, Sendable, Identifiable, Hashable {
    case slowMotion = 0x00, video = 0x01, timelapse = 0x02, photo = 0x05
    case hyperlapse = 0x0A, panorama = 0x0C, lowLight = 0x28
    case livePhoto = 0x4D
    public var id: UInt8 { rawValue }

    /// M 键 / 菜单可切换的模式
    public static let switchable: [CameraMode] = [.photo, .video, .slowMotion, .timelapse]

    public var englishName: String {
        switch self {
        case .photo: return "Photo"; case .video: return "Video"; case .slowMotion: return "SlowMo"
        case .timelapse: return "Timelapse"; case .hyperlapse: return "Hyperlapse"; case .panorama: return "Panorama"
        case .lowLight: return "LowLight"; case .livePhoto: return "LivePhoto"
        }
    }
    public var displayName: String {
        switch self {
        case .photo: return "拍照"; case .video: return "录像"; case .slowMotion: return "慢动作"
        case .timelapse: return "延时摄影"; case .hyperlapse: return "移动延时"; case .panorama: return "全景"
        case .lowLight: return "夜景录像"; case .livePhoto: return "实况照片"
        }
    }
    public var symbol: String {
        switch self {
        case .photo: return "camera"; case .video: return "video"; case .slowMotion: return "tortoise"
        case .timelapse, .hyperlapse: return "timelapse"; case .panorama: return "pano"; case .lowLight: return "moon"
        case .livePhoto: return "livephoto"
        }
    }
    /// 拍照类模式：快门 = 0x02/0x01 [01]（Pocket 4P 实况照片同样走 0x01，OpenPocketCine）
    /// 侧栏短标签
    public var shortName: String {
        switch self {
        case .slowMotion: return "慢动作"; case .video: return "录像"; case .photo: return "拍照"; case .timelapse: return "延时"
        case .livePhoto: return "实况"
        default: return displayName
        }
    }
    public var isStill: Bool { self == .photo || self == .panorama || self == .livePhoto }
    /// Pocket 3 延时摄影的开始/停止走 0x02/0x01 [01]/[00]，而不是录像的 0x02/0x02
    public var usesShutterForRecording: Bool { self == .timelapse || self == .hyperlapse }
}

/// 0x02/0xE1 的已知取值。没有登记的模式不会发送——禁止扫描未知枚举。
nonisolated public struct ShootingModeTable: Sendable, Equatable {
    public var wire: [CameraMode: UInt8]
    public init(wire: [CameraMode: UInt8]) { self.wire = wire }

    public func wireID(for mode: CameraMode) -> UInt8? { wire[mode] }

    public func mode(forWire id: UInt8) -> CameraMode? {
        for (mode, value) in wire where value == id { return mode }
        return nil
    }

    /// 侧栏顺序。实况照片只在表里有取值时出现。
    public var switchable: [CameraMode] {
        var list: [CameraMode] = [.slowMotion, .video, .photo]
        if wire[.livePhoto] != nil { list.append(.livePhoto) }
        list.append(.timelapse)
        return list.filter { wire[$0] != nil }
    }

    /// Pocket 3 实机：慢动作 00、录像 01、延时 02、拍照 05，以及已有的移动延时 / 全景 / 夜景。
    public static let pocket3 = ShootingModeTable(wire: [
        .slowMotion: 0x00, .video: 0x01, .timelapse: 0x02, .photo: 0x05,
        .hyperlapse: 0x0A, .panorama: 0x0C, .lowLight: 0x28,
    ])

    /// Pocket 4 的 0xE1 取值没有公开抓包。复用 Pocket 3，不另猜、不扫描。
    public static let pocket4 = pocket3

    /// Pocket 4P：拍照 0x17、实况照片 0x4D、慢动作 0x00（OpenPocketCine 调查）。
    /// 录像 / 延时 / 移动延时 / 全景 / 夜景没有单独的公开取值，暂用 Pocket 3，标为未验证。
    public static let pocket4P = ShootingModeTable(wire: [
        .slowMotion: 0x00, .video: 0x01, .timelapse: 0x02, .photo: 0x17,
        .livePhoto: 0x4D,
        .hyperlapse: 0x0A, .panorama: 0x0C, .lowLight: 0x28,
    ])
}

/// Pocket 4P 的 SuperPhoto 不是另一个 0xE1 模式（OpenPocketCine P01）。
/// 它留在拍照模式 0x17 内，用 0x02/0x12 选择标准/超清与画幅；超清快门载荷是 0x0F。
/// TODO: 本应用尚未实机确认，不发送 0x12，也不把它做成可切换的 0xE1 值。
nonisolated public enum Pocket4PSuperPhoto {
    public static let formatCommand: UInt8 = 0x12
    public static let standard16x9: Bytes = [0x00, 0x01]
    public static let superPhoto16x9: Bytes = [0x04, 0x01]
    public static let superPhoto1x1: Bytes = [0x04, 0x03]
    public static let shutter: Bytes = [0x0F]
}

/// 连接时确定的机型。模式号、UDP 端口、存储字段是否按 SD 卡解析、界面名称都从这里来。
/// 预览编码不在这里写死：H.264 / HEVC 以码流参数集为准（见 `VideoCodec`）。
nonisolated public struct DeviceProfile: Sendable, Equatable {
    public var model: PocketModel
    public var isDJI: Bool
    public var vendor: BLEVendor
    public var displayName: String
    public var udpPort: UInt16
    /// Pocket 3 的 0x80 @5/@9、0xDC @6/@10 是 SD 卡 MiB。
    /// Pocket 4 / 4P 有机内存储，同一偏移未确认，打开会显示垃圾容量。
    public var parsesSDCapacity: Bool
    public var hasInternalStorage: Bool
    public var modeTable: ShootingModeTable
    /// 公开资料中的预览编码。解码器仍等参数集，不用这个字段去锁编码。
    public var documentedPreviewCodec: VideoCodec
    /// 模式号是否整表沿用 Pocket 3（Pocket 4 为真；4P 只有拍照 / 实况 / 慢动作有公开值）。
    public var modeIDsUnverified: Bool

    public var isPocketSeries: Bool { model != .unknown }

    /// 访问单元前的 16 字节 `00 00 01 ff` 帧头。只有 Pocket 4 / 4P 的公开资料这么写。
    /// Pocket 3 在 UDP 层去掉 12 字节分片头后就是 Annex-B；对它做帧头剥离会把起始码误判成长度头，
    /// 画面连续报 VideoToolbox -12909。
    public var usesLiveViewFrameHeader: Bool { model == .pocket4 || model == .pocket4P }

    public static let pocket3 = DeviceProfile(
        model: .pocket3, isDJI: true, vendor: .dji, displayName: "Osmo Pocket 3",
        udpPort: DJIUDPFrame.cameraPort, parsesSDCapacity: true, hasInternalStorage: false,
        modeTable: .pocket3, documentedPreviewCodec: .h264, modeIDsUnverified: false)

    public static let pocket4 = DeviceProfile(
        model: .pocket4, isDJI: true, vendor: .dji, displayName: "Osmo Pocket 4",
        udpPort: DJIUDPFrame.cameraPort, parsesSDCapacity: false, hasInternalStorage: true,
        modeTable: .pocket4, documentedPreviewCodec: .hevc, modeIDsUnverified: true)

    public static let pocket4P = DeviceProfile(
        model: .pocket4P, isDJI: true, vendor: .dji, displayName: "Osmo Pocket 4P",
        udpPort: DJIUDPFrame.cameraPort, parsesSDCapacity: false, hasInternalStorage: true,
        modeTable: .pocket4P, documentedPreviewCodec: .hevc, modeIDsUnverified: true)

    /// 还没识别到机型。模式号与 SD 解析保持 Pocket 3，这样「跳过蓝牙」的 Pocket 3 行为不变。
    public static let unidentified = DeviceProfile(
        model: .unknown, isDJI: false, vendor: .none, displayName: "Osmo Pocket",
        udpPort: DJIUDPFrame.cameraPort, parsesSDCapacity: true, hasInternalStorage: false,
        modeTable: .pocket3, documentedPreviewCodec: .h264, modeIDsUnverified: true)

    public static func detect(manufacturerData: Bytes?, localName: String?) -> DeviceProfile {
        var vendor: BLEVendor = .none
        var modelByte: UInt8?
        if let raw = manufacturerData, raw.count >= 2 {
            let cid = Array(raw.prefix(2))
            if cid == DJIBLE.djiCompanyID { vendor = .dji }
            else if cid == DJIBLE.xtraCompanyID { vendor = .xtra }
            if vendor != .none, raw.count >= 3 { modelByte = raw[2] }
        }
        let named = model(fromAdvertisedName: localName)
        let model: PocketModel
        switch modelByte {
        case 0x20: model = .pocket3
        case 0x21: model = .pocket4
        case 0x22: model = .pocket4P
        default: model = named
        }
        let recognized = vendor != .none || model != .unknown
        guard recognized else { return .unidentified }
        var profile: DeviceProfile
        switch model {
        case .pocket3: profile = .pocket3
        case .pocket4: profile = .pocket4
        case .pocket4P: profile = .pocket4P
        case .unknown:
            profile = .unidentified
            profile.isDJI = true
            profile.displayName = "Osmo Pocket"
        }
        if vendor != .none { profile.vendor = vendor }
        profile.udpPort = profile.vendor == .xtra ? DJIUDPFrame.xtraPort : DJIUDPFrame.cameraPort
        profile.isDJI = true
        return profile
    }

    /// 广播名 / Wi-Fi 名。先匹配 4P / 4 Pro，再匹配 4，最后 3。
    public static func model(fromAdvertisedName name: String?) -> PocketModel {
        guard let name else { return .unknown }
        let n = name.lowercased().filter { $0.isLetter || $0.isNumber }
        if n.contains("pocket4p") || n.contains("pocket4pro") { return .pocket4P }
        if n.contains("pocket4") { return .pocket4 }
        if n.contains("pocket3") { return .pocket3 }
        return .unknown
    }
}

nonisolated public enum PocketModel: String, Sendable, Equatable {
    case pocket3, pocket4, pocket4P, unknown
}

nonisolated public enum BLEVendor: String, Sendable, Equatable {
    case dji, xtra, none
}

nonisolated public struct CameraStatus: Equatable, Sendable {
    public var modeRaw: UInt8? = nil
    public var recording = false
    public var sdInserted = false
    public var sdFreeMB = 0
    public var sdTotalMB = 0
    public var recordingTimeS = 0
    public var photoCount = 0        // 原项目亦未解析，保留字段
    public var batteryPercent = -1
    public var batteryMilliVolt = 0
    /// 解析 0x80 / 0xDC 时用的机型。默认 Pocket 3，现有日志字节的单测不变。
    public var profile: DeviceProfile = .pocket3
    public var raw80: Bytes = []
    public var rawDC: Bytes = []
    public var rawBattery: Bytes = []
    public var hasCameraStatus = false
    public var hasStorageStatus = false
    /// Camera:0x80 u32@0 原始标志
    public var stateFlags: UInt32 = 0
    /// bit30：相机处于回放（OPC CameraStatus.inPlayback）。实机日志：拍照后约 4s 置位，同时开始 10Hz 推送 Camera:0x82（回放参数），实时画面停止。
    public var inPlayback: Bool { stateFlags & 0x4000_0000 != 0 }
    /// bit18/19：拍照处理中（实机日志拍照瞬间 0x80→0x84→0x8C；含义推断，未证实）
    public var capturing: Bool { stateFlags & 0x000C_0000 != 0 }
    /// 收到 Camera:0x82（回放参数推送）的次数
    public var playbackPushes = 0

    public init() {}

    public var mode: CameraMode? { modeRaw.flatMap { profile.modeTable.mode(forWire: $0) } }
    public var modeName: String {
        guard let m = modeRaw else { return "未知" }
        if let known = profile.modeTable.mode(forWire: m) { return known.displayName }
        return String(format: "模式 0x%02X", m)
    }

    /// 与原项目 summary() 一致的英文摘要（日志用）
    public var summary: String {
        var parts = ["Mode=\(modeRaw.map { profile.modeTable.mode(forWire: $0)?.englishName ?? String(format: "Mode%02X", $0) } ?? "Unknown")"]
        if recording { parts.append("REC \(recordingTimeS)s") }
        if batteryPercent >= 0 { parts.append("Bat=\(batteryPercent)%") }
        if profile.parsesSDCapacity, sdInserted { parts.append("SD=\(sdFreeMB)MB free") }
        else if profile.hasInternalStorage { parts.append("Internal") }
        return parts.joined(separator: " | ")
    }

    /// 应用一条 DUML 包；返回是否被识别。`profile` 非空时改用该机型的存储/模式表。
    @discardableResult
    public mutating func apply(_ pkt: DUMLPacket, profile: DeviceProfile? = nil) -> Bool {
        if let profile { self.profile = profile }
        let p = pkt.payload
        switch (pkt.cmdSet, pkt.cmdID) {
        case (2, 0x80):
            // OpenPocketCine CameraStatus.swift：u32 flags @0，bit7 = 录制中；@5/@9 存储总量/剩余 MiB；
            // @29 u16 = 已录制秒数；@57 = 拍摄模式（0xE1 取值）。
            // 原 Python 用 byte0 低 4 位当模式、byte1 bit0 当录制状态 —— 实机日志 01 02 80 00 … 证明不对。
            // Pocket 4/4P 有机内存储，@5/@9 是否仍是 SD 卡未确认，机型不允许解析时不写入容量。
            guard p.count >= 13 else { return false }
            raw80 = p
            recording = (p[0] & 0x80) != 0
            stateFlags = p.le32(0)
            if p.count >= 31 { recordingTimeS = Int(p.le16(29)) }
            modeRaw = p.count >= 58 ? p[57] : nil
            if self.profile.parsesSDCapacity {
                let total = Int(p.le32(5)), free = Int(p.le32(9))
                if (1 ... 50_000_000).contains(total) { sdTotalMB = total; sdInserted = true }
                if (0 ... 50_000_000).contains(free) { sdFreeMB = free }
            } else {
                sdInserted = false; sdTotalMB = 0; sdFreeMB = 0
            }
            hasCameraStatus = true
            return true
        case (2, 0x82):
            playbackPushes += 1
            return true
        case (2, 0xDC):
            // [total][free] u32 MiB：Pocket 3 上 SD @6/@10。4/4P 不把这些字节当成 SD 卡。
            guard p.count >= 14 else { return false }
            rawDC = p
            if self.profile.parsesSDCapacity {
                let total = Int(p.le32(6))
                sdInserted = total > 0
                if total > 0 { sdTotalMB = total; sdFreeMB = Int(p.le32(10)) }
                hasStorageStatus = true
            }
            return true
        case (13, 0x02):
            guard p.count >= 3 else { return false }
            rawBattery = p
            batteryMilliVolt = Int(p.le16(1))
            if p.count >= 21, p[20] <= 100 { batteryPercent = Int(p[20]) }
            return true
        case (2, 0xA0):
            // 原项目：offset 6 = 录制秒数（Pocket 3 上未证实；0x80 @29 优先）
            guard p.count >= 10 else { return false }
            if !hasCameraStatus { recordingTimeS = Int(p.le16(6)) }
            return true
        default:
            return false
        }
    }
}

/// 相机命令构造（App(2,0) → Camera(1,0)，cmdSet 2）
nonisolated public enum CameraCommand {
    public struct Spec: Equatable, Sendable {
        public var receiverType: UInt8 = DUMLDevice.camera
        public var receiverID: UInt8 = 0
        public var cmdSet: UInt8 = DUMLCmdSet.camera
        public var cmdID: UInt8
        public var payload: Bytes = []
        public var cmdType: UInt8 = DUMLCmdType.request   // flags 0x40
    }

    // 以下取值来自 OpenPocketCine（Pocket 3 实机抓包，Commands.swift）。全部用 flags 0x40（request，相机会应答）。
    /// 快门：0x02/0x01 [01]。录像模式下相机应答 d9。
    public static let takePhoto = Spec(cmdID: 0x01, payload: [0x01])
    /// 录像开始/停止：0x02/0x02 [01]/[00]（不是开关；录制中再发 [01] 应答 df）
    public static let startRecording = Spec(cmdID: 0x02, payload: [0x01])
    public static let stopRecording = Spec(cmdID: 0x02, payload: [0x00])
    /// 延时摄影开始/停止：0x02/0x01 [01]/[00]
    public static let shutterStop = Spec(cmdID: 0x01, payload: [0x00])
    /// 拍摄模式：0x02/0xE1 [mode]。表里没有的模式返回 nil，调用方不得改发其它字节。
    public static func setMode(_ mode: CameraMode, profile: DeviceProfile = .pocket3) -> Spec? {
        guard let id = profile.modeTable.wireID(for: mode) else { return nil }
        return Spec(cmdID: 0xE1, payload: [id])
    }

    /// 退出回放：0x02/0x0C 01 01 00 00（OPC exitPlayback；进入为 …01）
    public static let exitPlayback = Spec(cmdID: 0x0C, payload: [0x01, 0x01, 0x00, 0x00])

    /// 根据当前状态选择正确的录制命令
    public static func recordCommand(start: Bool, mode: CameraMode?) -> Spec {
        if mode?.usesShutterForRecording == true { return start ? takePhoto : shutterStop }
        return start ? startRecording : stopRecording
    }

    /// 相机应答第一个字节的含义
    public static func describeReply(cmdID: UInt8, payload: Bytes) -> String {
        guard let code = payload.first else { return "空应答" }
        switch code {
        case 0x00: return "成功"
        case 0xD9: return "当前模式不支持（如在录像模式下拍照）"
        case 0xDF: return "已在录制中"
        default: return String(format: "错误码 0x%02X", code)
        }
    }

    /// Camera:0x8E。Mimo 符号名是参数选项（`dji_camera_parameter_option`），不是链路心跳。保持 ≤1Hz。
    public static let heartbeat = Spec(cmdID: 0x8E, payload: [0x00, 0x01, 0x14, 0x00], cmdType: DUMLCmdType.request)
    public static let stateQuery = Spec(cmdID: 0xA0, cmdType: DUMLCmdType.request)
    public static let statusPoll = Spec(cmdID: 0x61, cmdType: DUMLCmdType.request)

    /// Mimo `AppRequestIFrame` / `dji_camera_get_app_request_i_frame_req`（Camera:0xB3，flags 0x40）。
    /// dji-firmware-tools 只登记了名字「Request IFrame」，没有字段。模板名是 GET，故负载先用空。
    /// OpenPocketCine 把 0x09/0xA8 当作 Pocket 家族的 PLI，没有记录 0xB3。未实机验证；与 0xA8 一起发，且调用方限频。
    public static let requestIFrame = Spec(cmdID: 0xB3, payload: [])
}

/// 连接期间的保活策略。默认 `.mimo`。两种模式都保留已在实机上与画面共存、且 OPC 认为维持视频所必需的注册：
/// General:0x88 1Hz、0x81/0x82 每 5s，以及 Camera:0x8E ≤1Hz（参数轮询）。
nonisolated public enum LinkKeepalive: String, Sendable, Equatable {
    /// General:0x0E 1Hz。不发送 General:0x4F。
    case mimo
    /// 旧行为：General:0x4F → DM368(2) 1Hz（版本配置分块读取）。不发送 0x0E。
    case legacy

    /// 诊断行里的短标记
    public var diagnosticToken: String { self == .mimo ? "0x0E" : "旧0x4F" }

    /// 连接成功或切换设置时写入文本日志
    public var sessionLog: String {
        switch self {
        case .mimo:
            return "链路保活：Mimo。每秒 1 次 General:0x0E（空负载、flags 0x40、发往 Camera）。视频注册 General:0x88 保持 1Hz，相机参数 Camera:0x8E 保持 1Hz。0x4F 版本配置读取已关闭。0x0E 的接收方和空负载尚未实机验证。"
        case .legacy:
            return "链路保活：旧版。每秒 1 次 General:0x4F → DM368(2)（版本配置分块读取，相机通常回约 265 字节 XML）。General:0x0E 关闭。0x88 与 0x8E 与 Mimo 模式相同。用于实机对比。"
        }
    }
}

/// 链路层 General 命令（cmdSet 0），与相机参数轮询分开。
nonisolated public enum LinkCommand {
    /// General:0x0E `dji_general_heartbeat`。
    /// 负载为空：dji-firmware-tools 写明 PC 发起的心跳请求通常没有 Group/文本（应答才可能带 1 字节 group）。
    /// 接收方假设为 Camera(1,0)。Mimo `HeartbeatLogic` 的对端没有从符号里解出；lib-osmo-ble 不涉及这条 Wi-Fi 命令。未实机验证。
    /// flags 0x40：期待一个短应答，便于确认相机是否认识它。不要高于 1Hz。
    public static let heartbeat = CameraCommand.Spec(
        receiverType: DUMLDevice.camera, receiverID: 0,
        cmdSet: DUMLCmdSet.general, cmdID: 0x0E,
        payload: [], cmdType: DUMLCmdType.request)
}
