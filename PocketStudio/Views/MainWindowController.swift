// MainWindowController.swift — 主窗口：NSSplitViewController（侧边栏 + 内容）+ NSToolbar

import AppKit

@MainActor
enum Section: Int, CaseIterable {
    case live, connect, status, debug, help
    var title: String { ["实时取景", "连接", "设备状态", "调试", "帮助"][rawValue] }
    var symbol: String { ["video.fill", "bolt.horizontal.circle", "gauge.with.dots.needle.50percent", "ladybug", "questionmark.circle"][rawValue] }
}

@MainActor
final class MainWindowController: NSWindowController, NSToolbarDelegate, NSWindowDelegate {
    let split = NSSplitViewController()
    let sidebar = SidebarViewController()
    let content = ContentContainerViewController()
    private let model = AppModel.shared
    private var observer: NSObjectProtocol?

    private enum TB {
        static let connect = NSToolbarItem.Identifier("connect")
        static let refresh = NSToolbarItem.Identifier("refresh")
        static let photo = NSToolbarItem.Identifier("photo")
        static let localRec = NSToolbarItem.Identifier("localRec")
        static let snapshot = NSToolbarItem.Identifier("snapshot")
        static let overlay = NSToolbarItem.Identifier("overlay")
        static let reveal = NSToolbarItem.Identifier("reveal")
    }
    private var items: [NSToolbarItem.Identifier: NSToolbarItem] = [:]

