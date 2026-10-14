// OnboardingWindowController.swift — 首次运行新手引导：欢迎 → 权限 → 相机 Wi-Fi 信息 → 连接流程 → 完成

import AppKit
@preconcurrency import CoreBluetooth
@preconcurrency import Network
@preconcurrency import CoreLocation

@MainActor
final class OnboardingWindowController: NSWindowController {
    var onFinish: (() -> Void)?
    private let model = AppModel.shared
    private var pages: [NSView] = []
    private var index = 0
    private let container = NSView()
    private let pageDots = UI.label("", size: 12, color: .secondaryLabelColor)
    private lazy var back = UI.button("上一步", target: self, action: #selector(prev))
    private lazy var next = UI.glassButton("继续", target: self, action: #selector(advance), prominent: true)
    private lazy var skip = UI.button("稍后再说", target: self, action: #selector(finish))

    private let btStatus = UI.label("", size: 12, color: .secondaryLabelColor)
    private let lnStatus = UI.label("", size: 12, color: .secondaryLabelColor)
    private let locStatus = UI.label("", size: 12, color: .secondaryLabelColor)
    private let ssidField = NSTextField(string: "")
    private let pwField = NSTextField(string: "")
    private var timer: Timer?
    private var lnObserver: NSObjectProtocol?

    init() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 560),
                         styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.isMovableByWindowBackground = true
        super.init(window: w)
        build()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.refreshPermissions() } }
        lnObserver = NotificationCenter.default.addObserver(forName: .localNetworkPermissionChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshPermissions() }
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    private func page(symbol: String, title: String, body: String, extra: [NSView] = []) -> NSView {
        let icon = NSImageView(image: UI.symbol(symbol, size: 44, weight: .light) ?? NSImage())
        icon.contentTintColor = .controlAccentColor
        let t = UI.title(title)
        let b = UI.wrappingLabel(body, size: 14)
        let s = UI.vstack([icon, t, b] + extra, spacing: 14)
        s.setCustomSpacing(18, after: icon)
        b.widthAnchor.constraint(equalTo: s.widthAnchor).isActive = true
        return s
    }

    private func permRow(_ symbol: String, _ title: String, _ desc: String, _ status: NSTextField, request: Selector, settings: Selector) -> NSView {
        let icon = NSImageView(image: UI.symbol(symbol, size: 20) ?? NSImage())
        icon.contentTintColor = .controlAccentColor
        icon.widthAnchor.constraint(equalToConstant: 28).isActive = true
        let text = UI.vstack([UI.label(title, size: 13, weight: .semibold), UI.wrappingLabel(desc, size: 12), status], spacing: 2)
        text.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let req = UI.button("请求", target: self, action: request)
        let set = UI.button("系统设置", symbol: "gearshape", target: self, action: settings)
        return CardView(UI.hstack([icon, text, req, set], spacing: 10), padding: 12)
    }

