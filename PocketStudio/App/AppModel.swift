// AppModel.swift — 连接编排与全局状态（对应原项目 web.py ConnectionManager + main.py 流程）
//
// 连接步骤（与原项目 Web UI 一致）：
//  0 蓝牙扫描 → 1 配对 → 2 等待相机 Wi-Fi 开启(~20s) → 3 加入 Wi-Fi → 4 检查相机可达
//  → 5 UDP 握手 → 6 启动视频 → 7 已连接
// 蓝牙在加入 Wi-Fi 期间保持连接（原项目注释：否则相机可能关闭 AP），成功后断开。

import Foundation
import AppKit
import CoreMedia

extension Notification.Name {
    static let modelChanged = Notification.Name("PocketStudio.modelChanged")
    static let logAppended = Notification.Name("PocketStudio.logAppended")
}

enum StepStatus { case pending, active, done, failed, skipped }

struct ConnectStep {
    let title: String
    let symbol: String
    var status: StepStatus = .pending
    var detail: String = ""
}

enum ConnectionPhase: Equatable {
    case idle, connecting, connected, failed(String)
}

/// 在 CameraLink 的后台 queue 上创建，主线程展示 → nonisolated + Sendable
nonisolated struct DUMLLogEntry: Sendable {
    let time: Date
    let direction: DUMLDirection
    let packet: DUMLPacket
    var route: String { "\(DUMLDevice.name(packet.senderType))(\(packet.senderID))→\(DUMLDevice.name(packet.receiverType))(\(packet.receiverID))" }
    var command: String { String(format: "%@:0x%02x", DUMLCmdSet.name(packet.cmdSet), packet.cmdID) }
    /// 高频推送（心跳/状态/ACK 窗口等），可在调试页过滤
    var isHighFrequency: Bool {
        let p = packet
        switch (p.cmdSet, p.cmdID) {
        case (0, 0x4F), (0, 0x0E), (2, 0x8E), (2, 0x80), (2, 0xDC), (2, 0xA0), (2, 0x61), (4, 0x01), (4, 0x05), (13, 0x02), (0, 0x81), (0, 0x82), (0, 0x88): return true
        default: return false
        }
    }
}

/// 隔离：@MainActor（所有 UI 状态）。后台回调（CameraLink / VideoPipeline 的 @Sendable 闭包）
/// 一律通过 Task { @MainActor in … } 回到主线程；DUML 日志经线程安全的 DUMLBuffer 批量转交。
@MainActor
final class AppModel {
    static let shared = AppModel()
    let settings = AppSettings.shared
    let ble = BLEManager()
    let wifi = WiFiManager()
    let video = VideoPipeline()
    private(set) var link: CameraLink?

    private(set) var phase: ConnectionPhase = .idle
    private(set) var steps: [ConnectStep] = AppModel.freshSteps()
    private(set) var snapshot = LinkSnapshot()
    private(set) var videoStats = VideoPipeline.Stats(fps: 0, kbps: 0, frames: 0, bytes: 0, width: 0, height: 0)
    private(set) var bleBattery: Int?
    private(set) var textLog: [String] = []
    private(set) var dumlLog: [DUMLLogEntry] = []
    private(set) var isLocalRecording = false
    private(set) var lastSavedFile: URL?
    private(set) var lastRecordingFile: URL?
    var logPaused = false

    /// 手动加入 Wi-Fi 引导状态（程序化加入失败时显示）
    private(set) var manualWiFiReason: String?
    /// 连接页上的「读取中 / 加入中 / 失败：…」
    private(set) var wifiProvisionStatus: String = ""
    private var activeSSID = ""
    private var activePassword = ""
    private var activeDeviceID = ""
    private var credentialSource: WiFiCredentialOrigin = .none
    private enum WiFiCredentialOrigin { case none, manual, cache, camera }

    /// 这一次连接实际使用的热点。还没读到时回落到设置里的手填值。
    var displayedSSID: String { activeSSID.isEmpty ? settings.ssid : activeSSID }
    var displayedPassword: String { activePassword.isEmpty ? settings.password : activePassword }
    private var manualWiFiCheckRequested = false

    private var connectTask: Task<Void, Never>?
    private let pending = DUMLBuffer()
    private var changePosted = false
    private var statsTimer: Timer?
    private var modeIndex = 1 // 原项目从「录像」开始循环
    /// 模式选择（乐观更新 + 状态核对）
    private(set) var captureMode = CaptureModeState()
    /// 本次连接识别到的机型。未识别前界面用「Osmo Pocket」，不写死 Pocket 3。
    private(set) var deviceProfile: DeviceProfile = .unidentified
    var displayedMode: CameraMode? { captureMode.displayed }
    private var lastStatus80 = Bytes()
    private var lastStatus80At = 0.0

    private func applySnapshot(_ s: LinkSnapshot) {
        snapshot = s
        if s.camera.hasCameraStatus { captureMode.report(s.camera.mode, now: ProcessInfo.processInfo.systemUptime) }
        changed()
    }

    /// 统一快门：动作随模式与录制状态变化
    func shutter() {
        guard isConnected, link != nil else { return }
        let cam = snapshot.camera
        switch Shutter.action(mode: cam.hasCameraStatus ? cam.mode : displayedMode, recording: cam.recording) {
        case .takePhoto: takePhoto()
        case .startRecording, .stopRecording: toggleCameraRecording()
        }
    }

    static func freshSteps() -> [ConnectStep] {
        [ConnectStep(title: "扫描蓝牙设备", symbol: "dot.radiowaves.left.and.right"),
         ConnectStep(title: "蓝牙配对", symbol: "link"),
         ConnectStep(title: "等待相机 Wi-Fi 开启", symbol: "hourglass"),
         ConnectStep(title: "加入相机 Wi-Fi", symbol: "wifi"),
         ConnectStep(title: "检查相机是否可达", symbol: "network"),
         ConnectStep(title: "UDP 握手", symbol: "arrow.left.arrow.right"),
         ConnectStep(title: "启动视频流", symbol: "video"),
         ConnectStep(title: "已连接", symbol: "checkmark.seal")]
    }

