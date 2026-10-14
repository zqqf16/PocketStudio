// WiFiProvisioning.swift — 从相机 BLE 读取 SoftAP 的 SSID / 密码，以及加入热点的重试策略。
//
// 命令号来自 DJI Mimo 符号（dji_wifi_get_ssid 0x07/0x07、dji_wifi_get_password 0x07/0x0E）
// 和 OpenPocketCine 对回复格式的描述。请求负载按空处理，尚未用 Pocket 实机或 HCI snoop 确认。
// 新固件可能在 0x12/0x92 之后把回复加密；解析不成「状态 + 长度 + UTF-8」时交给调用方改走手动输入。

import Foundation

nonisolated public enum WiFiFetchQuery: Equatable, Sendable {
    case ssid
    case password

    public var commandName: String { self == .ssid ? "0x07/0x07" : "0x07/0x0E" }
}

/// `[status][len][utf8]`。0xE4 = 热点还没起来（OPC）。长度对不上或不是可打印 UTF-8 = 无法使用（可能已加密）。
nonisolated public enum WiFiStringReply: Equatable, Sendable {
    case value(String)
    case notReady(UInt8)
    case rejected(UInt8)
    case unreadable
}

nonisolated public struct WiFiCredentials: Equatable, Sendable {
    public var ssid: String
    public var password: String
    /// 0x07/0x07 失败或返回 0xE4 时，用蓝牙广播名当 SSID。密码仍来自 0x07/0x0E。
    public var ssidFromAdvertisement: Bool
    public init(ssid: String, password: String, ssidFromAdvertisement: Bool) {
        self.ssid = ssid
        self.password = password
        self.ssidFromAdvertisement = ssidFromAdvertisement
    }
}

nonisolated public enum WiFiFetchFailure: Equatable, Sendable {
    case encrypted
    case ssidUnavailable
    case passwordUnavailable
    case timedOut

    public var userMessage: String {
        switch self {
        case .encrypted: return "相机回复无法解析为文本（新固件可能已加密），请手动填写 Wi-Fi"
        case .ssidUnavailable: return "未能读到 Wi-Fi 名称，蓝牙广播名也不可用"
        case .passwordUnavailable: return "未能读到 Wi-Fi 密码"
        case .timedOut: return "等待相机开启 Wi-Fi 超时"
        }
    }
}

nonisolated public enum WiFiProvisioning {
    /// flags 0x40（request）| cmdSet 0x07 | cmdID。线上字节序是 `40 07 07` / `40 07 0E`。
    public static let getSSIDType: UInt32 = 0x070740
    public static let getPasswordType: UInt32 = 0x0E0740
    public static let target: UInt16 = 0x0702
    public static let notReadyStatus: UInt8 = 0xE4
    public static let confirmCmdSet: UInt8 = 0x07
    public static let confirmCmdID: UInt8 = 0x46
    /// 两次 FFF5 写之间的间隔。要求 100–500ms，取 200ms。
    public static let writeSpacing: TimeInterval = 0.2
    public static let requestTimeout: TimeInterval = 3
    public static let placeholderName = "DJI 设备"

    public static func message(id: UInt16, query: WiFiFetchQuery) -> DJIBLEMessage {
        let type: UInt32 = query == .ssid ? getSSIDType : getPasswordType
        return DJIBLEMessage(target: target, id: id, type: type, payload: [])
    }

    public static func commandFields(_ type: UInt32) -> (flags: UInt8, cmdSet: UInt8, cmdID: UInt8) {
        (UInt8(truncatingIfNeeded: type), UInt8(truncatingIfNeeded: type >> 8), UInt8(truncatingIfNeeded: type >> 16))
    }

    public static func isPairingConfirmation(_ m: DJIBLEMessage) -> Bool {
        let c = commandFields(m.type)
        return c.cmdSet == confirmCmdSet && c.cmdID == confirmCmdID
    }

    /// 相机 0x07/0x46 的 ACK。布局未实机验证：flags 0xC0（response）、负载 `[0x00]`、沿用对方的事务 id、target 仍是 app→wifi。
    public static func pairingConfirmationAck(for incoming: DJIBLEMessage) -> DJIBLEMessage {
        let type = UInt32(0xC0) | (UInt32(confirmCmdSet) << 8) | (UInt32(confirmCmdID) << 16)
        return DJIBLEMessage(target: target, id: incoming.id, type: type, payload: [0x00])
    }

    public static func parseReply(_ payload: Bytes, query: WiFiFetchQuery) -> WiFiStringReply {
        guard let status = payload.first else { return .unreadable }
        if status == notReadyStatus { return .notReady(status) }
        if status != 0 {
            return payload.count <= 4 ? .rejected(status) : .unreadable
        }
        guard payload.count >= 2 else { return .unreadable }
        let len = Int(payload[1])
        guard len > 0, payload.count == 2 + len else { return .unreadable }
        let bytes = Array(payload[2 ..< 2 + len])
        guard let text = String(bytes: bytes, encoding: .utf8), isPlausible(text, query: query) else { return .unreadable }
        return .value(text)
    }

    /// 广播名能不能当 SSID 用。占位名「DJI 设备」不算。
    public static func plausibleSSID(_ name: String?) -> String? {
        guard var name else { return nil }
        name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard name != placeholderName, isPlausible(name, query: .ssid) else { return nil }
        return name
    }

    public static func isPlausible(_ text: String, query: WiFiFetchQuery) -> Bool {
        let n = Array(text.utf8).count
        let limit = query == .ssid ? 32 : 63
        guard n >= 1, n <= limit else { return false }
        guard text.contains(where: { !$0.isWhitespace }) else { return false }
        for scalar in text.unicodeScalars {
            if scalar.value < 0x20 || scalar.value == 0x7F { return false }
        }
        return true
    }
}

