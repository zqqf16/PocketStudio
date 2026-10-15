// LiveViewController.swift — 主取景界面：全幅实时画面 + Liquid Glass 悬浮控制 + 底部状态栏
//
// 键盘（与原项目 CLI 一致，改为「按住移动、松开停止」）：
//   方向键 / WASD 云台转动   Q/E 慢速左右   R/F 慢速上下   Esc / . 停止云台   1–9 速度
//   空格 / Return 快门（随模式：拍照 / 开始·停止录制）   P 拍照   O 开始/停止录制   M 切换模式   V 显示/隐藏画面   I 统计信息
//   （松开方向键云台本来就会停，空格改给快门，与 iOS 相机习惯一致）
// 触控板：双指滑动 = 微调云台；在画面上按住拖动 = 摇杆。

import AppKit
import CoreMedia

@MainActor
final class LiveViewController: NSViewController {
    private let model = AppModel.shared
    private let videoView = VideoView()
    private let placeholder = NSStackView()
    private let placeholderTitle = UI.label("未连接相机", size: 20, weight: .semibold, color: .white)
    private let placeholderDetail = UI.wrappingLabel("点击「连接」开始：App 会通过蓝牙唤醒 Osmo Pocket 的 Wi-Fi，再接收实时画面。", size: 13, color: NSColor.white.withAlphaComponent(0.7))
    private lazy var placeholderButton = UI.glassButton("连接相机", symbol: "bolt.horizontal.circle", target: self, action: #selector(connectTapped), prominent: true)

    // HUD
    private let recBadge = UI.label("", size: 13, weight: .semibold, color: .white, mono: true)
    private let modeLabel = UI.label("", size: 13, weight: .medium, color: .white)
    private let localRecLabel = UI.label("", size: 12, weight: .medium, color: .white)
    private var hud: NSView!
    private let statsLabel = UI.label("", size: 11, color: .white, mono: true)
    private var statsPanel: NSView!
    private var recoveryPanel: NSView!
    private let recoveryLabel = NSTextField(labelWithString: "")

    // Controls
    private let shutterButton = ShutterButton()
    private let shutterTimer = UI.label("", size: 12, weight: .semibold, color: .white, mono: true)
    private var localRecButton = NSButton()
    private var snapshotButton = NSButton()
    private var controlsPanel: NSView!

    private let joystick = JoystickView()
    private var joystickPanel: NSView!
    private let gimbalModeButton = NSPopUpButton(frame: .zero, pullsDown: true)

    private let statusBar = StatusBarView()
    private let topScrim = ScrimView(edge: .top)
    private let bottomScrim = ScrimView(edge: .bottom)
    static let textShadow: NSShadow = { let s = NSShadow(); s.shadowBlurRadius = 3; s.shadowOffset = .zero; s.shadowColor = NSColor.black.withAlphaComponent(0.8); return s }()
    /// 自动隐藏的控件层（3s 无鼠标活动淡出，悬停淡入）
    private var chromeViews: [NSView] { [topScrim, bottomScrim, hud, statusBar, controlsPanel, joystickPanel, statsPanel] }
    private var chromeVisible = true
    private var chromeTimer: Timer?
    private var trackingArea: NSTrackingArea?

    private var keyMonitor: Any?
    private var held = Set<String>()
    private var overlaysVisible = true
    private var videoHidden = false
    private var scrollStopWork: DispatchWorkItem?
    /// 当前正在驱动云台的连续输入源；保活定时器据此每 100ms 刷新速度（协议层看门狗 300ms 无刷新即归零）
    private enum GimbalSource { case none, keys, joystick, drag, scroll }
    private var gimbalSource: GimbalSource = .none
    private var gimbalInput = (yaw: 0.0, pitch: 0.0)
    private var keepAlive: Timer?
    private var observers: [NSObjectProtocol] = []
    /// 随窗口/激活状态变化的停止钩子（viewDidAppear 安装、viewWillDisappear 移除；不能和 observers 混放，否则反复进出会累积）
    private var stopObservers: [NSObjectProtocol] = []

    override func loadView() {
        let root = NSView()
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor.black.cgColor
        view = root
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        buildVideo()
        buildPlaceholder()
        buildHUD()
        buildControls()
        buildGimbal()
        buildStatusBar()
        let pipeline = model.video
        let m = model
        model.video.onDisplaySample = videoView.makeSink { reason in
            pipeline.noteRendererFlush()
            Task { @MainActor in m.log("视频：\(reason)，已冲刷") }
        }
        model.video.onFlushRenderer = videoView.makeFlusher()
        model.rendererStatus = { [weak self] in self?.videoView.rendererStatusText ?? "—" }
        observers.append(NotificationCenter.default.addObserver(forName: .modelChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        })
        observers.append(NotificationCenter.default.addObserver(forName: .settingsChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }   // 设置变化会刷新云台速度提示等
        })
        refresh()
        let ta = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: nil)
        view.addTrackingArea(ta); trackingArea = ta
        pokeChrome()
    }

    // MARK: 沉浸式：控件自动隐藏

    override func mouseMoved(with event: NSEvent) { pokeChrome() }
    override func mouseEntered(with event: NSEvent) { pokeChrome() }
    override func mouseExited(with event: NSEvent) { scheduleChromeHide(after: 1.0) }

    /// 鼠标活动：淡入控件，3s 后再判断是否淡出
    func pokeChrome() {
        setChrome(visible: true)
        scheduleChromeHide(after: 3.0)
    }

    private func scheduleChromeHide(after t: TimeInterval) {
        chromeTimer?.invalidate()
        chromeTimer = Timer.scheduledTimer(withTimeInterval: t, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.chromeTimerFired() }
        }
    }

    private func chromeTimerFired() {
        if chromePinned { scheduleChromeHide(after: 1.0); return }
        setChrome(visible: false)
        if view.window?.isKeyWindow == true, isMouseOverVideo { NSCursor.setHiddenUntilMouseMoves(true) }
    }

    /// 录制中 / 未连接 / 正在恢复 / 正在操控 / 鼠标在控件上 → 不隐藏
    private var chromePinned: Bool {
        let cam = model.snapshot.camera
        if !model.isConnected || cam.recording || model.isLocalRecording || model.videoRecoveryMessage != nil { return true }
        if gimbalSource != .none || !held.isEmpty { return true }
        guard let w = view.window else { return true }
        let p = view.convert(w.mouseLocationOutsideOfEventStream, from: nil)
        for v in [controlsPanel, joystickPanel, statusBar, hud] where v?.isHidden == false {
            if let v, v.frame.insetBy(dx: -8, dy: -8).contains(p) { return true }
        }
        return false
    }

    private var isMouseOverVideo: Bool {
        guard let w = view.window else { return false }
        return view.bounds.contains(view.convert(w.mouseLocationOutsideOfEventStream, from: nil))
    }

    private func setChrome(visible: Bool) {
        guard visible != chromeVisible else { return }
        chromeVisible = visible
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = visible ? 0.18 : 0.45
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            for v in chromeViews { v.animator().alphaValue = visible ? 1 : 0 }
        }
        (view.window?.windowController as? MainWindowController)?.liveChromeChanged(visible: visible)
    }

    // MARK: Build

    private(set) var videoAspect: CGFloat = 16.0 / 9.0
    private let dimView = NSView()
    private var everShowedFrame = false

    private func buildVideo() {
        // 全出血：画面铺满整个内容区（含标题栏下方），由 AVSampleBufferDisplayLayer 的 resizeAspect 等比适配、黑边留白。
        // 不再用固定比例约束：横 / 竖 / 4:3 / 1:1 都由图层按真实显示尺寸自动处理，视图本身尺寸永远不变 → 重连不跳动。
        view.addSubview(videoView)
        UI.pin(videoView, to: view)
        // 恢复期间：保留最后一帧并压暗（不清空、不收缩）
        dimView.wantsLayer = true
        dimView.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.5).cgColor
        dimView.isHidden = true
        view.addSubview(dimView)
        UI.pin(dimView, to: view)
        videoView.onDrag = { [weak self] p in
            guard let self, self.model.settings.dragOnVideoControl else { return }
            if let p { let s = self.model.settings.gimbalSpeed * 1.5; self.drive(.drag, yaw: Double(p.x) * s, pitch: Double(p.y) * s) }
            else { self.release(.drag) }
        }
    }

    /// 记录解码显示尺寸（含像素宽高比 / clean aperture）；真实变化才记日志。供「窗口适配画面比例」使用。
    private func updateAspectIfNeeded(width: Int, height: Int) {
        guard width > 0, height > 0 else { return }
        let a = CGFloat(width) / CGFloat(height)
        if abs(a - videoAspect) / videoAspect > 0.01 || lastDims != (width, height) {
            if lastDims.0 != 0 || abs(a - videoAspect) / videoAspect > 0.01 {
                model.log(String(format: "画面尺寸 %d×%d（%@）", width, height, height > width ? "竖向" : "横向"))
            }
            videoAspect = a; lastDims = (width, height)
        }
    }
    private var lastDims = (0, 0)

    // MARK: 几何诊断（排查「画面放大缩小 / 窗口尺寸自己在变」）

    private var lastGeoLine: String?
    private var lastGeoLogAt: Double = 0
    /// 只在几何变化时记一行：窗口、内容视图、画面视图、显示图层、布局区、安全区、侧栏、全屏、渲染器。
    /// 用途：区分「窗口被改尺寸」「分栏被改尺寸」「画面视图/图层自己变了」「只是渲染器变了」。
    /// 图层另记「呈现值」：模型值不变但呈现值在动 = 有隐式动画在跑（视觉上就是画面在缩放）。
    private func logGeometryIfChanged(_ why: String) {
        guard let w = view.window else { return }
        let vf = videoView.frame
        let lb = videoView.displayLayer.bounds
        let pres = videoView.displayLayer.presentation().map { "\(Int($0.bounds.width))×\(Int($0.bounds.height))" } ?? "—"
        let v = view.bounds
        let ins = view.safeAreaInsets
        let side: String = {
            guard let c = w.windowController as? MainWindowController, let item = c.split.splitViewItems.first else { return "?" }
            return item.isCollapsed ? "收" : String(format: "%.0f", item.viewController.view.frame.width)
        }()
        let line = "窗口 \(Int(w.frame.width))×\(Int(w.frame.height))"
            + " · 视图 \(Int(v.width))×\(Int(v.height))"
            + " · 画面 \(Int(vf.width))×\(Int(vf.height))@\(Int(vf.minX)),\(Int(vf.minY))"
            + " · 图层 \(Int(lb.width))×\(Int(lb.height))@\(Int(lb.origin.x)),\(Int(lb.origin.y))"
            + " · 呈现 \(pres)"
            + " · 布局区 \(Int(w.contentLayoutRect.width))×\(Int(w.contentLayoutRect.height))"
            + " · 安全区 \(Int(ins.top))/\(Int(ins.bottom))"
            + " · 侧栏 \(side)"
            + " · 全屏 \(w.styleMask.contains(.fullScreen) ? 1 : 0)"
            + " · 解码 \(model.videoStats.width)×\(model.videoStats.height)"
            + " · 渲染器 \(videoView.rendererStatusText)"
        guard line != lastGeoLine else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastGeoLogAt >= 0.2 else { return }   // 变化密集时最多 5 Hz，避免日志被刷掉
        lastGeoLine = line
        lastGeoLogAt = now
        model.log("[几何/\(why)] \(line)")
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        logGeometryIfChanged("布局")
    }

    private func buildPlaceholder() {
        let icon = NSImageView(image: UI.symbol("camera.aperture", size: 56, weight: .thin) ?? NSImage())
        icon.contentTintColor = NSColor.white.withAlphaComponent(0.8)
        placeholderDetail.alignment = .center
        placeholderDetail.preferredMaxLayoutWidth = 380
        placeholder.setViews([icon, placeholderTitle, placeholderDetail, placeholderButton], in: .center)
        placeholder.orientation = .vertical
        placeholder.alignment = .centerX
        placeholder.spacing = 12
        placeholder.setCustomSpacing(20, after: placeholderDetail)
        placeholder.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(placeholder)
        NSLayoutConstraint.activate([
            placeholder.centerXAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerXAnchor),
            placeholder.centerYAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerYAnchor),
            placeholderDetail.widthAnchor.constraint(lessThanOrEqualToConstant: 380),
        ])
    }

    private func buildHUD() {
        let dot = NSImageView(image: UI.symbol("circle.fill", size: 9) ?? NSImage())
        dot.contentTintColor = .systemRed
        for l in [recBadge, modeLabel, localRecLabel, recoveryLabel, statsLabel] {
            l.lineBreakMode = .byTruncatingTail
            l.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            l.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        }
        // 顶部 / 底部渐变遮罩（全出血，压在标题栏区域下）
        view.addSubview(topScrim); view.addSubview(bottomScrim)
        NSLayoutConstraint.activate([
            topScrim.leadingAnchor.constraint(equalTo: view.leadingAnchor), topScrim.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            topScrim.topAnchor.constraint(equalTo: view.topAnchor), topScrim.heightAnchor.constraint(equalToConstant: 110),
            bottomScrim.leadingAnchor.constraint(equalTo: view.leadingAnchor), bottomScrim.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            bottomScrim.bottomAnchor.constraint(equalTo: view.bottomAnchor), bottomScrim.heightAnchor.constraint(equalToConstant: 120),
        ])
        for l in [recBadge, modeLabel, localRecLabel] { l.textColor = .white; l.shadow = Self.textShadow }
        let row = UI.hstack([dot, recBadge, modeLabel, localRecLabel], spacing: 8)
        // 同状态栏：顶部读数（待机 / REC 计时 / Mac 录制进度）只允许截断，不允许把宽度顶给分栏与窗口
        row.setClippingResistancePriority(.defaultHigh, for: .horizontal)
        row.appearance = NSAppearance(named: .darkAqua)
        hud = row
        view.addSubview(hud)
        statsLabel.lineBreakMode = .byClipping
        statsLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 520).isActive = true
        statsLabel.maximumNumberOfLines = 0
        statsPanel = HUDPanel(statsLabel, cornerRadius: 14, padding: 10)
        statsPanel.isHidden = true
        view.addSubview(statsPanel)
        recoveryLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        recoveryLabel.textColor = .white
        let spin = NSProgressIndicator(); spin.style = .spinning; spin.controlSize = .regular; spin.startAnimation(nil)
        let rs = UI.vstack([spin, recoveryLabel], spacing: 10, alignment: .centerX)
        recoveryPanel = HUDPanel(rs, cornerRadius: 20, padding: 18)
        recoveryPanel.isHidden = true
        view.addSubview(recoveryPanel)
        let g = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            recoveryPanel.centerXAnchor.constraint(equalTo: g.centerXAnchor),
            recoveryPanel.centerYAnchor.constraint(equalTo: g.centerYAnchor),
        ])
        NSLayoutConstraint.activate([
            hud.leadingAnchor.constraint(equalTo: g.leadingAnchor, constant: 16),
            hud.topAnchor.constraint(equalTo: g.topAnchor, constant: 12),
            hud.trailingAnchor.constraint(lessThanOrEqualTo: g.trailingAnchor, constant: -16),
            statsPanel.trailingAnchor.constraint(lessThanOrEqualTo: g.trailingAnchor, constant: -16),
            statsPanel.bottomAnchor.constraint(lessThanOrEqualTo: g.bottomAnchor, constant: -80),
            recoveryPanel.widthAnchor.constraint(lessThanOrEqualTo: g.widthAnchor, constant: -40),
            statsPanel.leadingAnchor.constraint(equalTo: g.leadingAnchor, constant: 16),
            statsPanel.topAnchor.constraint(equalTo: hud.bottomAnchor, constant: 10),
        ])
    }

    // 右侧竖向「相机侧栏」（单一 Liquid Glass 面板，垂直居中）：
    //   模式（4 个图标+短标签） → 快门 + 时长/模式 → 录制到 Mac · 截图 → 云台：回中 · 急停 · 云台菜单（模式/转速/速度/翻转）
    private static let railWidth: CGFloat = 60
    private static let smallButton: CGFloat = 26
    private var modeButtons: [NSButton] = []
    private var modeStack: NSStackView?
    private var modeSegments: [CameraMode] = Shutter.segments

    private func railButton(_ symbol: String, _ action: Selector, _ tip: String) -> NSButton {
        let b = NSButton(image: UI.symbol(symbol, size: 13, weight: .medium) ?? NSImage(), target: self, action: action)
        b.bezelStyle = .glass
        b.controlSize = .small
        b.imagePosition = .imageOnly
        b.toolTip = tip
        b.setAccessibilityLabel(tip)
        b.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([b.widthAnchor.constraint(equalToConstant: Self.smallButton),
                                     b.heightAnchor.constraint(equalToConstant: Self.smallButton)])
        return b
    }

    private func modeButton(_ m: CameraMode, index: Int) -> NSButton {
        let b = NSButton(title: m.shortName, image: UI.symbol(m.symbol, size: 13, weight: .medium) ?? NSImage(), target: self, action: #selector(modeButtonTapped(_:)))
        b.isBordered = false
        b.setButtonType(.momentaryChange)        // 点击不出现系统高亮 / 按下变暗
        (b.cell as? NSButtonCell)?.highlightsBy = []
        (b.cell as? NSButtonCell)?.showsStateBy = []
        b.focusRingType = .none
        b.imagePosition = .imageAbove
        b.font = .systemFont(ofSize: 9, weight: .medium)
        b.tag = index
        b.toolTip = "切换到「\(m.displayName)」(M 循环)"
        b.setAccessibilityLabel("模式：\(m.displayName)")
        b.wantsLayer = true
        b.layer?.cornerRadius = 8
        b.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([b.widthAnchor.constraint(equalToConstant: 48), b.heightAnchor.constraint(equalToConstant: 34)])
        return b
    }

    private func railSeparator() -> NSView {
        let v = NSBox(); v.boxType = .separator
        v.translatesAutoresizingMaskIntoConstraints = false
        v.widthAnchor.constraint(equalToConstant: 36).isActive = true
        return v
    }

    private func buildControls() {
        shutterButton.target = self
        shutterButton.action = #selector(shutterTapped)
        modeButtons = modeSegments.enumerated().map { modeButton($0.element, index: $0.offset) }
        shutterTimer.alignment = .center
        shutterTimer.font = .monospacedDigitSystemFont(ofSize: 10, weight: .semibold)
        shutterTimer.widthAnchor.constraint(equalToConstant: 52).isActive = true

        localRecButton = railButton("record.circle", #selector(localRecTapped), "录制到 Mac：把实时画面录成 Mac 上的视频文件（与相机 SD 卡录制无关，⌥⌘R）")
        snapshotButton = railButton("photo.on.rectangle", #selector(snapshotTapped), "截取当前画面到 Mac（⇧⌘S）")
    }

    private func buildGimbal() {
        joystick.onChange = { [weak self] p in
            guard let self else { return }
            let s = self.model.settings.gimbalSpeed / 0.3 * 0.6 // 摇杆满幅 ≈ 设定速度的 2 倍
            if p == .zero { self.release(.joystick) }
            else { self.drive(.joystick, yaw: Double(p.x) * min(1, s), pitch: Double(p.y) * min(1, s)) }
        }
        joystickPanel = HUDPanel(joystick, cornerRadius: 74, padding: 6)
        view.addSubview(joystickPanel)

        // 云台菜单：模式 / 转动速度（相机端）/ 手动速度（1–9）/ 翻转
        gimbalModeButton.pullsDown = true
        gimbalModeButton.bezelStyle = .glass
        gimbalModeButton.controlSize = .small
        gimbalModeButton.imagePosition = .imageOnly
        (gimbalModeButton.cell as? NSPopUpButtonCell)?.arrowPosition = .noArrow
        gimbalModeButton.translatesAutoresizingMaskIntoConstraints = false
        let gm = NSMenu()
        gm.delegate = self
        let h = NSMenuItem(title: "", action: nil, keyEquivalent: ""); h.image = UI.symbol("gyroscope", size: 13, weight: .medium); gm.addItem(h)
        gm.addItem(NSMenuItem.sectionHeader(title: "云台模式"))
        for m in [GimbalMode.follow, .directionLock, .fpv] {
            let it = NSMenuItem(title: m.displayName, action: #selector(gimbalModeSelected(_:)), keyEquivalent: "")
            it.target = self; it.tag = Int(m.rawValue); gm.addItem(it)
        }
        gm.addItem(.separator())
        gm.addItem(NSMenuItem.sectionHeader(title: "相机端转动速度"))
        for v in GimbalSpeedSetting.allCases {
            let it = NSMenuItem(title: v.displayName, action: #selector(gimbalSpeedSelected(_:)), keyEquivalent: "")
            it.target = self; it.tag = Int(v.rawValue); gm.addItem(it)
        }
        gm.addItem(.separator())
        gm.addItem(NSMenuItem.sectionHeader(title: "手动控制速度（数字键 1–9）"))
        for n in [1, 2, 3, 5, 7, 9] {
            let it = NSMenuItem(title: String(format: "%.1f", Double(n) / 10), action: #selector(manualSpeedSelected(_:)), keyEquivalent: "")
            it.target = self; it.tag = 100 + n; gm.addItem(it)
        }
        gm.addItem(.separator())
        let flip = NSMenuItem(title: "前 / 后镜头翻转（自拍）", action: #selector(flipTapped), keyEquivalent: "")
        flip.target = self; gm.addItem(flip)
        gimbalModeButton.menu = gm
        NSLayoutConstraint.activate([gimbalModeButton.widthAnchor.constraint(equalToConstant: 56),
                                     gimbalModeButton.heightAnchor.constraint(equalToConstant: Self.smallButton)])

        let recenter = railButton("scope", #selector(recenterTapped), "云台回中：镜头回到正前方（C / ⌘0）")
        let stop = railButton("hand.raised.fill", #selector(stopGimbalTapped), "紧急停止云台（Esc / . / ⌘.）：正常松手会自动停止，仅在异常仍在转动时使用")

        // 组装右侧栏
        let modes = UI.vstack(modeButtons, spacing: 2, alignment: .centerX)
        modeStack = modes
        let shutterCol = UI.vstack([shutterButton, shutterTimer], spacing: 3, alignment: .centerX)
        let macRow = UI.hstack([localRecButton, snapshotButton], spacing: 4)
        let gimbalTitle = UI.label("云台", size: 9, weight: .semibold, color: NSColor.white.withAlphaComponent(0.6))
        let gRow = UI.hstack([recenter, stop], spacing: 4)
        let rail = UI.vstack([modes, railSeparator(), shutterCol, macRow, railSeparator(), gimbalTitle, gRow, gimbalModeButton], spacing: 8, alignment: .centerX)
        rail.widthAnchor.constraint(equalToConstant: Self.railWidth).isActive = true
        controlsPanel = HUDPanel(rail, cornerRadius: 22, padding: 6)
        view.addSubview(controlsPanel)
    }

    private func buildStatusBar() {
        view.addSubview(statusBar)
        statusBar.appearance = NSAppearance(named: .darkAqua)
        let g = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            statusBar.leadingAnchor.constraint(equalTo: g.leadingAnchor, constant: 12),
            statusBar.trailingAnchor.constraint(equalTo: g.trailingAnchor, constant: -12),
            statusBar.bottomAnchor.constraint(equalTo: g.bottomAnchor, constant: -10),
            joystickPanel.leadingAnchor.constraint(equalTo: g.leadingAnchor, constant: 18),
            joystickPanel.bottomAnchor.constraint(equalTo: statusBar.topAnchor, constant: -14),
            controlsPanel.trailingAnchor.constraint(equalTo: g.trailingAnchor, constant: -14),
            { let c = controlsPanel.centerYAnchor.constraint(equalTo: g.centerYAnchor, constant: -16); c.priority = .defaultHigh; return c }(),
            controlsPanel.topAnchor.constraint(greaterThanOrEqualTo: g.topAnchor, constant: 12),
            controlsPanel.bottomAnchor.constraint(lessThanOrEqualTo: statusBar.topAnchor, constant: -12),
        ])
    }

    // MARK: Refresh

    private func refresh() {
        let connected = model.isConnected
        if connected && model.videoStats.frames > 0 { everShowedFrame = true }
        if !connected { everShowedFrame = false }
        updateAspectIfNeeded(width: model.videoStats.width, height: model.videoStats.height)
        let hasVideo = connected && (model.videoStats.frames > 0 || everShowedFrame)
        placeholder.isHidden = hasVideo
        dimView.isHidden = !(connected && everShowedFrame && (model.videoRecoveryMessage != nil || model.videoStats.frames == 0))
        switch model.phase {
        case .idle: placeholderTitle.stringValue = "未连接相机"; placeholderButton.isHidden = false; placeholderButton.title = "连接相机"
        case .connecting:
            placeholderTitle.stringValue = "正在连接…"
            placeholderDetail.stringValue = model.steps.first { $0.status == .active }.map { "\($0.title)：\($0.detail)" } ?? ""
            placeholderButton.isHidden = true
        case .connected:
            placeholderTitle.stringValue = "已连接，等待画面…"
            placeholderDetail.stringValue = "若长时间无画面，App 会自动恢复；也可点击工具栏「刷新视频」（重建连接）。"
            placeholderButton.isHidden = true
        case let .failed(msg):
            placeholderTitle.stringValue = "连接失败"
            placeholderDetail.stringValue = msg
            placeholderButton.isHidden = false; placeholderButton.title = "重试"
        }
        if case .idle = model.phase {
            let who = model.deviceProfile.isPocketSeries ? model.deviceProfile.displayName : "Osmo Pocket"
            placeholderDetail.stringValue = "点击「连接」开始：App 会通过蓝牙唤醒 \(who) 的 Wi-Fi，再接收实时画面。首次使用请先完成新手引导。"
        }

        let cam = model.snapshot.camera
        let ov = overlaysVisible && connected
        hud.isHidden = !ov
        controlsPanel.isHidden = !ov
        joystickPanel.isHidden = !ov
        statsPanel.isHidden = statsPanel.isHidden || !connected
        recoveryPanel.isHidden = !(connected && model.videoRecoveryMessage != nil)
        recoveryLabel.stringValue = model.videoRecoveryMessage ?? ""

        recBadge.stringValue = cam.recording ? String(format: "REC %02d:%02d", cam.recordingTimeS / 60, cam.recordingTimeS % 60) : "待机"
        (hud as? NSStackView)?.views.first?.isHidden = !cam.recording
        modeLabel.stringValue = cam.hasCameraStatus ? "· \(cam.modeName)" : ""
        if let info = model.localRecordingInfo {
            let (start, bytes) = info
            let t = Int(Date().timeIntervalSince(start))
            localRecLabel.stringValue = String(format: "· Mac 录制 %02d:%02d  %.1f MB", t / 60, t % 60, Double(bytes) / 1_048_576)
        } else { localRecLabel.stringValue = "" }

        let shownMode = model.displayedMode ?? (cam.hasCameraStatus ? cam.mode : nil)
        shutterButton.style = Shutter.style(mode: shownMode, recording: cam.recording)
        shutterButton.toolTip = Shutter.tooltip(mode: shownMode, recording: cam.recording)
        shutterButton.isEnabled = connected && model.link != nil
        shutterTimer.stringValue = cam.recording ? String(format: "%02d:%02d", cam.recordingTimeS / 60, cam.recordingTimeS % 60) : (shownMode?.displayName ?? "—")
        shutterTimer.textColor = cam.recording ? .systemRed : NSColor.white.withAlphaComponent(0.8)
        syncModeButtons()
        let modeEnabled = connected && !cam.recording && model.link != nil
        for (i, b) in modeButtons.enumerated() {
            guard modeSegments.indices.contains(i) else { continue }
            let sel = modeSegments[i] == shownMode
            b.isEnabled = modeEnabled
            // 选中 = 黄色图标 + 文字（iOS 相机风格），无背景胶囊；未选中白色
            let fg = sel ? NSColor.systemYellow : NSColor.white.withAlphaComponent(modeEnabled ? 0.85 : 0.38)
            b.contentTintColor = fg
            b.attributedTitle = NSAttributedString(string: modeSegments[i].shortName, attributes: [
                .font: NSFont.systemFont(ofSize: 9.5, weight: sel ? .bold : .medium), .foregroundColor: fg])
            b.attributedAlternateTitle = b.attributedTitle
            b.layer?.backgroundColor = nil
        }
        localRecButton.contentTintColor = model.isLocalRecording ? .systemRed : nil
        localRecButton.image = UI.symbol(model.isLocalRecording ? "stop.circle.fill" : "record.circle", size: 13, weight: .medium)
        gimbalModeButton.toolTip = String(format: "云台菜单：模式 / 转速 / 手动速度（当前 %.1f）/ 翻转", model.settings.gimbalSpeed)

        let s = model.snapshot.stats, v = model.videoStats
        statsLabel.stringValue = """
        UDP 收 \(s.rxPackets) / 发 \(s.txPackets)
        视频包 \(s.videoFrames)  DUML \(s.dumlPackets)
        解码 \(v.frames) 帧  \(v.fps) fps  \(v.kbps) kbps
        分辨率 \(v.width)×\(v.height)  累计 \(String(format: "%.1f", Double(v.bytes) / 1_048_576)) MB
        \(model.snapshot.gimbal.description)
        \(cam.summary)
        """
        statusBar.update(model: model)
        logGeometryIfChanged("刷新")
    }

    // MARK: Keyboard / trackpad

    override func viewDidAppear() {
        super.viewDidAppear()
        installMonitor()
        installStopHooks()
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
        stopAllGimbalInput()
        keepAlive?.invalidate(); keepAlive = nil
        // 停止钩子绑定窗口 / 激活状态，随本次消失一并移除；否则每次回到本页都会再装 6 个，
        // 侧栏来回切换后同一事件会触发 N 次 stopAllGimbalInput。
        for o in stopObservers { NotificationCenter.default.removeObserver(o) }
        stopObservers.removeAll()
    }

    // MARK: Gimbal input（统一入口：任何输入源结束都发可靠停止）

    private func drive(_ src: GimbalSource, yaw: Double, pitch: Double) {
        guard model.isConnected else { return }
        if yaw == 0 && pitch == 0 { release(src); return }
        gimbalSource = src
        gimbalInput = (yaw, pitch)
        model.setGimbal(yaw: yaw, pitch: pitch)
    }

    private func release(_ src: GimbalSource) {
        guard gimbalSource == src || gimbalSource == .none else { return }
        gimbalSource = .none
        gimbalInput = (0, 0)
        model.stopGimbal()   // 协议层会在 ~100ms 内连发 4 次零速
    }

    /// 停止一切：按键、摇杆、拖动、滚动
    func stopAllGimbalInput() {
        held = []
        scrollStopWork?.cancel(); scrollStopWork = nil
        joystick.reset()
        videoView.cancelDrag()
        gimbalSource = .none
        gimbalInput = (0, 0)
        model.stopGimbal()
    }

    private func installStopHooks() {
        guard keepAlive == nil else { return }
        let nc = NotificationCenter.default
        let stop: @Sendable (Notification) -> Void = { [weak self] _ in MainActor.assumeIsolated { self?.stopAllGimbalInput() } }
        for name in [NSApplication.willResignActiveNotification, NSApplication.didResignActiveNotification, NSApplication.willHideNotification] {
            stopObservers.append(nc.addObserver(forName: name, object: nil, queue: .main, using: stop))
        }
        if let w = view.window {
            for name in [NSWindow.didResignKeyNotification, NSWindow.didMiniaturizeNotification, NSWindow.willCloseNotification] {
                stopObservers.append(nc.addObserver(forName: name, object: w, queue: .main, using: stop))
            }
        }
        keepAlive = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.keepAliveTick() }
        }
    }

    /// 每 100ms：仍按住时刷新速度（喂看门狗）；检测丢失的 mouseUp / keyUp
    private func keepAliveTick() {
        guard gimbalSource != .none else { return }
        let mouseDown = NSEvent.pressedMouseButtons & 1 != 0
        let focused = view.window?.isKeyWindow == true && NSApp.isActive
        switch gimbalSource {
        case .joystick, .drag:
            if !mouseDown || !focused { stopAllGimbalInput(); return }
        case .keys:
            if !focused || held.isEmpty { stopAllGimbalInput(); return }
        case .scroll, .none:
            return   // 滚动事件本身就是连续刷新；停止由 phase 结束 / 150ms 空闲 / 协议看门狗负责
        }
        model.setGimbal(yaw: gimbalInput.yaw, pitch: gimbalInput.pitch)
    }

    private func installMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .scrollWheel]) { [weak self] e in
            guard let self else { return e }
            return self.handle(e) ? nil : e
        }
    }

    private func handle(_ e: NSEvent) -> Bool {
        guard let w = view.window, e.window === w, w.isKeyWindow, view.superview != nil else { return false }
        if w.firstResponder is NSText { return false } // 正在输入文字
        if e.type == .scrollWheel { return handleScroll(e) }
        if !e.modifierFlags.intersection([.command, .control, .option]).isEmpty { return false }
        let key = keyName(e)
        guard let key else { return false }
        let isDown = e.type == .keyDown
        let movement: Set<String> = ["up", "down", "left", "right", "slowL", "slowR", "slowU", "slowD"]
        if movement.contains(key) {
            if isDown { held.insert(key) } else { held.remove(key) }
            applyHeld()
            return true
        }
        guard isDown, !e.isARepeat else { return isDown }
        pokeChrome()
        switch key {
        case "space", "return": model.shutter()
        case "escape", ".": stopAllGimbalInput()
        case "p": model.takePhoto()
        case "o": model.toggleCameraRecording()
        case "m": model.cycleMode()
        case "v": toggleVideo()
        case "i": statsPanel.isHidden.toggle(); refresh()
        case "c": stopAllGimbalInput(); model.recenterGimbal()
        default:
            if let n = Int(key), (1 ... 9).contains(n) {
                model.settings.gimbalSpeed = Double(n) / 10
                applyHeld()
            } else { return false }
        }
        return true
    }

    private func keyName(_ e: NSEvent) -> String? {
        switch e.keyCode {
        case 126: return "up"
        case 125: return "down"
        case 123: return "left"
        case 124: return "right"
        case 49: return "space"
        case 36, 76: return "return"
        case 53: return "escape"
        default: break
        }
        guard let c = e.charactersIgnoringModifiers?.lowercased(), c.count == 1 else { return nil }
        switch c {
        case "w": return "up"
        case "s": return "down"
        case "a": return "left"
        case "d": return "right"
        case "q": return "slowL"
        case "e": return "slowR"
        case "r": return "slowU"
        case "f": return "slowD"
        case "p", "o", "m", "v", "i", "c", ".": return c
        case "1", "2", "3", "4", "5", "6", "7", "8", "9": return c
        default: return nil
        }
    }

    private func applyHeld() {
        guard model.isConnected else { return }
        let sp = model.settings.gimbalSpeed
        func v(_ k: String) -> Double { held.contains(k) ? 1 : 0 }
        let yaw = (v("right") - v("left")) * sp + (v("slowR") - v("slowL")) * sp * 0.3
        let pitch = (v("up") - v("down")) * sp + (v("slowU") - v("slowD")) * sp * 0.3
        if yaw == 0 && pitch == 0 { release(.keys) } else { drive(.keys, yaw: yaw, pitch: pitch) }
    }

    private func handleScroll(_ e: NSEvent) -> Bool {
        guard model.isConnected, model.settings.trackpadScrollControl else { return false }
        let p = view.convert(e.locationInWindow, from: nil)
        guard view.bounds.contains(p) else { return false }
        // 手势结束 / 惯性滚动结束 / 被取消 → 立即停止（惯性阶段不驱动云台，避免松手后继续转）
        if e.phase.contains(.ended) || e.phase.contains(.cancelled) || e.momentumPhase.contains(.ended) || e.momentumPhase.contains(.cancelled) {
            scrollStopWork?.cancel(); scrollStopWork = nil
            release(.scroll); return true
        }
        if !e.momentumPhase.isEmpty { return true }
        let k: CGFloat = e.hasPreciseScrollingDeltas ? 18 : 2
        let sp = model.settings.gimbalSpeed * 2
        let yaw = Double(max(-1, min(1, -e.scrollingDeltaX / k))) * sp
        let pitch = Double(max(-1, min(1, e.scrollingDeltaY / k))) * sp
        if yaw == 0 && pitch == 0 { return true }
        drive(.scroll, yaw: yaw, pitch: pitch)
        scrollStopWork?.cancel()
        let w = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.release(.scroll) } }
        scrollStopWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: w)
        return true
    }

    // MARK: Actions

    func toggleOverlays() { overlaysVisible.toggle(); model.log("悬浮控件：\(overlaysVisible ? "显示" : "隐藏")"); refresh() }
    var areOverlaysVisible: Bool { overlaysVisible }
    func toggleVideo() { videoHidden.toggle(); videoView.isHidden = videoHidden; model.log(videoHidden ? "画面已隐藏 (V)" : "画面已显示 (V)") }

    @objc private func connectTapped() { model.connect() }
    @objc private func shutterTapped() { model.shutter() }
    @objc private func manualSpeedSelected(_ s: NSMenuItem) { model.settings.gimbalSpeed = Double(s.tag - 100) / 10; refresh() }
    private func syncModeButtons() {
        let segs = Shutter.segments(for: model.deviceProfile)
        guard segs != modeSegments, let modeStack else { return }
        modeSegments = segs
        for b in modeButtons { modeStack.removeArrangedSubview(b); b.removeFromSuperview() }
        modeButtons = segs.enumerated().map { modeButton($0.element, index: $0.offset) }
        for b in modeButtons { modeStack.addArrangedSubview(b) }
    }

    @objc private func modeButtonTapped(_ b: NSButton) {
        let i = b.tag
        guard modeSegments.indices.contains(i) else { return }
        model.setMode(modeSegments[i])
        refresh()
    }
    @objc private func localRecTapped() { model.toggleLocalRecording() }
    @objc private func snapshotTapped() { model.saveSnapshot() }
    @objc private func gimbalModeSelected(_ s: NSMenuItem) { if let m = GimbalMode(rawValue: UInt8(s.tag)) { model.setGimbalMode(m) } }
    @objc private func recenterTapped() { stopAllGimbalInput(); model.recenterGimbal() }
    @objc private func flipTapped() { stopAllGimbalInput(); model.flipGimbal() }
    @objc private func gimbalSpeedSelected(_ s: NSMenuItem) { if let v = GimbalSpeedSetting(rawValue: UInt8(s.tag)) { model.setGimbalSpeedSetting(v) } }
    @objc private func stopGimbalTapped() { stopAllGimbalInput(); model.log("已发送云台停止（零速 ×4）") }
}

