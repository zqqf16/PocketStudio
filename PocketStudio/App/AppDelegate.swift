// AppDelegate.swift — 应用入口、主菜单、窗口管理

import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    private var main: MainWindowController?
    private var settingsWC: SettingsWindowController?
    private var onboardingWC: OnboardingWindowController?
    private let model = AppModel.shared

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = buildMenu()
        let m = MainWindowController()
        main = m
        m.showWindow(nil)
        NSApp.activate()
        if !model.settings.hasCompletedOnboarding { showOnboarding(nil) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) { model.disconnect() }

    // MARK: Menu

    private func buildMenu() -> NSMenu {
        let bar = NSMenu()
        func add(_ title: String, _ items: [NSMenuItem]) -> NSMenu {
            let top = NSMenuItem(); let m = NSMenu(title: title)
            items.forEach { m.addItem($0) }
            top.submenu = m; bar.addItem(top); return m
        }
        func item(_ t: String, _ a: Selector?, _ k: String = "", _ mods: NSEvent.ModifierFlags = [.command], symbol: String? = nil) -> NSMenuItem {
            let i = NSMenuItem(title: t, action: a, keyEquivalent: k)
            i.keyEquivalentModifierMask = mods
            if let symbol { i.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
            return i
        }
        let appName = "PocketStudio"
        _ = add(appName, [
            item("关于 \(appName)", #selector(NSApplication.orderFrontStandardAboutPanel(_:))),
            .separator(),
            item("设置…", #selector(showSettings(_:)), ","),
            item("新手引导…", #selector(showOnboarding(_:))),
            .separator(),
            item("隐藏 \(appName)", #selector(NSApplication.hide(_:)), "h"),
            item("隐藏其他", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]),
            item("全部显示", #selector(NSApplication.unhideAllApplications(_:))),
            .separator(),
            item("退出 \(appName)", #selector(NSApplication.terminate(_:)), "q"),
        ])
        _ = add("编辑", [
            item("撤销", Selector(("undo:")), "z"),
            item("重做", Selector(("redo:")), "z", [.command, .shift]),
            .separator(),
            item("剪切", #selector(NSText.cut(_:)), "x"),
            item("拷贝", #selector(NSText.copy(_:)), "c"),
            item("粘贴", #selector(NSText.paste(_:)), "v"),
            item("全选", #selector(NSText.selectAll(_:)), "a"),
        ])
        _ = add("相机", [
            item("连接相机", #selector(connect(_:)), "k", symbol: "bolt.horizontal.circle"),
            item("断开连接", #selector(disconnect(_:)), "k", [.command, .shift], symbol: "xmark.circle"),
            item("刷新视频（重建连接）", #selector(refreshVideo(_:)), "r", symbol: "arrow.clockwise"),
            .separator(),
            item("快门（随模式拍照 / 录制）", #selector(shutter(_:)), symbol: "circle.inset.filled"),
            item("拍照", #selector(photo(_:)), "p", [.command, .shift], symbol: "camera"),
            item("开始/停止相机录制", #selector(toggleRec(_:)), "r", [.command, .shift], symbol: "record.circle"),
            item("切换拍摄模式", #selector(cycleMode(_:)), "m", [.command, .shift], symbol: "camera.metering.multispot"),
            .separator(),
            item("录制到 Mac（实时画面）", #selector(localRec(_:)), "r", [.command, .option], symbol: "square.and.arrow.down.on.square"),
            item("保存当前画面", #selector(snapshot(_:)), "s", [.command, .shift], symbol: "photo.on.rectangle"),
            item("在访达中显示录制文件", #selector(reveal(_:)), symbol: "folder"),
            item("播放最近的录制", #selector(openRecording(_:)), symbol: "play.rectangle"),
            .separator(),
            item("云台回中", #selector(recenter(_:)), "0", [.command], symbol: "scope"),
            item("紧急停止云台", #selector(stopGimbal(_:)), ".", [.command], symbol: "hand.raised.fill"),
        ])
        var viewItems: [NSMenuItem] = []
        for s in Section.allCases {
            let i = item(s.title, #selector(goSection(_:)), "\(s.rawValue + 1)", symbol: s.symbol); i.tag = s.rawValue
            viewItems.append(i)
        }
        viewItems += [.separator(),
                      item("显示/隐藏侧边栏", #selector(NSSplitViewController.toggleSidebar(_:)), "s", [.command, .control]),
                      item("进入全屏幕", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control]),
                      item("沉浸模式（收起侧边栏与工具栏）", #selector(MainWindowController.toggleImmersive(_:)), "i", [.command, .control], symbol: "rectangle.inset.filled"),
                      item("窗口适配画面比例", #selector(MainWindowController.fitWindowToVideo(_:)), "0", [.command, .option], symbol: "aspectratio")]
        _ = add("显示", viewItems)
        let win = add("窗口", [
            item("最小化", #selector(NSWindow.performMiniaturize(_:)), "m"),
            item("缩放", #selector(NSWindow.performZoom(_:))),
        ])
        NSApp.windowsMenu = win
        let help = add("帮助", [item("PocketStudio 帮助", #selector(showHelp(_:)), "?")])
        NSApp.helpMenu = help
        return bar
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(disconnect(_:)): return model.isConnected || model.isBusy
        case #selector(connect(_:)): return !model.isConnected && !model.isBusy
        case #selector(refreshVideo(_:)), #selector(shutter(_:)), #selector(photo(_:)), #selector(toggleRec(_:)), #selector(cycleMode(_:)),
             #selector(snapshot(_:)), #selector(recenter(_:)), #selector(stopGimbal(_:)):
            return model.isConnected
        case #selector(localRec(_:)):
            menuItem.title = model.isLocalRecording ? "停止录制到 Mac" : "录制视频流到 Mac"
            return model.isConnected || model.isLocalRecording
        default: return true
        }
    }

    // MARK: Actions

    @objc func showSettings(_ sender: Any?) {
        if settingsWC == nil { settingsWC = SettingsWindowController() }
        settingsWC?.showWindow(sender)
        settingsWC?.window?.makeKeyAndOrderFront(sender)
    }
    @objc func showOnboarding(_ sender: Any?) {
        let wc = OnboardingWindowController()
        wc.onFinish = { [weak self] in self?.onboardingWC = nil; self?.main?.select(.connect) }
        onboardingWC = wc
        wc.showWindow(sender)
        wc.window?.center()
        wc.window?.makeKeyAndOrderFront(sender)
    }
    @objc func showHelp(_ sender: Any?) { main?.select(.help) }
    @objc func goSection(_ sender: NSMenuItem) { if let s = Section(rawValue: sender.tag) { main?.select(s) } }
    @objc func connect(_ sender: Any?) { model.connect(); main?.select(.connect) }
    @objc func disconnect(_ sender: Any?) { if model.isBusy { model.cancelConnect() } else { model.disconnect() } }
    @objc func refreshVideo(_ sender: Any?) { model.refreshVideo() }
    @objc func shutter(_ sender: Any?) { model.shutter() }
    @objc func photo(_ sender: Any?) { model.takePhoto() }
    @objc func toggleRec(_ sender: Any?) { model.toggleCameraRecording() }
    @objc func cycleMode(_ sender: Any?) { model.cycleMode() }
    @objc func localRec(_ sender: Any?) { model.toggleLocalRecording() }
    @objc func snapshot(_ sender: Any?) { model.saveSnapshot() }
    @objc func reveal(_ sender: Any?) { model.revealLastFile() }
    @objc func openRecording(_ sender: Any?) { model.openLastRecording() }
    @objc func recenter(_ sender: Any?) { model.recenterGimbal() }
    @objc func stopGimbal(_ sender: Any?) { model.stopGimbal() }
}