/// 配对之后读 SSID / 密码。没有定时器：调用方按返回的 `wait` 推进时钟。
/// 热点未开（0xE4、短错误、超时）时，每项最多发 3 次，并且从 `start` 起不超过 20 秒。
/// SSID 失败或 0xE4 且广播名可用时，立刻改用广播名，不再把重试花在 SSID 上。
/// 回复无法解析则马上停止（可能已加密）。
nonisolated public struct WiFiCredentialFetcher: Sendable {
    public struct Config: Equatable, Sendable {
        public var initialDelay: TimeInterval
        public var retryGap: TimeInterval
        public var writeSpacing: TimeInterval
        public var pollWindow: TimeInterval
        public var maxAttempts: Int
        public init(initialDelay: TimeInterval = 1.5, retryGap: TimeInterval = 1,
                    writeSpacing: TimeInterval = WiFiProvisioning.writeSpacing,
                    pollWindow: TimeInterval = 20, maxAttempts: Int = 3) {
            self.initialDelay = initialDelay
            self.retryGap = retryGap
            self.writeSpacing = writeSpacing
            self.pollWindow = pollWindow
            self.maxAttempts = maxAttempts
        }
    }

    public enum Action: Equatable, Sendable {
        case wait(TimeInterval)
        case send(WiFiFetchQuery, id: UInt16)
        case success(WiFiCredentials)
        case failure(WiFiFetchFailure)
    }

    private enum Pending: Equatable { case readSSID, readPassword }
    private enum Phase: Equatable {
        case idle
        case waiting(until: TimeInterval, pending: Pending)
        case awaiting(WiFiFetchQuery)
        case finished
    }

    private var config: Config
    private var nextID: UInt16
    private var advertised: String?
    private var ssid: String?
    private var ssidFromAdvertisement = false
    private var ssidAttempts = 0
    private var passwordAttempts = 0
    private var startedAt: TimeInterval = 0
    private var lastSendAt: TimeInterval?
    private var phase: Phase = .idle
    private var terminal: Action?

    public init(nextID: UInt16 = 0x8100, config: Config = Config()) {
        self.nextID = nextID
        self.config = config
    }

    public mutating func start(advertisedName: String?, now: TimeInterval) -> Action {
        advertised = WiFiProvisioning.plausibleSSID(advertisedName)
        startedAt = now
        ssidAttempts = 0
        passwordAttempts = 0
        ssid = nil
        ssidFromAdvertisement = false
        lastSendAt = nil
        terminal = nil
        let until = now + config.initialDelay
        phase = .waiting(until: until, pending: .readSSID)
        return .wait(config.initialDelay)
    }

    public mutating func advance(now: TimeInterval) -> Action {
        if let terminal { return terminal }
        guard case let .waiting(until, pending) = phase else { return finish(.failure(.timedOut)) }
        if now + 0.000_001 < until { return .wait(until - now) }
        return begin(pending, now: now)
    }

    public mutating func receive(query: WiFiFetchQuery, payload: Bytes, now: TimeInterval) -> Action {
        if let terminal { return terminal }
        guard case let .awaiting(expected) = phase, expected == query else { return finish(.failure(.timedOut)) }
        return handle(query: query, reply: WiFiProvisioning.parseReply(payload, query: query), now: now)
    }

    public mutating func timedOut(query: WiFiFetchQuery, now: TimeInterval) -> Action {
        if let terminal { return terminal }
        guard case let .awaiting(expected) = phase, expected == query else { return finish(.failure(.timedOut)) }
        return handle(query: query, reply: .notReady(0), now: now)
    }

    private mutating func handle(query: WiFiFetchQuery, reply: WiFiStringReply, now: TimeInterval) -> Action {
        switch query {
        case .ssid:
            switch reply {
            case let .value(text):
                ssid = text
                ssidFromAdvertisement = false
                return begin(.readPassword, now: now)
            case .unreadable:
                return finish(.failure(.encrypted))
            case .notReady, .rejected:
                if let advertised {
                    ssid = advertised
                    ssidFromAdvertisement = true
                    return begin(.readPassword, now: now)
                }
                return schedule(.readSSID, now: now)
            }
        case .password:
            switch reply {
            case let .value(text):
                guard let ssid else { return finish(.failure(.ssidUnavailable)) }
                return finish(.success(WiFiCredentials(ssid: ssid, password: text, ssidFromAdvertisement: ssidFromAdvertisement)))
            case .unreadable:
                return finish(.failure(.encrypted))
            case .notReady, .rejected:
                return schedule(.readPassword, now: now)
            }
        }
    }

    private mutating func schedule(_ pending: Pending, now: TimeInterval) -> Action {
        let attempts = pending == .readSSID ? ssidAttempts : passwordAttempts
        if attempts >= config.maxAttempts {
            return attemptsExhausted(pending, now: now)
        }
        let at = now + config.retryGap
        if at > startedAt + config.pollWindow {
            if pending == .readSSID, let advertised {
                ssid = advertised
                ssidFromAdvertisement = true
                return begin(.readPassword, now: now)
            }
            return finish(.failure(.timedOut))
        }
        phase = .waiting(until: at, pending: pending)
        return .wait(at - now)
    }

    private mutating func attemptsExhausted(_ pending: Pending, now: TimeInterval) -> Action {
        if pending == .readSSID, let advertised {
            ssid = advertised
            ssidFromAdvertisement = true
            return begin(.readPassword, now: now)
        }
        return finish(.failure(pending == .readSSID ? .ssidUnavailable : .passwordUnavailable))
    }

    private mutating func begin(_ pending: Pending, now: TimeInterval) -> Action {
        if now > startedAt + config.pollWindow { return finish(.failure(.timedOut)) }
        if let lastSendAt {
            let earliest = lastSendAt + config.writeSpacing
            if now + 0.000_001 < earliest {
                phase = .waiting(until: earliest, pending: pending)
                return .wait(earliest - now)
            }
        }
        switch pending {
        case .readSSID:
            if ssidAttempts >= config.maxAttempts { return attemptsExhausted(pending, now: now) }
            ssidAttempts += 1
            return emit(.ssid, now: now)
        case .readPassword:
            if passwordAttempts >= config.maxAttempts { return attemptsExhausted(pending, now: now) }
            passwordAttempts += 1
            return emit(.password, now: now)
        }
    }

    private mutating func emit(_ query: WiFiFetchQuery, now: TimeInterval) -> Action {
        let id = nextID
        nextID &+= 1
        lastSendAt = now
        phase = .awaiting(query)
        return .send(query, id: id)
    }

    private mutating func finish(_ action: Action) -> Action {
        phase = .finished
        terminal = action
        return action
    }
}