/// 底部 Liquid Glass 状态栏
@MainActor
final class StatusBarView: NSView {
    private let conn = StatusItem(symbol: "circle.fill")
    private let battery = StatusItem(symbol: "battery.75percent")
    private let sd = StatusItem(symbol: "sdcard")
    private let mode = StatusItem(symbol: "camera")
    private let rec = StatusItem(symbol: "record.circle")
    private let gimbal = StatusItem(symbol: "move.3d")
    private let video = StatusItem(symbol: "waveform.path.ecg")

    override init(frame: NSRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        let spacer = NSView(); spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let row = UI.hstack([conn, battery, sd, mode, rec, spacer, gimbal, video], spacing: 14)
        // 状态栏的内容宽度**绝不能**变成「内容区 / 窗口」的最小宽度：
        //   NSStackView 默认 clipping resistance = required，会让「文字排满的自然宽度」一路顶到分栏与窗口，
        //   读数一变宽（云台角度正负号 / 位数、fps / kbps 位数…）窗口与分栏就跟着变 → 画面缩放抖动。
        //   这里：栈视图 defaultHigh + 文字 defaultLow = 空间不够时先把文字截断成「…」，几何保持不变。
        row.setClippingResistancePriority(.defaultHigh, for: .horizontal)
        // 置于底部渐变遮罩上，不再单独加玻璃底板
        row.shadow = LiveViewController.textShadow
        addSubview(row)
        UI.pin(row, to: self, inset: 4)
    }
    required init?(coder: NSCoder) { fatalError() }