    private init() {
        ble.onLog = { [weak self] s in Task { @MainActor in self?.log(s) } }
        ble.onBattery = { [weak self] b in Task { @MainActor in self?.bleBattery = b; self?.changed() } }
        video.onError = { [weak self] e in Task { @MainActor in self?.log("视频：\(e)") } }
        video.onNote = { [weak self] e in Task { @MainActor in self?.log("视频：\(e)") } }
        video.onNeedKeyframe = { [weak self] reason in
            Task { @MainActor in self?.requestKeyframe(reason) }
        }
        statsTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.periodic() }
        }
    }

    var isBusy: Bool { phase == .connecting }
    var isConnected: Bool { phase == .connected }

    // MARK: Change notification（合并为每个 runloop 最多一次）

    func changed() {
        guard !changePosted else { return }
        changePosted = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                self?.changePosted = false
                NotificationCenter.default.post(name: .modelChanged, object: self)
            }
        }
    }

    func log(_ s: String) {
        var text = s
        for secret in [activePassword, settings.password] where secret.count >= 4 {
            text = WiFiLogMask.redact(secret, in: text)
        }
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"
        textLog.append("\(f.string(from: Date()))  \(text)")
        if textLog.count > 1000 { textLog.removeFirst(textLog.count - 1000) }
        NotificationCenter.default.post(name: .logAppended, object: self)
    }

    private func periodic() {
        let now = ProcessInfo.processInfo.systemUptime
        if let last = lastPeriodicAt { mainLagMax = max(mainLagMax, (now - last - 0.25) * 1000) }
        lastPeriodicAt = now
        if isConnected { videoStats = video.stats(); captureMode.tick(now: now); runWatchdog(now: now); changed() }
        let batch = pending.drain()
        if !batch.isEmpty { logCameraStatus80(batch) }
        if !batch.isEmpty, !logPaused {
            dumlLog += batch
            if dumlLog.count > 3000 { dumlLog.removeFirst(dumlLog.count - 3000) }
            NotificationCenter.default.post(name: .logAppended, object: self)
        }
    }

    func clearLogs() { dumlLog = []; textLog = []; NotificationCenter.default.post(name: .logAppended, object: self) }

    /// 调试用：记下 Camera:0x80 原始字节，方便 Pocket 4/4P 用户回传。模式字节变化立刻记，其余最多 5 秒一条。
    private func logCameraStatus80(_ batch: [DUMLLogEntry]) {
        let now = ProcessInfo.processInfo.systemUptime
        for e in batch where e.direction == .rx && e.packet.cmdSet == 2 && e.packet.cmdID == 0x80 {
            let p = e.packet.payload
            let mode = p.count >= 58 ? p[57] : nil
            let prevMode = lastStatus80.count >= 58 ? lastStatus80[57] : nil
            if lastStatus80.isEmpty || mode != prevMode || now - lastStatus80At >= 5 {
                lastStatus80 = p
                lastStatus80At = now
                let modeText = mode.map { String(format: "0x%02X", $0) } ?? "—"
                log("[调试] Camera:0x80 \(p.count)B \(p.hexString(separator: " ")) · 型号 \(deviceProfile.displayName) · @57=\(modeText)")
            }
            return
        }
    }

    private func setStep(_ i: Int, _ st: StepStatus, _ detail: String = "") {
        guard steps.indices.contains(i) else { return }
        if st == .active { for j in 0 ..< i where steps[j].status == .active { steps[j].status = .done } }
        steps[i].status = st
        if !detail.isEmpty || st != .active { steps[i].detail = detail }
        if !detail.isEmpty { log("[\(steps[i].title)] \(detail)") }
        changed()
    }

    // MARK: Connect

    func connect() {
        guard !isBusy, !isConnected else { return }
        deviceProfile = .unidentified
        activeSSID = ""
        activePassword = ""
        activeDeviceID = ""
        credentialSource = .none
        wifiProvisionStatus = ""
        if settings.ssid.isEmpty && !settings.skipWiFi && !settings.autoFetchWiFi {
            log("尚未填写相机 Wi-Fi 名称，将使用手动加入引导")
        }
        steps = Self.freshSteps()
        phase = .connecting
        manualWiFiReason = nil
        changed()
        connectTask = Task { [weak self] in await self?.runConnect() }
    }

    func cancelConnect() {
        connectTask?.cancel()
        connectTask = nil
        teardown()
        phase = .idle
        manualWiFiReason = nil
        log("已取消连接")
        changed()
    }

    private func runConnect() async {
        let s = settings
        do {
            if !s.skipBLE {
                do {
                    try await bleActivateAndWiFi(retries: 3)
                } catch is CancellationError { throw CancellationError() }
                catch {
                    // 与原项目 main.py 一致：蓝牙失败后尝试仅 Wi-Fi
                    guard !s.skipWiFi else { throw error }
                    log("蓝牙激活失败：\(error.localizedDescription)。尝试仅加入 Wi-Fi（相机 Wi-Fi 可能已开启）…")
                    _ = await obtainCredentials(advertisedName: nil, deviceID: settings.lastBLEDeviceID, allowBLE: false)
                    try await joinWiFiStep()
                    try await reachabilityStep()
                }
            } else {
                for i in 0 ... 2 { setStep(i, .skipped, "已跳过") }
                if !s.skipWiFi {
                    _ = await obtainCredentials(advertisedName: nil, deviceID: s.lastBLEDeviceID, allowBLE: false)
                    try await joinWiFiStep()
                    try await reachabilityStep()
                } else {
                    setStep(3, .skipped, "已跳过"); setStep(4, .skipped, "已跳过")
                }
            }
            ble.disconnect()
            try Task.checkCancellation()
            resolveProfile()
            try await udpStep()
            setStep(6, .active, "发送 Mimo 启动序列（DM368 注册 + 视频心跳）…")
            try await Task.sleep(nanoseconds: 700_000_000)
            setStep(6, .done)
            setStep(7, .done, "连接成功！")
            phase = .connected
            log("=== 已就绪：P 拍照，O 录制，方向键 / WASD 控制云台 ===")
            changed()
        } catch is CancellationError {
            // cancelConnect 已处理
        } catch {
            let msg = error.localizedDescription
            if let i = steps.firstIndex(where: { $0.status == .active }) { setStep(i, .failed, msg) }
            log("连接失败：\(msg)")
            teardown()
            phase = .failed(msg)
            manualWiFiReason = nil
            changed()
        }
    }

    private func bleActivateAndWiFi(retries: Int) async throws {
        var lastError: Error = BLEError.notFound
        for attempt in 1 ... retries {
            do {
                if attempt > 1 { log("蓝牙重试 \(attempt)/\(retries)…") }
                try await bleActivateOnce()
                return
            } catch is CancellationError { ble.disconnect(); throw CancellationError() }
            catch let e as WiFiJoinError { ble.disconnect(); throw e } // Wi-Fi 问题不重试蓝牙
            catch {
                lastError = error
                ble.disconnect()
                log("蓝牙第 \(attempt)/\(retries) 次失败：\(error.localizedDescription)")
                if attempt < retries { try await Task.sleep(nanoseconds: 3_000_000_000) }
            }
        }
        throw lastError
    }

    private func bleActivateOnce() async throws {
        setStep(0, .active, "正在通过蓝牙寻找 Osmo Pocket…")
        var devices = try await ble.scan(timeout: settings.bleTimeout)
        let pockets = devices.filter { $0.profile.isPocketSeries }
        if !pockets.isEmpty { devices = pockets }
        else if devices.isEmpty { throw BLEError.notFound }
        else { log("未发现 Pocket 系列，但找到：\(devices.map { "\($0.name)（\($0.profile.displayName)）" }.joined(separator: ", "))，尝试第一台") }
        let dev = devices[0]
        deviceProfile = dev.profile
        setStep(0, .done, "找到 \(dev.name)（\(dev.profile.displayName)）")
        log("识别型号：\(dev.profile.displayName)，UDP \(dev.profile.udpPort)\(dev.profile.modeIDsUnverified ? "（部分模式号尚未实机确认，不会扫描未知 0xE1）" : "")")

        setStep(1, .active, "正在与 \(dev.name) 配对…首次配对请在相机屏幕上点「允许」")
        try await ble.connect(dev)
        let already = try await ble.pair()
        if already {
            setStep(1, .done, "相机报告：已配对")
        } else if await ble.awaitPairingConfirmation(timeout: 6) {
            setStep(1, .done, "相机已确认配对")
        } else {
            setStep(1, .done, "配对请求已发送")
        }
        settings.lastBLEDeviceID = dev.id.uuidString
        activeDeviceID = dev.id.uuidString

        if settings.skipWiFi {
            setStep(2, .skipped, "已跳过")
            setStep(3, .skipped, "已跳过"); setStep(4, .skipped, "已跳过")
        } else {
            let polled = await obtainCredentials(advertisedName: dev.name, deviceID: dev.id.uuidString, allowBLE: true)
            if wifi.isOnCameraNetwork(ssid: displayedSSID, cameraIP: settings.cameraIP) {
                setStep(2, .skipped, "已在相机网络上，无需等待")
            } else if polled {
                setStep(2, .done, "已尝试从相机读取 Wi-Fi")
            } else {
                let total = Int(settings.apWaitSeconds)
                for left in stride(from: total, to: 0, by: -1) {
                    setStep(2, .active, "等待相机 Wi-Fi 热点开启… 剩余 \(left) 秒（蓝牙保持连接）")
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                }
                setStep(2, .done, "")
            }
            try await joinWiFiStep()
            try await reachabilityStep()
        }
        log("Wi-Fi 已连接，断开蓝牙")
    }

    /// 决定这次用手填、钥匙串，还是向相机读。返回 true 表示已经做过 BLE 轮询（不必再空等热点）。
    @discardableResult
    private func obtainCredentials(advertisedName: String?, deviceID: String, allowBLE: Bool) async -> Bool {
        if !deviceID.isEmpty { activeDeviceID = deviceID }
        let cache = WiFiCredentialCache.load(deviceID: deviceID)
        let plan = WiFiCredentialPlanner.plan(autoFetch: settings.autoFetchWiFi, manualSSID: settings.ssid,
                                              manualPassword: settings.password, cachedSSID: cache?.ssid,
                                              cachedPassword: cache?.password, advertisedName: advertisedName)
        switch plan {
        case let .manual(ssid, password):
            adopt(ssid: ssid, password: password, source: .manual)
            log("使用手动填写的 Wi-Fi「\(ssid)」")
            return false
        case let .cached(ssid, password):
            adopt(ssid: ssid, password: password, source: .cache)
            log("使用已保存的相机 Wi-Fi「\(ssid)」，密码 \(WiFiLogMask.bullets(password))")
            return false
        case let .needsManualEntry(reason):
            wifiProvisionStatus = "失败：\(reason)"
            log(reason)
            changed()
            return false
        case .fetch:
            guard allowBLE, ble.isConnected else {
                if !settings.ssid.isEmpty {
                    adopt(ssid: settings.ssid, password: settings.password, source: .manual)
                    log("当前没有蓝牙连接，改用手动填写的 Wi-Fi「\(settings.ssid)」")
                } else {
                    wifiProvisionStatus = "失败：需要蓝牙连接才能自动读取相机 Wi-Fi"
                    log(wifiProvisionStatus)
                }
                changed()
                return false
            }
            wifiProvisionStatus = "读取中"
            setStep(2, .active, "读取中：正在从相机读取 Wi-Fi 名称和密码（热点未开时最多约 20 秒）")
            changed()
            let result = await ble.readWiFiCredentials(advertisedName: advertisedName)
            switch result {
            case let .success(creds):
                WiFiCredentialCache.save(deviceID: deviceID, ssid: creds.ssid, password: creds.password)
                adopt(ssid: creds.ssid, password: creds.password, source: .camera)
                wifiProvisionStatus = ""
                if creds.ssidFromAdvertisement {
                    log("Wi-Fi 名称用蓝牙广播「\(creds.ssid)」（读取失败或返回 0xE4），密码已写入钥匙串")
                } else {
                    log("已从相机读到 Wi-Fi「\(creds.ssid)」，密码已写入钥匙串")
                }
            case let .failure(reason):
                wifiProvisionStatus = "失败：\(reason.userMessage)"
                log("自动读取失败，改用手动填写或手动加入。\(reason.userMessage)")
                if !settings.ssid.isEmpty {
                    adopt(ssid: settings.ssid, password: settings.password, source: .manual)
                }
            }
            changed()
            return true
        }
    }

    private func adopt(ssid: String, password: String, source: WiFiCredentialOrigin) {
        activeSSID = ssid
        activePassword = password
        credentialSource = source
        changed()
    }

    /// 只清钥匙串。当前这次手动加入仍能拷贝刚读到的密码；下次连接会重新读。
    private func clearAutoCache() {
        guard credentialSource == .cache || credentialSource == .camera else { return }
        let id = activeDeviceID.isEmpty ? settings.lastBLEDeviceID : activeDeviceID
        WiFiCredentialCache.clear(deviceID: id)
        credentialSource = .none
        log("加入失败，已清除该相机保存在钥匙串中的 Wi-Fi，下次连接会重新读取")
    }

    private func joinWiFiStep() async throws {
        let ssid = displayedSSID, pw = displayedPassword, ip = settings.cameraIP
        if wifi.isOnCameraNetwork(ssid: ssid, cameraIP: ip) {
            wifiProvisionStatus = ""
            setStep(3, .done, "已在相机网络上\(wifi.currentSSID.map { "（\($0)）" } ?? "")"); return
        }
        if ssid.isEmpty {
            let reason = settings.autoFetchWiFi ? "未能自动读到相机 Wi-Fi 名称。" : "尚未在设置中填写相机 Wi-Fi 名称。"
            try await fallbackManualJoin(reason: reason, ssid: ssid, ip: ip)
            return
        }
        if !wifi.locationAuthorized {
            wifiProvisionStatus = "加入中"
            setStep(3, .active, "加入中：请在系统弹窗里允许「定位服务」。macOS 要用它才能看到 Wi-Fi 名称。若已经拒绝，请到系统设置里打开，或按页面上的步骤手动加入。")
            changed()
            let allowed = await wifi.ensureLocationAuthorization()
            if !allowed {
                try await fallbackManualJoin(reason: "未授予定位权限，无法按名称自动加入「\(ssid)」。请到「系统设置 → 隐私与安全性 → 定位服务」允许 PocketStudio，或按下面的步骤手动加入。", ssid: ssid, ip: ip)
                return
            }
        }
        wifiProvisionStatus = "加入中"
        setStep(3, .active, "加入中：正在加入「\(ssid)」（5.8 GHz 热点最多扫描约 90 秒）")
        changed()
        do {
            try await wifi.join(ssid: ssid, password: pw)
            if await wifi.waitForCameraNetwork(ssid: ssid, cameraIP: ip, timeout: WiFiScanRetry.addressWait) {
                wifiProvisionStatus = ""
                setStep(3, .done, "已加入 \(ssid)")
                return
            }
            clearAutoCache()
            try await fallbackManualJoin(reason: "已请求加入「\(ssid)」，但 \(Int(WiFiScanRetry.addressWait)) 秒内未获得 192.168.2.x 地址。", ssid: ssid, ip: ip)
        } catch {
            var reason = error.localizedDescription
            var clear = true
            if let join = error as? WiFiJoinError {
                switch join {
                case .locationDenied:
                    reason += " 请到系统设置允许定位，或手动加入。"
                    clear = false
                case .noInterface:
                    clear = false
                case .networkNotFound, .associate:
                    clear = true
                }
            }
            if clear { clearAutoCache() }
            try await fallbackManualJoin(reason: reason, ssid: ssid, ip: ip)
        }
    }

    private func fallbackManualJoin(reason: String, ssid: String, ip: String) async throws {
        wifiProvisionStatus = "失败：\(reason)"
        manualWiFiReason = reason
        setStep(3, .active, "需要手动加入 Wi-Fi：\(reason)")
        log("请按「连接」页面提示手动加入相机 Wi-Fi（最多等待 3 分钟，连上后自动继续）")
        changed()
        let ok = await wifi.waitForCameraNetwork(ssid: ssid, cameraIP: ip, timeout: 180)
        manualWiFiReason = nil
        if ok { wifiProvisionStatus = "" }
        try Task.checkCancellation()
        guard ok else { throw WiFiJoinError.associate("等待手动加入超时。") }
        setStep(3, .done, "已检测到相机网络")
    }

    /// 「我已连接」按钮：立即重新检测
    func manualWiFiRecheck() {
        if wifi.isOnCameraNetwork(ssid: displayedSSID, cameraIP: settings.cameraIP) { log("已检测到相机网络，继续…") }
        else { log("尚未检测到 192.168.2.x 地址。请确认 Mac 菜单栏 Wi-Fi 已选中相机热点。") }
    }

    private func reachabilityStep() async throws {
        setStep(4, .active, "检查相机 \(settings.cameraIP)…")
        let ok = await wifi.waitForCameraNetwork(ssid: displayedSSID, cameraIP: settings.cameraIP, timeout: 10)
        if !ok { throw WiFiJoinError.associate("相机不可达：未获得 192.168.2.x 地址") }
        setStep(4, .done, wifi.localCameraNetworkAddress.map { "本机地址 \($0)" } ?? "")
    }

    private func udpStep() async throws {
        setStep(5, .active, "与相机 \(settings.cameraIP):\(deviceProfile.udpPort) 握手…")
        do {
            let l = try await openLink()
            setStep(5, .done, String(format: "握手成功，相机 session 0x%04X", l.currentSnapshot().sessionID))
        } catch {
            throw NSError(domain: "PocketStudio", code: 1, userInfo: [NSLocalizedDescriptionKey:
                "\(error.localizedDescription)。常见原因：① 电脑或手机上的 DJI Mimo 正占用相机，请彻底退出；② 未允许「本地网络」权限；③ 未连上相机 Wi-Fi；④ 可在设置中切换到「BSD Socket 兼容模式」再试。"])
        }
    }

    /// 新建传输（新 socket / 新本地端口）+ 新 CameraLink（新 session、所有序号与窗口游标清零）并握手。
    /// 首次连接与「刷新视频」/ 看门狗第 3 阶段共用。
    @discardableResult
    private func openLink() async throws -> CameraLink {
        if settings.tcpPoke {
            if await poke.ensure(host: settings.cameraIP, pin: ble.activePairPIN) { log("TCP 7001 SetPairingPIN 已就绪（PIN \(ble.activePairPIN)，保持连接）") }
            else { log("TCP 7001 未就绪（不影响继续，部分固件不需要）") }
        }
        let transport: DatagramTransport = settings.transport == .bsd ? BSDDatagramTransport() : NWDatagramTransport(wifiOnly: settings.wifiInterfaceOnly)
        let l = CameraLink(host: settings.cameraIP, port: deviceProfile.udpPort, transport: transport, profile: deviceProfile)
        Self.configure(l, settings)
        let pipeline = video
        pipeline.reset()
        l.onVideo = { b in pipeline.ingest(b) }
        l.onSnapshot = { [weak self] s in Task { @MainActor in self?.applySnapshot(s) } }
        l.onError = { [weak self] e in Task { @MainActor in self?.log(e) } }
        l.onReply = { [weak self] p in Task { @MainActor in self?.handleReply(p) } }
        let buf = pending
        l.onDUML = { p, d in buf.append(DUMLLogEntry(time: Date(), direction: d, packet: p)) }
        link = l
        let result: Result<Void, LinkError> = await withCheckedContinuation { c in l.connect(timeout: 10) { c.resume(returning: $0) } }
        switch result {
        case .success:
            LocalNetworkPermission.shared.markGrantedFromTraffic()
            linkHeartbeatReplyCount = 0
            versionConfigReplyCount = 0
            logKeepaliveIfNeeded(force: true)
            linkConnectedAt = ProcessInfo.processInfo.systemUptime
            lastReplyCount = 0; lastReplyCountAt = linkConnectedAt; replyRate = 0
            lastRxPackets = 0; lastVideoPackets = 0
            monitor.reset()
            return l
        case let .failure(e):
            if link === l { link = nil }
            throw NSError(domain: "PocketStudio", code: 1, userInfo: [NSLocalizedDescriptionKey: e.description])
        }
    }

    // MARK: 视频看门狗 / 恢复

    private var monitor = VideoHealthMonitor()
    private let poke = TCPPoke()
    private var linkConnectedAt = 0.0
    private var lastDiagAt = 0.0
    private var lastPeriodicAt: Double?
    private var mainLagMax = 0.0
    private var lastReplyCount = 0
    private var lastReplyCountAt = 0.0
    private var replyRate = 0.0
    private var lastRxPackets = 0, lastVideoPackets = 0
    /// 画面恢复提示（nil = 正常）；LiveViewController 显示在画面上
    private(set) var videoRecoveryMessage: String?
    /// 渲染器状态（LiveViewController 提供；诊断用）
    var rendererStatus: () -> String = { "—" }

    private func requestKeyframe(_ reason: String) {
        link?.requestKeyframe { [weak self] sent in
            if sent { Task { @MainActor in self?.log("请求关键帧（0x09/0xA8 + Camera:0xB3）：\(reason)") } }
        }
    }

    private func runWatchdog(now: Double) {
        guard !recovering, link != nil else { return }
        let snap = snapshot, h = video.health()
        if now - lastReplyCountAt >= 2 {
            replyRate = max(0, Double(snap.repliesRx - lastReplyCount) / max(0.001, now - lastReplyCountAt))
            lastReplyCount = snap.repliesRx; lastReplyCountAt = now
        }
        handlePlayback(now: now)
        let busy = snap.camera.inPlayback || snap.camera.capturing
        let action = monitor.evaluate(VideoHealthInput(now: now, connectedAt: linkConnectedAt, lastVideoPacket: snap.lastVideoAt,
                                                       lastDecoded: h.lastDecodedAt, lastTelemetry: snap.lastTelemetryAt,
                                                       lastReply: snap.lastReliableAt, cameraBusy: busy))
        if action != .none { log(diagnosticLine(now: now, tag: "看门狗")) }
        switch action {
        case .none: break
        case .recovered:
            videoRecoveryMessage = nil; log("画面已恢复")
        case .linkLost:
            log("与相机的连接中断（遥测也停止 ≥4s）→ 自动重连")
            startRecovery(reason: "遥测中断")
        case .resetDecoder:
            videoRecoveryMessage = "画面中断，正在恢复…（重建解码器）"
            log("画面中断：视频包仍在到达但无法解码 → 只重建解码器（不动链路）")
            video.resetDecoder(reason: "看门狗")
        case .waitCameraBusy:
            videoRecoveryMessage = snap.camera.inPlayback ? "相机进入回放，正在退出回放…" : "相机正在处理照片，请稍候…"
            log("画面暂停：相机忙（回放=\(snap.camera.inPlayback) 拍照处理=\(snap.camera.capturing)）→ 不重建链路，等待相机")
        case .reRegister:
            videoRecoveryMessage = "画面中断，正在恢复…（重新注册）"
            log("画面中断：相机停止发送视频（遥测照常）→ 重新注册 + 请求关键帧")
            link?.reRegister(); requestKeyframe("看门狗")
        case .commandStall:
            videoRecoveryMessage = "相机停止响应命令，正在重新连接…"
            log("相机命令通道已 6s 无应答（遥测仍在）——此状态在日志中从未自愈、8–10s 后视频必停 → 立即蓝牙唤醒重连")
            startRecovery(reason: "命令通道无应答")
        case .rebuildLink:
            log("画面仍中断且相机不再应答命令 → 自动重连（退避）")
            startRecovery(reason: "看门狗")
        }
        if now - lastDiagAt >= (monitor.isStalled ? 2 : 10) {
            lastDiagAt = now
            log(diagnosticLine(now: now, tag: "诊断"))
            mainLagMax = 0
        }
    }

    /// 拍照后相机会自己进入回放（13:35:04 日志：0x80 标志 bit30 置位 + 10Hz Camera:0x82 推送，实时画面停止）。
    /// 我们没主动进入回放 → 每 2s 发一次「退出回放」0x02/0x0C 01 01 00 00，直到标志清除。
    private var lastExitPlaybackAt = 0.0
    private var exitPlaybackCount = 0
    private func handlePlayback(now: Double) {
        guard settings.autoExitPlayback, snapshot.camera.inPlayback else { exitPlaybackCount = 0; return }
        guard now - lastExitPlaybackAt >= 2 else { return }
        lastExitPlaybackAt = now; exitPlaybackCount += 1
        link?.sendCamera(CameraCommand.exitPlayback)
        if exitPlaybackCount <= 3 { log("相机处于回放（拍照后自动预览）→ 发送退出回放（0x02/0x0C 01 01 00 00）#\(exitPlaybackCount)") }
    }

    /// 一行诊断：下一份用户日志里据此定位问题
    func diagnosticLine(now: Double = ProcessInfo.processInfo.systemUptime, tag: String = "诊断") -> String {
        let s = snapshot, h = video.health(), v = videoStats
        func age(_ t: Double?) -> String { t.map { String(format: "%.1fs", now - $0) } ?? "从未" }
        let rx = s.stats.rxPackets - lastRxPackets, vp = s.stats.videoFrames - lastVideoPackets
        lastRxPackets = s.stats.rxPackets; lastVideoPackets = s.stats.videoFrames
        let types = s.stats.rxTypeCounts.sorted { $0.key < $1.key }.map { "t\($0.key)=\($0.value)" }.joined(separator: ",")
        return String(format: "[%@] 视频片段 %ld/s · AU %ld/s · 解码 %ld fps · %ld kbps · 最近：视频包 %@ / 解码 %@ / 遥测 %@ / 应答 %@ · 相机应答 %.1f/s · ACK v=%04X%@ r=%04X%@ x=%04X%@ · 握手 %ld 次 · 解码错误 %ld%@ · 解码器重建 %ld · 渲染器 %@ 冲刷 %ld · 等关键帧 %@(丢 %ld) · 关键帧请求 %ld · GOP %ld · 录制排队 %ld · 待解码 %ld · 主线程最大延迟 %.0fms · 收包 %ld（视频 %ld）累计[%@] · 云台 %@ · 保活 %@",
                      tag, h.rxChunksPerSec, h.ausPerSec, v.fps, v.kbps,
                      age(s.lastVideoAt), age(h.lastDecodedAt), age(s.lastTelemetryAt), age(s.lastReliableAt),
                      replyRate,
                      s.ackVideo, s.ackVideoSeen ? "" : "?", s.ackReliable, s.ackReliableSeen ? "" : "?", s.ackExtra, s.ackExtraSeen ? "" : "(base)",
                      s.handshakeCount, h.decodeErrors, h.lastDecodeError.map { "(\($0))" } ?? "", h.decoderResets,
                      rendererStatus(), h.rendererFlushes, h.waitingKeyframe ? "是" : "否", h.droppedWhileWaiting,
                      h.keyframeRequests, h.gopFrames, h.recPending, h.pendingIngest, mainLagMax, rx, vp, types,
                      s.gimbalReady ? "就绪" : "准备中", settings.linkKeepalive.diagnosticToken)
            + " · 型号 \(deviceProfile.displayName) · 编码 \(video.mediaNotes().codec) · 帧头 \(video.mediaNotes().frameHeader) · UDP \(deviceProfile.udpPort)"
    }

    /// 蓝牙没给出型号时，用用户填写的 Wi-Fi 名称（OsmoPocket4P-XXXX 这类）再认一次。仍没有就按 Pocket 3，避免改变现有连接。
    private func resolveProfile() {
        if deviceProfile.isPocketSeries { return }
        let named = DeviceProfile.detect(manufacturerData: nil, localName: displayedSSID.isEmpty ? nil : displayedSSID)
        if named.isPocketSeries {
            deviceProfile = named
            log("按 Wi-Fi 名称识别为 \(named.displayName)（UDP \(named.udpPort)）")
            return
        }
        if deviceProfile.isDJI {
            log("厂商数据是 DJI，但型号字节未知。模式号暂用 Pocket 3，UDP \(deviceProfile.udpPort)。请把上面的厂商数据原样发回。")
            return
        }
        deviceProfile = .pocket3
        log("未能识别型号，按 Osmo Pocket 3 的模式号和 SD 卡解析继续（不扫描未知 0xE1）")
    }

    // MARK: 自动重连（退避）
    //
    // 13:33–13:35 日志：两次「重建链路」都在关掉旧 socket 300ms 后立刻握手 → 10s 握手超时（13:34:11、13:35:21），
    // 失败后 link=nil，看门狗还拿空快照误报「画面已恢复」、算出负的应答速率；
    // 而用户手动重连（蓝牙配对 → 同一 Wi-Fi → 握手）一次成功（13:34:30）。
    // 现在：等待旧会话释放（≥1.5s）→ TCP 7001 戳 + 新 socket；还不行就走完整重连（蓝牙唤醒 + 必要时重新加入 Wi-Fi），按退避重试。

    private(set) var recovering = false
    private var policy = ReconnectPolicy()
    private var recoveryTask: Task<Void, Never>?

    /// 兼容旧调用名
    func rebuildLink(reason: String) { startRecovery(reason: reason) }

    func startRecovery(reason: String, immediate: Bool = false) {
        guard isConnected, !recovering else { return }
        recovering = true
        policy.reset()
        let wasRecording = isLocalRecording
        if wasRecording { toggleLocalRecording(); log("提示：本地录制已在重连前自动保存，如需继续请重新开始录制") }
        recoveryTask = Task { [weak self] in await self?.runRecovery(reason: reason, immediate: immediate) }
    }

    private func dropLink() {
        link?.stop(); link = nil
        poke.close()
        video.reset()
        snapshot = LinkSnapshot()
        changed()
    }

    private func runRecovery(reason: String, immediate: Bool) async {
        defer { recovering = false; recoveryTask = nil; changed() }
        dropLink()
        var first = true
        while let (delay, level) = policy.next() {
            let n = policy.failures + 1
            let wait = (first && immediate) ? 1.5 : delay   // 至少 1.5s：让相机释放旧会话
            first = false
            videoRecoveryMessage = "连接中断，正在重连（第 \(n) 次\(level == .fullReconnect ? "，蓝牙唤醒" : "")）…"
            log(String(format: "自动重连 #%ld（%@）：%.1fs 后%@", n, reason, wait, level == .fullReconnect ? "完整重连（蓝牙唤醒 → Wi-Fi → UDP）" : "重建 UDP（TCP 7001 + 新 socket）"))
            changed()
            do {
                try await Task.sleep(nanoseconds: UInt64(wait * 1e9))
                guard isConnected else { return }
                if level == .fullReconnect { try await rewake() }
                let l = try await openLink()
                ble.disconnect()
                policy.reset(); videoRecoveryMessage = nil
                log(String(format: "自动重连成功（#%ld），相机 session 0x%04X", n, l.currentSnapshot().sessionID))
                return
            } catch is CancellationError {
                return
            } catch {
                ble.disconnect()
                log("自动重连 #\(n) 失败：\(error.localizedDescription)")
                policy.recordFailure()
            }
        }
        log("自动重连多次失败，已停止。请检查相机是否开机、Wi-Fi 是否仍连着相机，然后点「连接」重试。")
        teardown()
        phase = .failed("自动重连失败")
        changed()
    }

    /// 蓝牙重新唤醒（与手动连接相同的配对，相机会因此接受新会话）+ 必要时重新加入 Wi-Fi（不弹手动引导）
    private func rewake() async throws {
        if !settings.skipBLE {
            do {
                var devs = try await ble.scan(timeout: min(settings.bleTimeout, 8))
                let p = devs.filter { $0.profile.isPocketSeries }
                if !p.isEmpty { devs = p }
                guard let d = devs.first else { throw BLEError.notFound }
                deviceProfile = d.profile
                try await ble.connect(d)
                let already = try await ble.pair()
                if !already { _ = await ble.awaitPairingConfirmation(timeout: 4) }
                settings.lastBLEDeviceID = d.id.uuidString
                activeDeviceID = d.id.uuidString
                log("蓝牙重新唤醒：\(d.name)（\(d.profile.displayName)）已配对")
                if activeSSID.isEmpty || activePassword.isEmpty {
                    _ = await obtainCredentials(advertisedName: d.name, deviceID: d.id.uuidString, allowBLE: true)
                }
            } catch is CancellationError { throw CancellationError() }
            catch { log("蓝牙唤醒失败（继续尝试 Wi-Fi）：\(error.localizedDescription)") }
        }
        guard !settings.skipWiFi else { return }
        let ssid = displayedSSID
        let pw = displayedPassword
        if !wifi.isOnCameraNetwork(ssid: ssid, cameraIP: settings.cameraIP) {
            log("Mac 已不在相机 Wi-Fi 上（相机热点可能断开）→ 重新加入")
            if !ssid.isEmpty {
                if !wifi.locationAuthorized { _ = await wifi.ensureLocationAuthorization(timeout: 8) }
                do { try await wifi.join(ssid: ssid, password: pw) }
                catch let error as WiFiJoinError {
                    switch error {
                    case .locationDenied, .noInterface: throw error
                    case .networkNotFound, .associate:
                        clearAutoCache()
                        throw error
                    }
                }
            }
            guard await wifi.waitForCameraNetwork(ssid: ssid, cameraIP: settings.cameraIP, timeout: 25) else {
                clearAutoCache()
                throw WiFiJoinError.associate("未能重新加入相机 Wi-Fi")
            }
        }
    }

    private func teardown() {
        recoveryTask?.cancel(); recoveryTask = nil; recovering = false
        monitor.reset(); videoRecoveryMessage = nil
        loggedKeepalive = nil
        link?.stop(); link = nil
        poke.close()
        if isLocalRecording { toggleLocalRecording() }
        video.reset()
        ble.disconnect()
    }

    func disconnect() {
        connectTask?.cancel(); connectTask = nil
        teardown()
        phase = .idle
        steps = Self.freshSteps()
        snapshot = LinkSnapshot()
        deviceProfile = .unidentified
        wifiProvisionStatus = ""
        activeSSID = ""
        activePassword = ""
        credentialSource = .none
        log("已断开")
        changed()
    }

    // MARK: Camera commands

    func takePhoto() {
        guard let link else { return }
        let mode = snapshot.camera.mode
        if let mode, !mode.isStill {
            log("拍照：相机当前为「\(mode.displayName)」模式，快门可能被拒绝（d9）。请先切到「拍照」模式。")
        }
        link.takePhoto()
        log("拍照（0x02/0x01 [01]）")
    }
    func toggleCameraRecording() {
        guard let link else { return }
        link.toggleRecording { [weak self] start, mode in
            Task { @MainActor in
                let how = mode?.usesShutterForRecording == true ? "0x02/0x01" : "0x02/0x02"
                self?.log(start ? "开始相机录制（\(how) [01]）" : "停止相机录制（\(how) [00]）")
            }
        }
    }
    func startCameraRecording() { link?.startRecording() }
    func stopCameraRecording() { link?.stopRecording() }
    func setMode(_ m: CameraMode) {
        guard !snapshot.camera.recording else { log("录制中不能切换模式，请先停止录制"); return }
        // 界面立即切换；命令防抖 400ms 只发最后一次（13:51 日志：7s 内连发 6 次切换后相机停止应答）
        captureMode.request(m, now: ProcessInfo.processInfo.systemUptime)
        changed()
        if let i = Shutter.segments(for: deviceProfile).firstIndex(of: m) { modeIndex = i }
        modeSendTask?.cancel()
        modeSendTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard let self, !Task.isCancelled else { return }
            if self.snapshot.camera.hasCameraStatus, self.snapshot.camera.mode == m { self.log("模式已是「\(m.displayName)」，不重复发送"); return }
            guard let spec = CameraCommand.setMode(m, profile: self.deviceProfile) else {
                self.log("「\(m.displayName)」在 \(self.deviceProfile.displayName) 上没有已知模式号，未发送")
                return
            }
            self.link?.setMode(m)
            let unverified = self.deviceProfile.modeIDsUnverified ? "（该机型模式号未全部实机确认）" : ""
            self.log(String(format: "切换模式：%@（0x02/0xE1 [%02X]）%@", m.displayName, spec.payload.first ?? 0, unverified))
        }
    }
    private var modeSendTask: Task<Void, Never>?

    /// 相机 / 云台对 request 的应答（flags 0x80/0xC0）
    /// 前几条 0x0E / 0x4F 应答写入文本日志，避免 1Hz 刷屏，又让实机 A/B 看得到负载。
    private var linkHeartbeatReplyCount = 0
    private var versionConfigReplyCount = 0
    private var loggedKeepalive: LinkKeepalive?
    private func logKeepaliveIfNeeded(force: Bool = false) {
        let mode = settings.linkKeepalive
        guard force || loggedKeepalive != mode else { return }
        loggedKeepalive = mode
        log(mode.sessionLog)
    }

    private func handleReply(_ p: DUMLPacket) {
        switch (p.cmdSet, p.cmdID) {
        case (0, 0x0E):
            linkHeartbeatReplyCount += 1
            guard linkHeartbeatReplyCount <= 3 else { return }
            log("相机应答 · 链路心跳 General:0x0E #\(linkHeartbeatReplyCount)：\(CameraCommand.describeReply(cmdID: p.cmdID, payload: p.payload)) payload=\(Self.payloadHex(p.payload))")
            return
        case (0, 0x4F):
            versionConfigReplyCount += 1
            guard versionConfigReplyCount <= 2 else { return }
            log("相机应答 · 版本配置 General:0x4F #\(versionConfigReplyCount)：\(p.payload.count) 字节（通常约 265 字节 XML，会占用可靠窗口）")
            return
        case (2, 0xB3):
            log("相机应答 · 关键帧 Camera:0xB3：\(CameraCommand.describeReply(cmdID: p.cmdID, payload: p.payload)) payload=\(Self.payloadHex(p.payload))")
            return
        default:
            break
        }
        let name: String
        switch (p.cmdSet, p.cmdID) {
        case (2, 0x01): name = "快门"
        case (2, 0x02): name = "录像"
        case (2, 0xE1): name = "切换模式"
        case (4, 0x4C): name = "云台模式/回中"
        case (4, 0x50): name = "云台参数"
        default: return   // 心跳等应答不打日志
        }
        let ok = p.payload.first == 0
        if p.cmdSet == 2, p.cmdID == 0xE1 { captureMode.ack(success: ok); changed() }
        log("相机应答 · \(name)：\(CameraCommand.describeReply(cmdID: p.cmdID, payload: p.payload))\(ok ? "" : "（\(p.payload.prefix(4).map { String(format: "%02x", $0) }.joined(separator: " "))）")")
    }

    private static func payloadHex(_ p: Bytes) -> String {
        let hex = Bytes(p.prefix(16)).hexString()
        return hex.isEmpty ? "空" : hex
    }
    func cycleMode() {
        let segs = Shutter.segments(for: deviceProfile)
        guard !segs.isEmpty else { return }
        modeIndex = (modeIndex + 1) % segs.count
        setMode(segs[modeIndex])
    }
    /// 「刷新视频」：彻底重置。实机日志：原地重新握手（11:41:20、11:41:49）后相机仍零应答、画面不恢复，
    /// 而断开重连（新 socket）立即恢复 → 刷新改为重建整条 UDP 链路。
    func refreshVideo() {
        guard !recovering else { log("正在自动重连，请稍候"); return }
        log("刷新视频：释放旧会话 1.5s 后重建 UDP 链路（失败则蓝牙唤醒重连），并重置解码器 / 渲染器 / 窗口游标")
        log(diagnosticLine(tag: "刷新前"))
        monitor.reset()
        startRecovery(reason: "手动刷新", immediate: true)
    }
    func sendRaw(cmdSet: UInt8, cmdID: UInt8, payload: Bytes, receiverType: UInt8, receiverID: UInt8, cmdType: UInt8) {
        guard let link else { log("未连接，无法发送"); return }
        link.sendRaw(cmdSet: cmdSet, cmdID: cmdID, payload: payload, receiverType: receiverType, receiverID: receiverID, cmdType: cmdType)
        log(String(format: "原始命令：set=0x%02x id=0x%02x payload=%@ → %@(%d)", cmdSet, cmdID, payload.hexString(), DUMLDevice.name(receiverType), receiverID))
    }

    // MARK: Gimbal

    /// 归一化速度（-1…1）；pitch 正值 = 向上
    /// 轴顺序与反转在协议层（GimbalSpeedController）处理，这里只传 UI 语义：yaw 右正、pitch 上正
    func setGimbal(yaw: Double, pitch: Double) { link?.setGimbalSpeed(yaw: yaw, pitch: pitch) }
    func stopGimbal() { link?.stopGimbal() }
    func nudgeGimbal(yaw: Double, pitch: Double, duration: Double = 0.3) {
        link?.nudge(yaw: yaw, pitch: pitch, duration: duration)
    }
    func recenterGimbal() { link?.gimbalRecenter(); log("云台回中（0x04/0x4C FE 08）") }
    func flipGimbal() { link?.gimbalFlip(); log("云台前后翻转（0x04/0x4C FE 09）") }
    func setGimbalMode(_ m: GimbalMode) {
        link?.setGimbalMode(m)
        log(String(format: "云台模式：%@（0x04/0x4C %02X 08）", m.displayName, m.rawValue))
    }
    func setGimbalSpeedSetting(_ v: GimbalSpeedSetting) {
        link?.setGimbalSpeedSetting(v); log("云台转速：\(v.displayName)（0x04/0x50）")
    }
    func applyLinkSettings() {
        guard let link else { return }
        Self.configure(link, settings)
        logKeepaliveIfNeeded()
    }
    private static func configure(_ link: CameraLink, _ s: AppSettings) {
        link.legacyAttitudeLayout = s.swapPitchYaw
        link.setGimbalStreaming(false)   // 不再提供 30Hz 持续发送（会挤爆相机命令通道，见 AGENTS §5f）
        link.setLegacyFraming(s.legacyFraming)
        link.setLinkKeepalive(s.linkKeepalive)
        link.configureGimbal(order: s.gimbalAxisOrder, invertYaw: s.invertYaw, invertPitch: s.invertPitch)
    }

    // MARK: Local recording / snapshot

    private func newFileURL(ext: String) throws -> URL {
        let folder = settings.recordingFolder
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyyMMdd_HHmmss"
        return folder.appendingPathComponent("PocketStudio_\(f.string(from: Date())).\(ext)")
    }

    func toggleLocalRecording() {
        if isLocalRecording {
            isLocalRecording = false
            video.stopRecording { [weak self] url in
                Task { @MainActor in
                    if let url { self?.lastSavedFile = url; self?.lastRecordingFile = url; self?.log("录制已保存：\(url.path)（点「在访达中显示」查看）") }
                    else { self?.log("录制未生成文件：录制期间没有收到关键帧。请录制更久一点，或先点「刷新视频」后再录。") }
                    self?.changed()
                }
            }
        } else {
            guard isConnected else { log("请先连接相机"); return }
            do {
                let fmt = settings.recordingFormat
                let rawExt = video.detectedCodec() == .hevc ? "h265" : "h264"
                let url = try newFileURL(ext: fmt == .mp4 ? "mp4" : rawExt)
                try video.startRecording(to: url, format: fmt)
                isLocalRecording = true
                log("开始录制到 \(url.path)")
            } catch { log("无法开始录制：\(error.localizedDescription)") }
        }
        changed()
    }

    var localRecordingInfo: (Date, Int)? { isLocalRecording ? video.recordingInfo : nil }

    func saveSnapshot() {
        do {
            let url = try newFileURL(ext: "png")
            if video.saveSnapshot(to: url) { lastSavedFile = url; log("截图已保存：\(url.path)") }
            else { log("暂无画面可截图") }
        } catch { log("截图失败：\(error.localizedDescription)") }
        changed()
    }

    /// 在访达中显示最近保存的文件（录制优先于截图）；文件不存在则打开文件夹
    func revealLastFile() {
        let fm = FileManager.default
        if let u = lastRecordingFile ?? lastSavedFile, fm.fileExists(atPath: u.path) {
            NSWorkspace.shared.activateFileViewerSelecting([u])
            log("在访达中显示：\(u.lastPathComponent)")
        } else {
            let folder = settings.recordingFolder
            try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
            if !NSWorkspace.shared.open(folder) { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: folder.path) }
            log("打开文件夹：\(folder.path)")
        }
    }
    /// 用默认播放器（QuickTime）打开最近的录制
    func openLastRecording() {
        guard let u = lastRecordingFile, FileManager.default.fileExists(atPath: u.path) else { revealLastFile(); return }
        NSWorkspace.shared.open(u)
    }

    // MARK: BLE 直播（实验，原项目 ble.py 中的 RTMP 能力）

    func runRTMPFlow(routerSSID: String, routerPassword: String, url: String, resolution: DJIBLE.RTMPResolution, fps: Int, bitrate: Int) {
        guard !isBusy else { log("正在连接中，稍后再试"); return }
        Task { [weak self] in
            guard let self else { return }
            do {
                var devs = try await ble.scan(timeout: settings.bleTimeout)
                devs = devs.filter { $0.model == DJIBLE.pocket3Model }.isEmpty ? devs : devs.filter { $0.model == DJIBLE.pocket3Model }
                guard let d = devs.first else { throw BLEError.notFound }
                try await ble.connect(d)
                try await ble.pair()
                await ble.stopStreaming()
                try await ble.prepareLivestream()
                try await ble.setupWiFi(ssid: routerSSID, password: routerPassword)
                try await ble.startRTMP(url: url, resolution: resolution, fps: fps, bitrateKbps: bitrate)
                log("RTMP 推流命令已发送。蓝牙保持连接，可点击「停止推流」。")
            } catch {
                log("RTMP 流程失败：\(error.localizedDescription)")
                ble.disconnect()
            }
        }
    }

    func stopRTMP() {
        Task { [weak self] in
            guard let self else { return }
            if ble.isConnected { await ble.stopStreaming() } else { log("蓝牙未连接") }
            ble.disconnect()
        }
    }
}

/// 跨线程收集 DUML 日志，主线程批量取出
nonisolated final class DUMLBuffer: @unchecked Sendable {
    private var items: [DUMLLogEntry] = []
    private let lock = NSLock()
    func append(_ e: DUMLLogEntry) {
        lock.lock(); items.append(e); if items.count > 5000 { items.removeFirst(1000) }; lock.unlock()
    }
    func drain() -> [DUMLLogEntry] { lock.lock(); defer { lock.unlock() }; let x = items; items = []; return x }
}
