// SettingsWindowController.swift — 设置窗口（⌘,）

import AppKit

@MainActor
final class SettingsWindowController: NSWindowController, NSTextFieldDelegate {
    private let s = AppSettings.shared
    private let ssid = NSTextField(string: "")
    private let password = NSSecureTextField(string: "")
    private let passwordPlain = NSTextField(string: "")
    private let ip = NSTextField(string: "")
    private let bleTimeout = NSTextField(string: "")
    private let apWait = NSTextField(string: "")
    private let transport = NSPopUpButton()
    private let format = NSPopUpButton()
    private let axisOrder = NSPopUpButton()
    private let folderLabel = UI.label("", size: 12, color: .secondaryLabelColor)
    private lazy var wifiOnly = UI.checkbox("仅通过 Wi-Fi 网卡发送（推荐）", on: s.wifiInterfaceOnly, target: self, action: #selector(save))
    private lazy var scroll = UI.checkbox("触控板双指滑动控制云台", on: s.trackpadScrollControl, target: self, action: #selector(save))
    private lazy var drag = UI.checkbox("在画面上拖动控制云台", on: s.dragOnVideoControl, target: self, action: #selector(save))
    private lazy var invert = UI.checkbox("反转俯仰（上/下）方向", on: s.invertPitch, target: self, action: #selector(save))
    private lazy var invertYaw = UI.checkbox("反转水平（左/右）方向", on: s.invertYaw, target: self, action: #selector(save))
    private lazy var tcpPoke = UI.checkbox("握手前通过 TCP 7001 发送配对信息并保持连接（推荐，提升重连成功率）", on: s.tcpPoke, target: self, action: #selector(save))
    private lazy var autoExitPlayback = UI.checkbox("拍照后相机自动进入回放时，自动退出回放以恢复实时画面", on: s.autoExitPlayback, target: self, action: #selector(save))
    private lazy var mimoKeepalive = UI.checkbox("Mimo 链路心跳（推荐；取消勾选恢复旧版 0x4F，便于实机对比）", on: s.mimoLinkKeepalive, target: self, action: #selector(save))
    private lazy var legacyFraming = UI.checkbox("使用原 Python 的 UDP 命令头 / ACK 布局（仅当新布局出问题时对比用）", on: s.legacyFraming, target: self, action: #selector(save))
    private lazy var swap = UI.checkbox("使用旧版姿态解析（原 Python 项目的字段布局，仅用于对比调试）", on: s.swapPitchYaw, target: self, action: #selector(save))
    private lazy var stream = UI.checkbox("（已停用）持续发送云台速度——会导致相机停止应答", on: s.continuousGimbalStream, target: self, action: #selector(save))
    private lazy var showPw = UI.checkbox("显示密码", on: false, target: self, action: #selector(togglePw))

    init() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 920), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = "设置"
        super.init(window: w)
        build()
        load()
        w.center()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func field(_ f: NSTextField, _ w: CGFloat, _ placeholder: String = "") -> NSTextField {
        f.translatesAutoresizingMaskIntoConstraints = false
        f.widthAnchor.constraint(equalToConstant: w).isActive = true
        f.placeholderString = placeholder
        f.delegate = self
        return f
    }

    private func build() {
        transport.addItems(withTitles: TransportKind.allCases.map(\.displayName))
        format.addItems(withTitles: RecordingFormat.allCases.map(\.displayName))
        transport.target = self; transport.action = #selector(save)
        format.target = self; format.action = #selector(save)
        axisOrder.addItems(withTitles: ["Pitch, Roll, Yaw（默认，实机验证）", "Yaw, Roll, Pitch（原 Python 字段顺序）"])
        axisOrder.target = self; axisOrder.action = #selector(save)
        passwordPlain.isHidden = true
        let pwStack = UI.hstack([field(password, 220, "相机 Wi-Fi 密码"), field(passwordPlain, 220), showPw], spacing: 8)

        let grid = NSGridView(views: [
            [UI.headline("相机"), NSGridCell.emptyContentView],
            [UI.label("Wi-Fi 名称"), field(ssid, 260, "例如 OsmoPocket3-D6B1")],
            [UI.label("Wi-Fi 密码"), pwStack],
            [UI.label("相机 IP"), field(ip, 140)],
            [UI.label("蓝牙扫描（秒）"), field(bleTimeout, 60)],
            [UI.label("等待热点（秒）"), field(apWait, 60)],
            [UI.headline("网络"), NSGridCell.emptyContentView],
            [UI.label("传输方式"), transport],
            [NSGridCell.emptyContentView, wifiOnly],
            [UI.headline("录制"), NSGridCell.emptyContentView],
            [UI.label("文件格式"), format],
            [UI.label("保存位置"), UI.hstack([folderLabel, UI.button("选择…", target: self, action: #selector(chooseFolder))], spacing: 8)],
            [UI.headline("云台与输入"), NSGridCell.emptyContentView],
            [NSGridCell.emptyContentView, scroll],
            [NSGridCell.emptyContentView, drag],
            [UI.label("速度命令轴顺序"), axisOrder],
            [NSGridCell.emptyContentView, invert],
            [NSGridCell.emptyContentView, invertYaw],
            [NSGridCell.emptyContentView, swap],
            [NSGridCell.emptyContentView, tcpPoke],
            [NSGridCell.emptyContentView, autoExitPlayback],
            [NSGridCell.emptyContentView, mimoKeepalive],
            [NSGridCell.emptyContentView, legacyFraming],
            [NSGridCell.emptyContentView, UI.button("重新显示新手引导", symbol: "graduationcap", target: self, action: #selector(onboarding))],
        ])
        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.rowSpacing = 10
        grid.columnSpacing = 12
        grid.column(at: 0).xPlacement = .trailing
        for r in [0, 6, 9, 12] { grid.row(at: r).topPadding = r == 0 ? 0 : 10; grid.cell(atColumnIndex: 0, rowIndex: r).xPlacement = .leading }
        let note = UI.wrappingLabel("密码保存在系统钥匙串中。修改网络设置后需重新连接才会生效。链路心跳切换后立即生效：默认每秒发送 General:0x0E，并停止周期读取版本配置 0x4F；取消勾选则恢复旧版 0x4F。连接日志会写明当前模式。", size: 11)
        let stack = UI.vstack([grid, note], spacing: 16)
        let content = NSView()
        content.addSubview(stack)
        UI.pin(stack, to: content, inset: 24)
        window?.contentView = content
    }

    private func load() {
        ssid.stringValue = s.ssid
        password.stringValue = s.password; passwordPlain.stringValue = s.password
        ip.stringValue = s.cameraIP
        bleTimeout.stringValue = String(Int(s.bleTimeout))
        apWait.stringValue = String(Int(s.apWaitSeconds))
        transport.selectItem(at: TransportKind.allCases.firstIndex(of: s.transport) ?? 0)
        format.selectItem(at: RecordingFormat.allCases.firstIndex(of: s.recordingFormat) ?? 0)
        axisOrder.selectItem(at: GimbalAxisOrder.allCases.firstIndex(of: s.gimbalAxisOrder) ?? 0)
        folderLabel.stringValue = (s.recordingFolder.path as NSString).abbreviatingWithTildeInPath
    }

    func controlTextDidChange(_ obj: Notification) {
        if (obj.object as? NSTextField) === passwordPlain { password.stringValue = passwordPlain.stringValue }
        if (obj.object as? NSTextField) === password { passwordPlain.stringValue = password.stringValue }
    }
    func controlTextDidEndEditing(_ obj: Notification) { save() }

    @objc private func togglePw() {
        let show = showPw.state == .on
        passwordPlain.isHidden = !show; password.isHidden = show
    }

    @objc private func save() {
        s.ssid = ssid.stringValue.trimmingCharacters(in: .whitespaces)
        if s.password != password.stringValue { s.password = password.stringValue }
        let ipv = ip.stringValue.trimmingCharacters(in: .whitespaces)
        s.cameraIP = ipv.isEmpty ? DJIUDPFrame.cameraIP : ipv
        s.bleTimeout = max(3, Double(bleTimeout.stringValue) ?? 15)
        s.apWaitSeconds = max(0, Double(apWait.stringValue) ?? 20)
        s.transport = TransportKind.allCases[max(0, transport.indexOfSelectedItem)]
        s.recordingFormat = RecordingFormat.allCases[max(0, format.indexOfSelectedItem)]
        s.wifiInterfaceOnly = wifiOnly.state == .on
        s.trackpadScrollControl = scroll.state == .on
        s.dragOnVideoControl = drag.state == .on
        s.invertPitch = invert.state == .on
        s.invertYaw = invertYaw.state == .on
        s.gimbalAxisOrder = GimbalAxisOrder.allCases[max(0, axisOrder.indexOfSelectedItem)]
        s.swapPitchYaw = swap.state == .on
        s.legacyFraming = legacyFraming.state == .on
        s.tcpPoke = tcpPoke.state == .on
        s.autoExitPlayback = autoExitPlayback.state == .on
        s.mimoLinkKeepalive = mimoKeepalive.state == .on
        AppModel.shared.applyLinkSettings()
    }

    @objc private func chooseFolder() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true; p.canChooseFiles = false; p.canCreateDirectories = true
        p.prompt = "选择"
        p.beginSheetModal(for: window!) { [weak self] r in
            MainActor.assumeIsolated {
                guard r == .OK, let u = p.url, let self else { return }
                self.s.recordingFolder = u
                self.load()
            }
        }
    }

    @objc private func onboarding() { NSApp.sendAction(#selector(AppDelegate.showOnboarding(_:)), to: nil, from: self) }
}