    func update(model: AppModel) {
        let c = model.snapshot.camera
        switch model.phase {
        case .idle: conn.set("未连接", tint: .secondaryLabelColor)
        case .connecting: conn.set("连接中…", tint: .systemOrange)
        case .connected: conn.set(String(format: "已连接 · 0x%04X", model.snapshot.sessionID), tint: .systemGreen)
        case .failed: conn.set("连接失败", tint: .systemRed)
        }
        let pct = c.batteryPercent >= 0 ? c.batteryPercent : (model.bleBattery ?? -1)
        if pct >= 0 {
            let sym = pct > 87 ? "battery.100percent" : pct > 62 ? "battery.75percent" : pct > 37 ? "battery.50percent" : pct > 12 ? "battery.25percent" : "battery.0percent"
            battery.setSymbol(sym)
            battery.set(c.batteryMilliVolt > 0 ? "\(pct)% · \(String(format: "%.2f", Double(c.batteryMilliVolt) / 1000)) V" : "\(pct)%", tint: pct <= 15 ? .systemRed : .labelColor)
        } else { battery.set("电量 —", tint: .secondaryLabelColor) }
        if !model.deviceProfile.parsesSDCapacity {
            sd.set("机内存储", tint: .secondaryLabelColor)
        } else {
            let known = c.hasStorageStatus || c.hasCameraStatus
            sd.set(known ? (c.sdInserted ? String(format: "SD 剩余 %.1f GB", Double(c.sdFreeMB) / 1024) : "无 SD 卡") : "SD —",
                   tint: known && !c.sdInserted ? .systemOrange : .labelColor)
        }
        mode.setSymbol(c.mode?.symbol ?? "camera")
        mode.set(c.hasCameraStatus ? c.modeName : "模式 —", tint: .labelColor)
        rec.set(c.recording ? String(format: "录制中 %02d:%02d", c.recordingTimeS / 60, c.recordingTimeS % 60) : "未录制", tint: c.recording ? .systemRed : .secondaryLabelColor)
        let gs = model.snapshot.gimbal
        if model.isConnected && !model.snapshot.gimbalReady {
            gimbal.set("云台准备中…", tint: .systemOrange)
        } else {
            let m = gs.mode.map { " · \($0.displayName)" } ?? ""
            gimbal.set(gs.valid ? String(format: "航向 %.1f°  俯仰 %.1f°", gs.yaw, gs.pitch) + m : "云台 —", tint: .labelColor)
        }
        let v = model.videoStats
        video.set(model.isConnected ? "\(v.fps) fps · \(v.kbps) kbps" : "视频 —", tint: .labelColor)
    }
}

