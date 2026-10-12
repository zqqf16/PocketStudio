// BLEManager.swift — CoreBluetooth 实现的扫描 / 连接 / 配对（移植自 pocket3/ble.py 的 DjiPocket3BLE）
//
// 首次使用会弹出蓝牙权限对话框（Info.plist: NSBluetoothAlwaysUsageDescription）。

import Foundation
@preconcurrency import CoreBluetooth

/// CBPeripheral 只在主线程使用；标为 @unchecked Sendable 以便经 CheckedContinuation 返回。
struct DiscoveredDJIDevice: Identifiable, Equatable, @unchecked Sendable {
    let id: UUID
    let name: String
    let model: String
    let profile: DeviceProfile
    let rssi: Int
    let peripheral: CBPeripheral
}

nonisolated enum BLEError: LocalizedError, Sendable {
    case unauthorized, poweredOff, unsupported, notFound, connectFailed(String), characteristicsMissing, timeout(String), notConnected, wifiSetupFailed(String)
    var errorDescription: String? {
        switch self {
        case .unauthorized: return "未获得蓝牙权限。请到「系统设置 → 隐私与安全性 → 蓝牙」中允许 PocketStudio。"
        case .poweredOff: return "蓝牙已关闭。请在控制中心或「系统设置 → 蓝牙」中打开。"
        case .unsupported: return "此 Mac 不支持低功耗蓝牙。"
        case .notFound: return "未找到 DJI 设备。请确认相机已开机、靠近 Mac，且未被手机上的 DJI Mimo 占用。"
        case let .connectFailed(s): return "蓝牙连接失败：\(s)"
        case .characteristicsMissing: return "未找到 DJI 的 FFF4/FFF5 特征值。"
        case let .timeout(s): return "蓝牙响应超时：\(s)"
        case .notConnected: return "蓝牙未连接"
        case let .wifiSetupFailed(s): return "相机 Wi-Fi 配置失败：\(s)"
        }
    }
}

/// 在主线程延迟执行
@MainActor func mainAfter(_ seconds: TimeInterval, _ block: @escaping @MainActor @Sendable () -> Void) {
    Task { @MainActor in
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        block()
    }
}

/// 隔离：@MainActor。CBCentralManager 使用 queue: .main，所以所有委托回调都在主线程；
/// 用 @preconcurrency 一致性让 MainActor 方法满足 ObjC 委托要求（运行时断言在主线程）。
@MainActor
final class BLEManager: NSObject, @preconcurrency CBCentralManagerDelegate, @preconcurrency CBPeripheralDelegate {
    private lazy var central = CBCentralManager(delegate: self, queue: .main)
    private var found: [UUID: DiscoveredDJIDevice] = [:]
    private var scanContinuation: CheckedContinuation<[DiscoveredDJIDevice], Never>?
    private var stateWaiters: [CheckedContinuation<Void, Error>] = []
    private var connectContinuation: CheckedContinuation<Void, Error>?
    private var responseWaiter: (id: UInt16, cont: CheckedContinuation<DJIBLEMessage, Error>)?
    private var peripheral: CBPeripheral?
    private var notifyChar: CBCharacteristic?
    private var writeChar: CBCharacteristic?
    private var reassembler = DJIBLEReassembler()
    /// 配对成功时实际使用的 PIN。TCP 7001 戳一下用同一个，避免和蓝牙配对身份不一致。
    private(set) var activePairPIN = DJIBLE.pairPIN

    var onLog: ((String) -> Void)?
    var onBattery: ((Int) -> Void)?
    private(set) var battery: Int?
    var isConnected: Bool { peripheral?.state == .connected && writeChar != nil }

    static var authorization: CBManagerAuthorization { CBManager.authorization }

    /// 触发系统蓝牙权限弹窗（新手引导用）
    func requestAuthorization() { _ = central.state }

    private func log(_ s: String) { onLog?(s) }

    // MARK: State

