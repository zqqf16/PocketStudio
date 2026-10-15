// DebugViewController.swift — DUML 日志、原始命令（原项目 /api/camera/raw）、蓝牙 RTMP 直播（实验）

import AppKit

@MainActor
final class DebugViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    private let model = AppModel.shared
    private let tabs = NSTabView()
    private let table = NSTableView()
    private var rows: [DUMLLogEntry] = []
    private lazy var pauseBox = UI.checkbox("暂停", on: false, target: self, action: #selector(pauseChanged))
    private lazy var hideHF = UI.checkbox("隐藏高频心跳/状态推送", on: true, target: self, action: #selector(reload))
    private let filterField = NSSearchField()
    private var observer: NSObjectProtocol?
    private let timeFmt: DateFormatter = { let f = DateFormatter(); f.dateFormat = "HH:mm:ss.SSS"; return f }()

    // 原始命令
    private let rawSet = NSTextField(string: "2"), rawID = NSTextField(string: "0x01"), rawPayload = NSTextField(string: "")
    private let rawRecvType = NSTextField(string: "1"), rawRecvID = NSTextField(string: "0")
    private let rawCmdType = NSPopUpButton()

    // RTMP
    private let rSSID = NSTextField(string: ""), rPass = NSSecureTextField(string: "")
    private let rURL = NSTextField(string: "rtmp://")
    private let rRes = NSPopUpButton(), rFPS = NSPopUpButton()
    private let rBitrate = NSTextField(string: "6000")

    override func loadView() {
        let root = NSView()
        tabs.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(tabs)
        UI.pin(tabs, to: root.safeAreaLayoutGuide, inset: 12)
        let t1 = NSTabViewItem(identifier: "log"); t1.label = "DUML 日志"; t1.view = buildLogTab()
        let t2 = NSTabViewItem(identifier: "raw"); t2.label = "原始命令"; t2.view = buildRawTab()
        let t3 = NSTabViewItem(identifier: "rtmp"); t3.label = "蓝牙直播（实验）"; t3.view = buildRTMPTab()
        [t1, t2, t3].forEach(tabs.addTabViewItem)
        view = root
    }

    private func buildLogTab() -> NSView {
        let v = NSView()
        filterField.placeholderString = "过滤（命令、设备、十六进制…）"
        filterField.target = self; filterField.action = #selector(reload)
        filterField.translatesAutoresizingMaskIntoConstraints = false
        filterField.widthAnchor.constraint(equalToConstant: 240).isActive = true
        let bar = UI.hstack([pauseBox, hideHF, filterField, NSView(),
                             UI.button("拷贝选中", symbol: "doc.on.doc", target: self, action: #selector(copySelected)),
                             UI.button("导出…", symbol: "square.and.arrow.up", target: self, action: #selector(export)),
                             UI.button("清空", symbol: "trash", target: self, action: #selector(clear))], spacing: 10)
        let cols: [(String, String, CGFloat)] = [("time", "时间", 92), ("dir", "方向", 40), ("route", "路由", 170), ("type", "类型", 56),
                                                 ("cmd", "命令", 120), ("seq", "序号", 56), ("len", "长度", 44), ("payload", "负载 (hex)", 420)]
        for (id, title, w) in cols {
            let c = NSTableColumn(identifier: .init(id)); c.title = title; c.width = w; c.minWidth = 30
            table.addTableColumn(c)
        }
        table.usesAlternatingRowBackgroundColors = true
        table.style = .fullWidth
        table.allowsMultipleSelection = true
        table.dataSource = self; table.delegate = self
        table.rowHeight = 18
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        v.addSubview(bar); v.addSubview(scroll)
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: v.topAnchor, constant: 8),
            bar.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 8),
            bar.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -8),
            scroll.topAnchor.constraint(equalTo: bar.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: v.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: v.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: v.bottomAnchor),
        ])
        return v
    }

    private func formRow(_ title: String, _ field: NSView, width: CGFloat = 220) -> [NSView] {
        field.translatesAutoresizingMaskIntoConstraints = false
        if field is NSTextField { field.widthAnchor.constraint(equalToConstant: width).isActive = true }
        return [UI.label(title, color: .secondaryLabelColor), field]
    }

    private func buildRawTab() -> NSView {
        rawCmdType.addItems(withTitles: ["REQ 需应答 (0x40)", "NOTIFY 无应答 (0x00)", "WRITE (0x80)", "ACK (0x20)"])
        rawPayload.placeholderString = "例如 01 00 ff（留空 = 无负载）"
        let grid = NSGridView(views: [
            formRow("命令集 cmd_set", rawSet, width: 80),
            formRow("命令 cmd_id", rawID, width: 80),
            formRow("负载 payload (hex)", rawPayload, width: 360),
            formRow("接收设备类型", rawRecvType, width: 80),
            formRow("接收设备 ID", rawRecvID, width: 80),
            formRow("命令类型", rawCmdType),
        ])
        grid.rowSpacing = 10; grid.column(at: 0).xPlacement = .trailing
        let presets = UI.hstack([
            UI.button("拍照 2:01 [01]", target: self, action: #selector(presetPhoto)),
            UI.button("开始录像 2:02 [01]", target: self, action: #selector(presetRecStart)),
            UI.button("停止录像 2:02 [00]", target: self, action: #selector(presetRecStop)),
            UI.button("拍照模式 2:E1 [05]（Pocket 3）", target: self, action: #selector(presetMode)),
        ], spacing: 8)
        let stack = UI.vstack([
            UI.title("发送原始 DUML 命令"),
            UI.wrappingLabel("对应原项目 Web UI 的 /api/camera/raw，用于协议实验。数字支持十进制或 0x 十六进制。设备类型：1=相机 4=云台 8=DM368 13=ESC。发送方固定为 App(2,0)。"),
            CardView(grid), UI.headline("快捷预设"), presets,
            UI.button("发送", symbol: "paperplane.fill", target: self, action: #selector(sendRaw), prominent: true),
        ], spacing: 14)
        return UI.scrollingPage(stack)
    }

    private func buildRTMPTab() -> NSView {
        rRes.addItems(withTitles: DJIBLE.RTMPResolution.allCases.map(\.rawValue)); rRes.selectItem(withTitle: "1080p")
        rFPS.addItems(withTitles: ["30", "25"])
        rURL.placeholderString = "rtmp://服务器/live/推流码"
        let grid = NSGridView(views: [
            formRow("路由器 Wi-Fi 名称", rSSID), formRow("路由器 Wi-Fi 密码", rPass),
            formRow("RTMP 地址", rURL, width: 360), formRow("分辨率", rRes), formRow("帧率", rFPS),
            formRow("码率 (kbps)", rBitrate, width: 80),
        ])
        grid.rowSpacing = 10; grid.column(at: 0).xPlacement = .trailing
        let stack = UI.vstack([
            UI.title("通过蓝牙让相机直接推流 RTMP"),
            UI.wrappingLabel("原项目 ble.py 中保留的 Moblin 直播能力（主流程未使用）：相机经蓝牙配对后，自行连接你的路由器 Wi-Fi，并向 RTMP 服务器推流。与本机实时取景互斥——请先断开相机连接。此功能尚未充分验证。"),
            CardView(grid),
            UI.hstack([UI.button("开始推流", symbol: "dot.radiowaves.up.forward", target: self, action: #selector(startRTMP), prominent: true),
                       UI.button("停止推流", symbol: "stop.fill", target: self, action: #selector(stopRTMP))], spacing: 10),
        ], spacing: 14)
        return UI.scrollingPage(stack)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        observer = NotificationCenter.default.addObserver(forName: .logAppended, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleReload() }
        }
        reload()
    }

    private var reloadScheduled = false

    override func viewDidAppear() {
        super.viewDidAppear()
        reload()   // 重新可见时补一次（隐藏期间的通知被 reload() 的 window 检查挡掉）
    }

    /// 日志追加通知很密集（命令高频期每秒几十条），每条都全量过滤 + 重建表格会卡主线程。
    /// 节流到最多 4 次/秒：日志持续不断时也不会像纯防抖那样被饿死（到期必刷一次）。
    private func scheduleReload() {
        guard !reloadScheduled else { return }
        reloadScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.reloadScheduled = false
                self.reload()
            }
        }
    }

    @objc private func reload() {
        guard view.window != nil || rows.isEmpty else { return }
        let q = filterField.stringValue.lowercased()
        let hf = hideHF.state == .on
        rows = model.dumlLog.filter { e in
            if hf && e.isHighFrequency { return false }
            if q.isEmpty { return true }
            return "\(e.route) \(e.command) \(e.packet.payload.hexString())".lowercased().contains(q)
        }
        let scroll = table.enclosingScrollView
        let atBottom = (scroll?.verticalScroller?.floatValue ?? 1) > 0.98 || rows.count < 30
        table.reloadData()
        if atBottom, !rows.isEmpty { table.scrollRowToVisible(rows.count - 1) }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let id = tableColumn?.identifier.rawValue else { return nil }
        let reuse = NSUserInterfaceItemIdentifier("cell-\(id)")
        let tf = (tableView.makeView(withIdentifier: reuse, owner: self) as? NSTextField) ?? {
            let t = NSTextField(labelWithString: ""); t.identifier = reuse
            t.font = .monospacedSystemFont(ofSize: 11, weight: .regular); t.lineBreakMode = .byTruncatingTail
            return t
        }()
        let e = rows[row], p = e.packet
        tf.textColor = .labelColor
        switch id {
        case "time": tf.stringValue = timeFmt.string(from: e.time)
        case "dir": tf.stringValue = e.direction.rawValue; tf.textColor = e.direction == .rx ? .systemBlue : .systemOrange
        case "route": tf.stringValue = e.route
        case "type": tf.stringValue = DUMLCmdType.name(p.cmdType)
        case "cmd": tf.stringValue = e.command
        case "seq": tf.stringValue = "\(p.seq)"
        case "len": tf.stringValue = "\(p.payload.count)"
        default: tf.stringValue = Bytes(p.payload.prefix(96)).hexString(separator: " ")
        }
        return tf
    }

    private func line(_ e: DUMLLogEntry) -> String {
        "\(timeFmt.string(from: e.time)) \(e.direction.rawValue) \(e.route) \(DUMLCmdType.name(e.packet.cmdType)) \(e.command) seq=\(e.packet.seq) (\(e.packet.payload.count)B) \(e.packet.payload.hexString(separator: " "))"
    }

    @objc private func pauseChanged() { model.logPaused = pauseBox.state == .on }
    @objc private func clear() { model.clearLogs() }
    @objc private func copySelected() { UI.copyToPasteboard(table.selectedRowIndexes.map { line(rows[$0]) }.joined(separator: "\n")) }
    @objc private func export() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "pocketstudio-duml.log"
        panel.beginSheetModal(for: view.window!) { [weak self] r in
            MainActor.assumeIsolated {
                guard r == .OK, let self, let url = panel.url else { return }
                let text = self.model.dumlLog.map(self.line).joined(separator: "\n") + "\n\n" + self.model.textLog.joined(separator: "\n")
                try? text.write(to: url, atomically: true, encoding: .utf8)
            }
        }
    }

    private func num(_ s: String) -> UInt8? {
        let t = s.trimmingCharacters(in: .whitespaces).lowercased()
        return t.hasPrefix("0x") ? UInt8(t.dropFirst(2), radix: 16) : UInt8(t)
    }

    @objc private func sendRaw() {
        guard let set = num(rawSet.stringValue), let id = num(rawID.stringValue),
              let rt = num(rawRecvType.stringValue), let ri = num(rawRecvID.stringValue) else {
            alert("请检查数字格式（0–255，可用 0x 前缀）"); return
        }
        guard let payload = Bytes(hexString: rawPayload.stringValue) else { alert("负载不是有效的十六进制"); return }
        let types: [UInt8] = [DUMLCmdType.request, DUMLCmdType.notify, DUMLCmdType.write, DUMLCmdType.ack]
        model.sendRaw(cmdSet: set, cmdID: id, payload: payload, receiverType: rt, receiverID: ri, cmdType: types[max(0, rawCmdType.indexOfSelectedItem)])
    }

    private func preset(_ set: String, _ id: String, _ payload: String) {
        rawSet.stringValue = set; rawID.stringValue = id; rawPayload.stringValue = payload
        rawRecvType.stringValue = "1"; rawRecvID.stringValue = "0"; rawCmdType.selectItem(at: 0)
    }
    @objc private func presetPhoto() { preset("2", "0x01", "01") }
    @objc private func presetRecStart() { preset("2", "0x02", "01") }
    @objc private func presetRecStop() { preset("2", "0x02", "00") }
    @objc private func presetMode() { preset("2", "0xE1", "05") }

    @objc private func startRTMP() {
        guard !model.isConnected else { alert("请先断开实时取景连接"); return }
        guard rURL.stringValue.lowercased().hasPrefix("rtmp"), !rSSID.stringValue.isEmpty else { alert("请填写路由器 Wi-Fi 名称和 RTMP 地址"); return }
        model.runRTMPFlow(routerSSID: rSSID.stringValue, routerPassword: rPass.stringValue, url: rURL.stringValue,
                          resolution: DJIBLE.RTMPResolution(rawValue: rRes.titleOfSelectedItem ?? "1080p") ?? .p1080,
                          fps: Int(rFPS.titleOfSelectedItem ?? "30") ?? 30, bitrate: Int(rBitrate.stringValue) ?? 6000)
    }
    @objc private func stopRTMP() { model.stopRTMP() }

    private func alert(_ s: String) {
        let a = NSAlert(); a.messageText = s; a.alertStyle = .warning
        if let w = view.window { a.beginSheetModal(for: w) } else { a.runModal() }
    }
}