/// 设置里的手动名称/密码，只在「自动获取」关闭时覆盖缓存和读取。
nonisolated public enum WiFiConnectPlan: Equatable, Sendable {
    case manual(ssid: String, password: String)
    case cached(ssid: String, password: String)
    case fetch
    case needsManualEntry(String)
}

nonisolated public enum WiFiCredentialPlanner {
    public static func plan(autoFetch: Bool, manualSSID: String, manualPassword: String,
                            cachedSSID: String?, cachedPassword: String?, advertisedName: String?) -> WiFiConnectPlan {
        let ssid = manualSSID.trimmingCharacters(in: .whitespacesAndNewlines)
        let manualReady = !ssid.isEmpty && !manualPassword.isEmpty
        if !autoFetch {
            if manualReady { return .manual(ssid: ssid, password: manualPassword) }
            return .needsManualEntry("已关闭自动获取 Wi-Fi，且未填写名称和密码")
        }
        if let cachedSSID, let cachedPassword, !cachedSSID.isEmpty, !cachedPassword.isEmpty {
            if let advertised = WiFiProvisioning.plausibleSSID(advertisedName), advertised != cachedSSID {
                return .fetch
            }
            return .cached(ssid: cachedSSID, password: cachedPassword)
        }
        return .fetch
    }
}