@MainActor
final class StatusItem: NSStackView {
    private let icon = NSImageView()
    private let text = UI.label("", size: 12, weight: .medium, mono: false)
    init(symbol: String) {
        super.init(frame: .zero)
        orientation = .horizontal; spacing = 5
        translatesAutoresizingMaskIntoConstraints = false
        setSymbol(symbol)
        addArrangedSubview(icon); addArrangedSubview(text)
        text.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        // 同 StatusBarView：读数只允许被截断（显示「…」），不允许把宽度要求传给上层布局
        setClippingResistancePriority(.defaultHigh, for: .horizontal)
        text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }
    required init?(coder: NSCoder) { fatalError() }
    func setSymbol(_ s: String) { icon.image = UI.symbol(s, size: 12) }
    func set(_ s: String, tint: NSColor) { text.stringValue = s; text.textColor = tint == .secondaryLabelColor ? tint : .labelColor; icon.contentTintColor = tint }
}


extension LiveViewController: NSMenuDelegate {
    /// 打开云台菜单时勾选当前模式（来自 Gimbal:0x05 @6）
    func menuNeedsUpdate(_ menu: NSMenu) {
        let cur = model.snapshot.gimbal.mode
        for it in menu.items where it.action == #selector(gimbalModeSelected(_:)) {
            it.state = cur?.rawValue == UInt8(it.tag) ? .on : .off
        }
        let sp = Int((model.settings.gimbalSpeed * 10).rounded())
        for it in menu.items where it.action == #selector(manualSpeedSelected(_:)) { it.state = it.tag - 100 == sp ? .on : .off }
    }
}