    func waitUntilReady(timeout: TimeInterval = 5) async throws {
        if let e = stateError(central.state) { throw e }
        if central.state == .poweredOn { return }
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            stateWaiters.append(c)
            mainAfter(timeout) { [weak self] in
                guard let self, !self.stateWaiters.isEmpty else { return }
                let ws = self.stateWaiters; self.stateWaiters = []
                ws.forEach { $0.resume(throwing: self.stateError(self.central.state) ?? BLEError.poweredOff) }
            }
        }
    }

    private func stateError(_ s: CBManagerState) -> BLEError? {
        switch s {
        case .unauthorized: return .unauthorized
        case .unsupported: return .unsupported
        case .poweredOff: return .poweredOff
        default: return nil
        }
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        let s = central.state
        if s == .poweredOn || stateError(s) != nil {
            let ws = stateWaiters; stateWaiters = []
            ws.forEach { c in if let e = stateError(s) { c.resume(throwing: e) } else { c.resume() } }
        }
        if s != .poweredOn, peripheral != nil { failConnection(BLEError.poweredOff) }
    }

    // MARK: Scan

    /// 扫描 DJI 设备。Pocket 3 经常不带厂商数据，所以也按广播名匹配，并且不会在见到第一台 0x20 后提前结束。
    func scan(timeout: TimeInterval) async throws -> [DiscoveredDJIDevice] {
        try await waitUntilReady()
        found = [:]
        log("正在扫描 DJI 蓝牙设备…")
        let result: [DiscoveredDJIDevice] = await withCheckedContinuation { c in
            scanContinuation = c
            central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
            mainAfter(timeout) { [weak self] in self?.finishScan() }
        }
        log("扫描结束：找到 \(result.count) 台 DJI 设备")
        return result
    }

    private func finishScan() {
        guard let c = scanContinuation else { return }
        scanContinuation = nil
        central.stopScan()
        c.resume(returning: found.values.sorted { a, b in
            if a.profile.isPocketSeries != b.profile.isPocketSeries { return a.profile.isPocketSeries }
            return a.rssi > b.rssi
        })
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let mfr = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data
        let local = peripheral.name ?? (advertisementData[CBAdvertisementDataLocalNameKey] as? String)
        let profile = DeviceProfile.detect(manufacturerData: mfr.map { Bytes($0) }, localName: local)
        guard profile.isDJI, found[peripheral.identifier] == nil else { return }
        let name = local ?? "DJI 设备"
        let d = DiscoveredDJIDevice(id: peripheral.identifier, name: name, model: profile.displayName, profile: profile, rssi: RSSI.intValue, peripheral: peripheral)
        found[peripheral.identifier] = d
        if let mfr {
            log("  发现：\(name)（\(profile.displayName)）RSSI \(RSSI) · 厂商数据 \(Bytes(mfr).hexString(separator: " "))")
        } else {
            log("  发现：\(name)（\(profile.displayName)）RSSI \(RSSI) · 无厂商数据，按广播名识别")
        }
    }

    // MARK: Connect

    func connect(_ device: DiscoveredDJIDevice, timeout: TimeInterval = 15) async throws {
        log("正在连接 \(device.name)…")
        let p = device.peripheral
        peripheral = p
        p.delegate = self
        notifyChar = nil; writeChar = nil
        reassembler = DJIBLEReassembler()
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            connectContinuation = c
            central.connect(p, options: nil)
            mainAfter(timeout) { [weak self] in
                guard let self, let c = self.connectContinuation else { return }
                self.connectContinuation = nil
                c.resume(throwing: BLEError.timeout("连接/发现服务"))
            }
        }
        log("已连接并订阅 FFF4 通知")
    }

    private func failConnection(_ e: Error) {
        if let c = connectContinuation { connectContinuation = nil; c.resume(throwing: e) }
        if let w = responseWaiter { responseWaiter = nil; w.cont.resume(throwing: e) }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        log("已连接，正在发现服务…")
        peripheral.discoverServices(nil)
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        failConnection(BLEError.connectFailed(error?.localizedDescription ?? "未知错误"))
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        log("蓝牙已断开")
        writeChar = nil; notifyChar = nil
        failConnection(BLEError.notConnected)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error { failConnection(BLEError.connectFailed(error.localizedDescription)); return }
        let services = peripheral.services ?? []
        if services.isEmpty { failConnection(BLEError.characteristicsMissing); return }
        services.forEach { peripheral.discoverCharacteristics([CBUUID(string: DJIBLE.notifyCharacteristic), CBUUID(string: DJIBLE.writeCharacteristic)], for: $0) }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        for ch in service.characteristics ?? [] {
            if ch.uuid == CBUUID(string: DJIBLE.notifyCharacteristic) { notifyChar = ch; peripheral.setNotifyValue(true, for: ch) }
            if ch.uuid == CBUUID(string: DJIBLE.writeCharacteristic) { writeChar = ch }
        }
        let allDone = (peripheral.services ?? []).allSatisfy { $0.characteristics != nil }
        if allDone, notifyChar == nil || writeChar == nil { failConnection(BLEError.characteristicsMissing) }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard characteristic.uuid == CBUUID(string: DJIBLE.notifyCharacteristic) else { return }
        if let error { failConnection(BLEError.connectFailed(error.localizedDescription)); return }
        if writeChar != nil, let c = connectContinuation { connectContinuation = nil; c.resume() }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let v = characteristic.value else { return }
        for frame in reassembler.push(Bytes(v)) {
            do {
                let m = try DJIBLE.parse(frame)
                if let b = DJIBLE.battery(from: m), b <= 100 { battery = b; onBattery?(b); log("电池：\(b)%") }
                if let w = responseWaiter, w.id == m.id { responseWaiter = nil; w.cont.resume(returning: m) }
            } catch {
                log("BLE 收到损坏数据：\(frame.hexString()) — \(error)")
            }
        }
    }

    // MARK: Messages

    private func send(_ m: DJIBLEMessage) throws {
        guard let p = peripheral, let w = writeChar else { throw BLEError.notConnected }
        p.writeValue(Data(DJIBLE.build(m)), for: w, type: .withoutResponse)
    }

    func sendAndWait(_ m: DJIBLEMessage, timeout: TimeInterval = 10) async throws -> DJIBLEMessage {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<DJIBLEMessage, Error>) in
            if let old = responseWaiter { responseWaiter = nil; old.cont.resume(throwing: BLEError.timeout("被新请求取代")) }
            responseWaiter = (m.id, c)
            do { try send(m) } catch { responseWaiter = nil; c.resume(throwing: error); return }
            mainAfter(timeout) { [weak self] in
                guard let self, let w = self.responseWaiter, w.id == m.id else { return }
                self.responseWaiter = nil
                w.cont.resume(throwing: BLEError.timeout(String(format: "id=0x%04X", m.id)))
            }
        }
    }

    /// 配对。先用 PIN「mbln」（Pocket 3：任何应答都继续）。超时或出错再改用「osmo」。
    /// osmo 的 00 01 / 00 02 算成功；00 06 不是「请在屏幕上确认」。返回 true 表示相机报告已经配对。
    @discardableResult
    func pair() async throws -> Bool {
        log("正在配对…（首次配对请在相机屏幕上点击确认）")
        do {
            let r = try await sendAndWait(DJIBLE.pairMessage(pin: DJIBLE.pairPIN))
            activePairPIN = DJIBLE.pairPIN
            log("配对应答（PIN mbln）：\(r.payload.hexString(separator: " "))")
            switch DJIBLE.interpretPairReply(pin: DJIBLE.pairPIN, payload: r.payload) {
            case .alreadyPaired: log("相机报告：已配对"); return true
            case .approveOnCamera: log("已发送配对请求，相机应当确认"); return false
            case .notApproval: break
            }
        } catch {
            log("PIN「mbln」没有成功（\(error.localizedDescription)），改用「osmo」重试")
        }
        let r = try await sendAndWait(DJIBLE.pairMessage(pin: DJIBLE.pairPINOsmo))
        log("配对应答（PIN osmo）：\(r.payload.hexString(separator: " "))")
        switch DJIBLE.interpretPairReply(pin: DJIBLE.pairPINOsmo, payload: r.payload) {
        case .alreadyPaired:
            activePairPIN = DJIBLE.pairPINOsmo
            log("相机报告：已配对（PIN osmo）")
            return true
        case .approveOnCamera:
            activePairPIN = DJIBLE.pairPINOsmo
            log("配对请求已发送（PIN osmo，应答 00 02）。请在相机屏幕上点允许")
            return false
        case .notApproval:
            throw BLEError.connectFailed("PIN「osmo」应答 \(r.payload.hexString(separator: " ")) 不是配对成功（00 06 不是屏幕确认）")
        }
    }

    func stopStreaming() async {
        log("发送停止推流（清理）…")
        do { let r = try await sendAndWait(DJIBLE.stopStreamingMessage, timeout: 5); log("停止推流应答：\(r.payload.hexString())") }
        catch { log("停止推流超时（可能正常）") }
    }

    func prepareLivestream() async throws {
        log("准备直播…")
        let r = try await sendAndWait(DJIBLE.prepareLivestreamMessage)
        log("准备直播应答：\(r.payload.hexString())")
    }

    func setupWiFi(ssid: String, password: String) async throws {
        log("让相机连接 Wi-Fi：\(ssid)")
        let r = try await sendAndWait(DJIBLE.setupWiFiMessage(ssid: ssid, password: password))
        guard r.payload == [0, 0] else { throw BLEError.wifiSetupFailed(r.payload.hexString()) }
        log("相机 Wi-Fi 配置成功")
    }

    func startRTMP(url: String, resolution: DJIBLE.RTMPResolution, fps: Int, bitrateKbps: Int) async throws {
        log("开始 RTMP 推流：\(url)")
        let r = try await sendAndWait(DJIBLE.startRTMPMessage(url: url, resolution: resolution, fps: fps, bitrateKbps: bitrateKbps))
        log("开始推流应答：\(r.payload.hexString())")
    }

    func disconnect() {
        if let p = peripheral { central.cancelPeripheralConnection(p) }
        peripheral = nil; writeChar = nil; notifyChar = nil
        if let c = scanContinuation { scanContinuation = nil; central.stopScan(); c.resume(returning: []) }
    }
}