    private func build() {
        pages = [
            page(symbol: "camera.aperture", title: "欢迎使用 PocketStudio",
                 body: "用 Mac 无线连接 DJI Osmo Pocket（3、4 或 4P）：实时取景、录制视频流、拍照 / 录像、切换模式、用键盘或触控板控制云台。\n\n接下来 1 分钟，我们会完成：系统权限 → 填写相机 Wi-Fi → 了解连接流程。"),
            page(symbol: "lock.shield", title: "授予系统权限",
                 body: "macOS 会逐项询问。请全部点「允许」。如果之前点了「不允许」，点右侧「系统设置」手动打开。",
                 extra: [permRow("dot.radiowaves.left.and.right", "蓝牙", "用于唤醒相机的 Wi-Fi 热点（必需）。", btStatus, request: #selector(reqBT), settings: #selector(setBT)),
                         permRow("network", "本地网络", "用于与相机 192.168.2.1 通信（必需）。点「请求」会立即弹出系统授权框，请选择「允许」。", lnStatus, request: #selector(reqLN), settings: #selector(setLN)),
                         permRow("location", "定位服务（可选）", "macOS 要求 App 读取 Wi-Fi 名称必须有定位权限。授予后可自动加入相机 Wi-Fi；不授予则需手动在菜单栏选择。", locStatus, request: #selector(reqLoc), settings: #selector(setLoc))]),
            page(symbol: "wifi", title: "相机 Wi-Fi 名称和密码",
                 body: "在哪里找：在相机屏幕上从顶部向下滑 → 进入设置（齿轮）→「无线连接 / Wi-Fi」菜单，可看到热点名称（形如 OsmoPocket3-XXXX、OsmoPocket4-XXXX 或 OsmoPocket4P-XXXX）和密码。不同固件菜单名称可能略有差异。\n\n不确定也可以先跳过：之后在「设置」中填写，或连接时按提示手动加入。",
                 extra: [buildWiFiForm()]),
            page(symbol: "list.number", title: "连接流程",
                 body: """
                 点击工具栏「连接」后，App 会自动依次：
                 ① 蓝牙扫描并与 Osmo Pocket 配对（首次可能需要在相机上点确认）
                 ② 等待约 20 秒，相机开启 Wi-Fi 热点
                 ③ 让 Mac 加入相机 Wi-Fi（若系统不允许自动加入，会显示手动步骤：拷贝密码 → 菜单栏 Wi-Fi 中选择相机 → 粘贴）
                 ④ 与相机握手并显示实时画面

                 小提示：
                 • 请先彻底关闭手机和电脑上的 DJI Mimo，否则相机会被占用。
                 • 连上相机 Wi-Fi 期间 Mac 无法上网，这是正常现象。
                 • 键盘：方向键/WASD 云台，P 拍照，O 录制，M 切换模式。
                 """),
            page(symbol: "checkmark.seal", title: "准备就绪",
                 body: "打开相机电源，然后点击「开始连接」。\n遇到问题可以随时查看侧边栏的「帮助」。"),
        ]
        let root = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        let spacer = NSView()
        let bar = UI.hstack([skip, spacer, pageDots, back, next], spacing: 10)
        root.addSubview(container); root.addSubview(bar)
        NSLayoutConstraint.activate([
            container.topAnchor.constraint(equalTo: root.topAnchor, constant: 48),
            container.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 48),
            container.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -48),
            container.bottomAnchor.constraint(lessThanOrEqualTo: bar.topAnchor, constant: -16),
            bar.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            bar.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),
            bar.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -20),
        ])
        window?.contentView = root
        show(0)
    }

    private func buildWiFiForm() -> NSView {
        ssidField.stringValue = model.settings.ssid
        pwField.stringValue = model.settings.password
        ssidField.placeholderString = "OsmoPocket3-XXXX / OsmoPocket4P-XXXX"
        pwField.placeholderString = "相机 Wi-Fi 密码"
        for f in [ssidField, pwField] { f.translatesAutoresizingMaskIntoConstraints = false; f.widthAnchor.constraint(equalToConstant: 280).isActive = true }
        let g = NSGridView(views: [[UI.label("Wi-Fi 名称"), ssidField], [UI.label("Wi-Fi 密码"), pwField]])
        g.rowSpacing = 10; g.column(at: 0).xPlacement = .trailing
        return CardView(g, padding: 14)
    }

    private func show(_ i: Int) {
        index = i
        container.subviews.forEach { $0.removeFromSuperview() }
        let p = pages[i]
        container.addSubview(p)
        NSLayoutConstraint.activate([
            p.topAnchor.constraint(equalTo: container.topAnchor),
            p.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            p.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            p.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor),
        ])
        back.isHidden = i == 0
        next.title = i == pages.count - 1 ? "开始连接" : "继续"
        pageDots.stringValue = (0 ..< pages.count).map { $0 == i ? "●" : "○" }.joined(separator: " ")
        refreshPermissions()
    }

    private func saveWiFi() {
        let ssid = ssidField.stringValue.trimmingCharacters(in: .whitespaces)
        if !ssid.isEmpty { model.settings.ssid = ssid }
        if !pwField.stringValue.isEmpty { model.settings.password = pwField.stringValue }
    }

    private func refreshPermissions() {
        switch CBManager.authorization {
        case .allowedAlways: btStatus.stringValue = "✅ 已允许"
        case .denied, .restricted: btStatus.stringValue = "❌ 已拒绝 —— 请点「系统设置」打开"
        default: btStatus.stringValue = "尚未请求"
        }
        let ln = LocalNetworkPermission.shared.state
        lnStatus.stringValue = ln.displayText
        lnStatus.textColor = ln == .denied ? .systemRed : .secondaryLabelColor
        switch model.wifi.locationStatus {
        case .authorizedAlways: locStatus.stringValue = "✅ 已允许"
        case .denied, .restricted: locStatus.stringValue = "未允许（可选）—— 将使用手动加入 Wi-Fi"
        default: locStatus.stringValue = "尚未请求"
        }
    }

    @objc private func reqBT() { model.ble.requestAuthorization() }
    @objc private func setBT() { WiFiManager.openBluetoothPrivacy() }
    @objc private func reqLN() {
        // Bonjour 广播 + 浏览（NSBonjourServices）→ 立即弹出系统「本地网络」授权框，并检测结果
        LocalNetworkPermission.shared.request(cameraIP: model.settings.cameraIP)
        refreshPermissions()
    }
    @objc private func setLN() { LocalNetworkPermission.shared.openSettings() }
    @objc private func reqLoc() { model.wifi.requestLocationAuthorization() }
    @objc private func setLoc() { WiFiManager.openLocationPrivacy() }

    @objc private func prev() { if index > 0 { show(index - 1) } }
    @objc private func advance() {
        if index == 2 { saveWiFi() }
        if index < pages.count - 1 { show(index + 1) } else { finish(); model.connect() }
    }
    @objc private func finish() {
        saveWiFi()
        model.settings.hasCompletedOnboarding = true
        timer?.invalidate()
        LocalNetworkPermission.shared.cleanup()
        window?.close()
        onFinish?()
    }
}
