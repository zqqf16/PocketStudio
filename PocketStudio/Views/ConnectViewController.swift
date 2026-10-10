// ConnectViewController.swift — 连接页：步骤进度、选项、手动加入 Wi-Fi 引导、运行日志

import AppKit

@MainActor
final class ConnectViewController: NSViewController {
    private let model = AppModel.shared
    private var stepRows: [(icon: NSImageView, title: NSTextField, detail: NSTextField, spinner: NSProgressIndicator)] = []
    private lazy var connectButton = UI.glassButton("连接相机", symbol: "bolt.horizontal.circle", target: self, action: #selector(connectTapped), prominent: true)
    private lazy var skipBLE = UI.checkbox("跳过蓝牙（相机 Wi-Fi 已经开启）", on: model.settings.skipBLE, target: self, action: #selector(optionsChanged))
    private lazy var skipWiFi = UI.checkbox("跳过加入 Wi-Fi（Mac 已连上相机热点）", on: model.settings.skipWiFi, target: self, action: #selector(optionsChanged))
    private let ssidLabel = UI.label("", size: 13, weight: .medium)
    private let networkLabel = UI.label("", size: 12, color: .secondaryLabelColor)
    private let manualReason = UI.wrappingLabel("")
    private var manualCard: NSView!
    private let logView = NSTextView()
    private var observers: [NSObjectProtocol] = []

    override func loadView() {
        let stack = UI.vstack([], spacing: 18)
        stack.addArrangedSubview(UI.title("连接相机"))
        stack.addArrangedSubview(UI.wrappingLabel("流程：蓝牙唤醒相机 → 相机开启 Wi-Fi 热点 → Mac 加入热点 → UDP 握手 → 接收实时画面。整个过程约 30–60 秒。"))

        // 目标网络
        let editBtn = UI.button("修改…", symbol: "pencil", target: self, action: #selector(openSettings))
        let netRow = UI.hstack([NSImageView(image: UI.symbol("wifi", size: 14) ?? NSImage()), ssidLabel, editBtn], spacing: 8)
        stack.addArrangedSubview(CardView(UI.vstack([netRow, networkLabel, skipBLE, skipWiFi], spacing: 8)))

        // 步骤
        let steps = UI.vstack([], spacing: 10)
        for s in AppModel.freshSteps() {
            let icon = NSImageView(image: UI.symbol(s.symbol, size: 15) ?? NSImage())
            icon.translatesAutoresizingMaskIntoConstraints = false
            icon.widthAnchor.constraint(equalToConstant: 22).isActive = true
            let spinner = NSProgressIndicator()
            spinner.style = .spinning; spinner.controlSize = .small; spinner.isDisplayedWhenStopped = false
            let t = UI.label(s.title, size: 13, weight: .medium)
            let d = UI.wrappingLabel("", size: 12)
            let text = UI.vstack([t, d], spacing: 2)
            let row = UI.hstack([icon, text, spinner], spacing: 10, alignment: .top)
            steps.addArrangedSubview(row)
            text.widthAnchor.constraint(greaterThanOrEqualToConstant: 300).isActive = true
            stepRows.append((icon, t, d, spinner))
        }
        stack.addArrangedSubview(CardView(steps))

        // 手动 Wi-Fi 引导
        manualCard = buildManualCard()
        stack.addArrangedSubview(manualCard)

        stack.addArrangedSubview(UI.hstack([connectButton,
                                            UI.button("打开 Wi-Fi 设置", symbol: "wifi", target: self, action: #selector(openWiFi)),
                                            UI.button("新手引导", symbol: "graduationcap", target: self, action: #selector(openOnboarding))], spacing: 10))

        // 日志
        stack.addArrangedSubview(UI.headline("运行日志"))
        logView.isEditable = false
        logView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        logView.drawsBackground = false
        logView.textContainerInset = NSSize(width: 6, height: 6)
        let logScroll = NSScrollView()
        logScroll.documentView = logView
        logScroll.hasVerticalScroller = true
        logScroll.drawsBackground = false
        logScroll.translatesAutoresizingMaskIntoConstraints = false
        logView.autoresizingMask = [.width]
        logScroll.heightAnchor.constraint(equalToConstant: 200).isActive = true
        let logCard = CardView(logScroll, padding: 4)
        stack.addArrangedSubview(logCard)
        for v in stack.arrangedSubviews where v is CardView { v.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        view = UI.scrollingPage(stack)
    }

    private func buildManualCard() -> NSView {
        let icon = NSImageView(image: UI.symbol("hand.raised.fill", size: 18) ?? NSImage())
        icon.contentTintColor = .systemOrange
        let head = UI.hstack([icon, UI.headline("请手动加入相机 Wi-Fi（连上后会自动继续）")], spacing: 8)
        let steps = UI.wrappingLabel("""
        1. 点击下方「拷贝密码」。
        2. 点击「打开 Wi-Fi 设置」，或点 Mac 屏幕右上角菜单栏的 Wi-Fi 图标。
        3. 在列表中选择相机热点（名称形如 OsmoPocket3-XXXX），粘贴密码（⌘V），点「加入」。
        4. 回到本窗口，App 检测到 192.168.2.x 地址后会自动继续；也可点「我已连接」。
        若列表里找不到相机热点：相机 Wi-Fi 可能尚未开启，请等待 20 秒，或在相机上重新进入「Wi-Fi/无线连接」。
        """, size: 13, color: .labelColor)
        let buttons = UI.hstack([
            UI.button("拷贝 Wi-Fi 名称", symbol: "doc.on.doc", target: self, action: #selector(copySSID)),
            UI.button("拷贝密码", symbol: "key", target: self, action: #selector(copyPassword)),
            UI.button("打开 Wi-Fi 设置", symbol: "wifi", target: self, action: #selector(openWiFi)),
            UI.button("我已连接", symbol: "checkmark", target: self, action: #selector(recheck), prominent: true),
        ], spacing: 8)
        let card = CardView(UI.vstack([head, manualReason, steps, buttons], spacing: 10))
        card.isHidden = true
        return card
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        observers.append(NotificationCenter.default.addObserver(forName: .modelChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        })
        observers.append(NotificationCenter.default.addObserver(forName: .logAppended, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshLog() }
        })
        observers.append(NotificationCenter.default.addObserver(forName: .settingsChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        })
        refresh(); refreshLog()
    }

    override func viewWillAppear() { super.viewWillAppear(); refresh() }

    private func refresh() {
        let s = model.settings
        ssidLabel.stringValue = s.ssid.isEmpty ? "尚未设置相机 Wi-Fi 名称" : "相机 Wi-Fi：\(s.ssid)"
        ssidLabel.textColor = s.ssid.isEmpty ? .systemOrange : .labelColor
        let cur = model.wifi.currentSSID
        let addr = model.wifi.localCameraNetworkAddress
        networkLabel.stringValue = "当前 Wi-Fi：\(cur ?? (model.wifi.locationAuthorized ? "未连接" : "（未授权定位，无法读取名称）"))" + (addr.map { "  ·  相机网段地址：\($0)" } ?? "")

        for (i, st) in model.steps.enumerated() where i < stepRows.count {
            let r = stepRows[i]
            r.detail.stringValue = st.detail
            r.detail.isHidden = st.detail.isEmpty
            let (sym, tint): (String, NSColor) = {
                switch st.status {
                case .pending: return (st.symbol, .tertiaryLabelColor)
                case .active: return (st.symbol, .controlAccentColor)
                case .done: return ("checkmark.circle.fill", .systemGreen)
                case .failed: return ("xmark.octagon.fill", .systemRed)
                case .skipped: return ("arrow.uturn.forward.circle", .secondaryLabelColor)
                }
            }()
            r.icon.image = UI.symbol(sym, size: 15)
            r.icon.contentTintColor = tint
            r.title.textColor = st.status == .pending ? .secondaryLabelColor : .labelColor
            if st.status == .active { r.spinner.startAnimation(nil) } else { r.spinner.stopAnimation(nil) }
        }
        manualCard.isHidden = model.manualWiFiReason == nil
        manualReason.stringValue = model.manualWiFiReason.map { "原因：\($0)" } ?? ""
        switch model.phase {
        case .connected: connectButton.title = "断开连接"; connectButton.image = UI.symbol("xmark.circle", size: 16)
        case .connecting: connectButton.title = "取消"; connectButton.image = UI.symbol("stop.circle", size: 16)
        default: connectButton.title = "连接相机"; connectButton.image = UI.symbol("bolt.horizontal.circle", size: 16)
        }
        skipBLE.isEnabled = !model.isBusy; skipWiFi.isEnabled = !model.isBusy
    }

    private func refreshLog() {
        let atBottom = (logView.enclosingScrollView?.verticalScroller?.floatValue ?? 1) > 0.98
        logView.string = model.textLog.suffix(400).joined(separator: "\n")
        if atBottom { logView.scrollToEndOfDocument(nil) }
    }

    @objc private func connectTapped() {
        if model.isConnected { model.disconnect() } else if model.isBusy { model.cancelConnect() } else { model.connect() }
    }
    @objc private func optionsChanged() {
        model.settings.skipBLE = skipBLE.state == .on
        model.settings.skipWiFi = skipWiFi.state == .on
    }
    @objc private func copySSID() { UI.copyToPasteboard(model.settings.ssid); model.log("已拷贝 Wi-Fi 名称") }
    @objc private func copyPassword() { UI.copyToPasteboard(model.settings.password); model.log("已拷贝 Wi-Fi 密码") }
    @objc private func openWiFi() { WiFiManager.openWiFiSettings() }
    @objc private func recheck() { model.manualWiFiRecheck() }
    @objc private func openSettings() { NSApp.sendAction(#selector(AppDelegate.showSettings(_:)), to: nil, from: self) }
    @objc private func openOnboarding() { NSApp.sendAction(#selector(AppDelegate.showOnboarding(_:)), to: nil, from: self) }
}