    init() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 760),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                         backing: .buffered, defer: false)
        w.title = "PocketStudio"
        w.minSize = NSSize(width: 820, height: 540)
        w.toolbarStyle = .unified
        w.titlebarSeparatorStyle = .automatic
        w.setFrameAutosaveName("MainWindow")
        super.init(window: w)
        w.delegate = self

        let sideItem = NSSplitViewItem(sidebarWithViewController: sidebar)
        sideItem.minimumThickness = 190
        sideItem.maximumThickness = 280
        sideItem.canCollapse = true
        let contentItem = NSSplitViewItem(viewController: content)
        split.addSplitViewItem(sideItem)
        split.addSplitViewItem(contentItem)
        w.contentViewController = split
        w.setContentSize(NSSize(width: 1180, height: 760))
        if w.frame.origin == .zero { w.center() }

        let tb = NSToolbar(identifier: "MainToolbar")
        tb.delegate = self
        tb.displayMode = .iconOnly
        tb.allowsUserCustomization = true
        tb.autosavesConfiguration = true
        w.toolbar = tb

        sidebar.onSelect = { [weak self] s in self?.content.show(s); self?.updateToolbar() }
        select(.live)
        observer = NotificationCenter.default.addObserver(forName: .modelChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateToolbar() }
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    func select(_ s: Section) { sidebar.select(s); content.show(s); updateToolbar() }

    // MARK: Toolbar

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.toggleSidebar, .sidebarTrackingSeparator, TB.connect, .flexibleSpace, TB.localRec, TB.snapshot, TB.reveal, .space, TB.refresh, TB.overlay]
    }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar) + [.space, .flexibleSpace]
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        let it = NSToolbarItem(itemIdentifier: id)
        it.target = self
        it.isBordered = true
        it.autovalidates = false
        func cfg(_ label: String, _ sym: String, _ sel: Selector, _ tip: String) {
            it.label = label; it.paletteLabel = label; it.toolTip = tip
            it.image = NSImage(systemSymbolName: sym, accessibilityDescription: label)
            it.action = sel
            it.target = self
        }
        switch id {
        case TB.connect: cfg("连接", "bolt.horizontal.circle", #selector(connectToggle), "连接 / 断开相机 (⌘K)")
        case TB.refresh: cfg("刷新视频", "arrow.clockwise", #selector(refreshVideo), "彻底重建连接以恢复视频 (⌘R)")
        case TB.photo: cfg("拍照", "camera", #selector(photo), "拍照 (P)")
        case TB.localRec: cfg("录制到 Mac", "square.and.arrow.down.on.square", #selector(localRec), "将视频流录制到 Mac (⌥⌘R)")
        case TB.snapshot: cfg("截图", "photo.on.rectangle", #selector(snapshot), "保存当前画面 (⇧⌘S)")
        case TB.overlay: cfg("悬浮控件", "rectangle.on.rectangle", #selector(toggleOverlay), "显示 / 隐藏画面上的控件")
        case TB.reveal: cfg("查看文件", "folder", #selector(reveal), "在访达中显示最近的录制 / 截图")
        default: return nil
        }
        items[id] = it
        return it
    }

    func updateToolbar() {
        let connected = model.isConnected, busy = model.isBusy
        if let c = items[TB.connect] {
            c.label = connected ? "断开" : busy ? "取消" : "连接"
            c.image = NSImage(systemSymbolName: connected ? "xmark.circle" : busy ? "stop.circle" : "bolt.horizontal.circle", accessibilityDescription: c.label)
        }
        items[TB.refresh]?.isEnabled = connected
        items[TB.photo]?.isEnabled = connected
        items[TB.snapshot]?.isEnabled = connected
        items[TB.localRec]?.isEnabled = connected
        items[TB.localRec]?.image = NSImage(systemSymbolName: model.isLocalRecording ? "stop.circle.fill" : "square.and.arrow.down.on.square", accessibilityDescription: nil)
        items[TB.localRec]?.label = model.isLocalRecording ? "停止录制" : "录制到 Mac"
        items[TB.overlay]?.isEnabled = content.current == .live
    }

    @objc func connectToggle() {
        if model.isConnected { model.disconnect() }
        else if model.isBusy { model.cancelConnect() }
        else { model.connect(); if content.current != .live { select(.connect) } }
    }
    @objc func refreshVideo() { model.refreshVideo() }
    @objc func photo() { model.takePhoto() }
    @objc func localRec() { model.toggleLocalRecording() }
    @objc func snapshot() { model.saveSnapshot() }
    @objc func reveal() { model.revealLastFile() }
    @objc func toggleOverlay() { content.live.toggleOverlays() }

    func windowWillClose(_ notification: Notification) { model.stopGimbal() }

    // MARK: 沉浸式 / 全屏

    private(set) var immersive = false
    private var sidebarWasCollapsed = false
    private var isFullScreen: Bool { window?.styleMask.contains(.fullScreen) == true }
    private var sidebarItem: NSSplitViewItem? { split.splitViewItems.first }

    /// 沉浸模式（⌃⌘I）：收起侧边栏、隐藏工具栏与标题，画面全出血；控件随鼠标淡入淡出
    @objc func toggleImmersive(_ sender: Any?) {
        immersive.toggle()
        if immersive { select(.live) }
        sidebarItem?.animator().isCollapsed = immersive
        window?.toolbar?.isVisible = !immersive
        window?.titleVisibility = immersive ? .hidden : .visible
        window?.titlebarAppearsTransparent = immersive
        content.live.pokeChrome()
    }

    /// 控件层淡入淡出时，沉浸 / 全屏下同步淡化窗口红绿灯
    func liveChromeChanged(visible: Bool) {
        guard immersive || isFullScreen else { setTrafficLights(alpha: 1); return }
        setTrafficLights(alpha: visible ? 1 : 0)
    }
    private func setTrafficLights(alpha: CGFloat) {
        guard let container = window?.standardWindowButton(.closeButton)?.superview else { return }
        NSAnimationContext.runAnimationGroup { ctx in ctx.duration = 0.3; container.animator().alphaValue = alpha }
    }

    func window(_ window: NSWindow, willUseFullScreenPresentationOptions proposedOptions: NSApplication.PresentationOptions = []) -> NSApplication.PresentationOptions {
        proposedOptions.union([.fullScreen, .autoHideToolbar, .autoHideMenuBar])
    }
    func windowWillEnterFullScreen(_ notification: Notification) {
        sidebarWasCollapsed = sidebarItem?.isCollapsed ?? false
        sidebarItem?.isCollapsed = true
        select(.live)
    }
    func windowDidExitFullScreen(_ notification: Notification) {
        if !immersive { sidebarItem?.isCollapsed = sidebarWasCollapsed }
        setTrafficLights(alpha: 1)
    }

    /// 「窗口适配画面比例」（⌥⌘0）：按解码显示尺寸调整窗口高度，使画面无黑边（含竖拍）
    @objc func fitWindowToVideo(_ sender: Any?) {
        guard let w = window, !isFullScreen else { return }
        let st = model.videoStats
        guard st.width > 0, st.height > 0 else { model.log("尚无画面尺寸，连接并出画面后再试"); return }
        let aspect = CGFloat(st.width) / CGFloat(st.height)
        let live = content.live.view.bounds
        guard live.width > 0, live.height > 0 else { return }
        var f = w.frame
        let vis = w.screen?.visibleFrame ?? f
        var targetH = live.width / aspect
        var dw: CGFloat = 0
        // 竖拍或太高：改为按高度适配宽度
        if f.height + (targetH - live.height) > vis.height {
            let maxLiveH = live.height + (vis.height - f.height)
            targetH = maxLiveH
            dw = maxLiveH * aspect - live.width
        }
        let dh = targetH - live.height
        f.size.height += dh; f.origin.y -= dh
        f.size.width += dw
        f = f.intersection(vis).isEmpty ? f : NSRect(x: max(vis.minX, min(f.minX, vis.maxX - f.width)), y: max(vis.minY, f.minY), width: min(f.width, vis.width), height: min(f.height, vis.height))
        w.setFrame(f, display: true, animate: true)
        model.log(String(format: "窗口已适配画面 %d×%d", st.width, st.height))
    }

}

/// 侧边栏（source list 风格表格）
@MainActor
final class SidebarViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    var onSelect: ((Section) -> Void)?
    private let table = NSTableView()
    private var suppress = false

    override func loadView() {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = false
        table.style = .sourceList
        table.headerView = nil
        table.rowSizeStyle = .default
        table.backgroundColor = .clear
        let col = NSTableColumn(identifier: .init("main"))
        table.addTableColumn(col)
        table.dataSource = self
        table.delegate = self
        table.setAccessibilityLabel("导航")
        scroll.documentView = table
        view = scroll
    }

    func select(_ s: Section) {
        suppress = true
        table.selectRowIndexes(IndexSet(integer: s.rawValue), byExtendingSelection: false)
        suppress = false
    }

    func numberOfRows(in tableView: NSTableView) -> Int { Section.allCases.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let s = Section(rawValue: row)!
        let cell = NSTableCellView()
        let iv = NSImageView(image: NSImage(systemSymbolName: s.symbol, accessibilityDescription: nil) ?? NSImage())
        let tf = NSTextField(labelWithString: s.title)
        iv.translatesAutoresizingMaskIntoConstraints = false
        tf.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(iv); cell.addSubview(tf)
        cell.imageView = iv; cell.textField = tf
        NSLayoutConstraint.activate([
            iv.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            iv.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            iv.widthAnchor.constraint(equalToConstant: 18),
            tf.leadingAnchor.constraint(equalTo: iv.trailingAnchor, constant: 8),
            tf.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -4),
            tf.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !suppress, let s = Section(rawValue: table.selectedRow) else { return }
        onSelect?(s)
    }
}

/// 内容区：按侧边栏选择切换子控制器
@MainActor
final class ContentContainerViewController: NSViewController {
    let live = LiveViewController()
    let connect = ConnectViewController()
    let status = StatusViewController()
    let debug = DebugViewController()
    let help = HelpViewController()
    private(set) var current: Section?

    override func loadView() { view = NSView() }

    func show(_ s: Section) {
        guard s != current else { return }
        let vc: NSViewController = [live, connect, status, debug, help][s.rawValue]
        children.forEach { $0.view.removeFromSuperview(); $0.removeFromParent() }
        addChild(vc)
        view.addSubview(vc.view)
        UI.pin(vc.view, to: view)
        current = s
    }
}