/// CoreWLAN 扫描重试。5.8 GHz / DFS 信标可能要几十秒，截止 90 秒、间隔约 5 秒。
/// 关联被拒绝连续 3 次就停，避免用错误密码打满 90 秒。
nonisolated public struct WiFiScanRetry: Equatable, Sendable {
    public static let deadline: TimeInterval = 90
    public static let interval: TimeInterval = 5
    public static let addressWait: TimeInterval = 15
    public static let maxAssociateFailures = 3

    public enum Failure: Equatable, Sendable { case notFound, associate }
    public enum Step: Equatable, Sendable {
        case retryAfter(TimeInterval)
        case stop
    }

    public var elapsed: TimeInterval
    public var associateFailures: Int

    public init(elapsed: TimeInterval = 0, associateFailures: Int = 0) {
        self.elapsed = elapsed
        self.associateFailures = associateFailures
    }

    public mutating func record(_ failure: Failure) -> Step {
        if case .associate = failure {
            associateFailures += 1
            if associateFailures >= Self.maxAssociateFailures { return .stop }
        }
        if elapsed >= Self.deadline { return .stop }
        return .retryAfter(min(Self.interval, Self.deadline - elapsed))
    }
}

nonisolated public enum WiFiLogMask {
    public static func bullets(_ secret: String) -> String { secret.isEmpty ? "" : "••••" }

    /// 从一行日志里去掉密码本身，以及它的 UTF-8 十六进制（连续或空格分隔）。短于 4 个字符的不处理，避免误伤。
    public static func redact(_ secret: String, in text: String) -> String {
        guard secret.count >= 4 else { return text }
        var out = text.replacingOccurrences(of: secret, with: bullets(secret))
        let raw = Array(secret.utf8)
        let compact = raw.hexString()
        let spaced = raw.hexString(separator: " ")
        if compact.count >= 8 {
            out = out.replacingOccurrences(of: compact, with: "••••", options: .caseInsensitive)
        }
        if spaced.count >= 11 {
            out = out.replacingOccurrences(of: spaced, with: "••••", options: .caseInsensitive)
        }
        return out
    }

    /// 密码应答只留下状态和长度，其余打码。SSID 原样（名称不是密码）。
    public static func hexDump(_ payload: Bytes, query: WiFiFetchQuery) -> String {
        guard query == .password, payload.count > 2 else { return payload.hexString(separator: " ") }
        return Array(payload.prefix(2)).hexString(separator: " ") + " •••• (\(payload.count) bytes)"
    }
}

/// 钥匙串里一条设备凭据的文本。JSON，密码可以含引号和换行。
nonisolated public enum WiFiCredentialBlob {
    public static func encode(ssid: String, password: String) -> String {
        let obj: [String: String] = ["password": password, "ssid": ssid]
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return "" }
        return text
    }

    public static func decode(_ raw: String) -> (ssid: String, password: String)? {
        guard let data = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: String],
              let ssid = obj["ssid"], let password = obj["password"],
              !ssid.isEmpty, !password.isEmpty else { return nil }
        return (ssid, password)
    }
}
