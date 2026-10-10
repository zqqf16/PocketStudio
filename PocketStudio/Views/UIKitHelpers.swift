// UIKitHelpers.swift — AppKit 小工具：Liquid Glass 面板、系统按钮、标签、布局
//
// 本文件集中使用 macOS 26 新 API（NSGlassEffectView / NSButton.BezelStyle.glass），
// 若将来 SDK 有调整，只需修改这里。

import AppKit

@MainActor
enum UI {
    static func symbol(_ name: String, size: CGFloat = 15, weight: NSFont.Weight = .regular, scale: NSImage.SymbolScale = .medium) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: size, weight: weight, scale: scale))
    }

    static func label(_ s: String, size: CGFloat = 13, weight: NSFont.Weight = .regular, color: NSColor = .labelColor, mono: Bool = false) -> NSTextField {
        let l = NSTextField(labelWithString: s)
        l.font = mono ? .monospacedSystemFont(ofSize: size, weight: weight) : .systemFont(ofSize: size, weight: weight)
        l.textColor = color
        l.lineBreakMode = .byTruncatingTail
        l.translatesAutoresizingMaskIntoConstraints = false
        return l
    }

    static func wrappingLabel(_ s: String, size: CGFloat = 13, color: NSColor = .secondaryLabelColor) -> NSTextField {
        let l = NSTextField(wrappingLabelWithString: s)
        l.font = .systemFont(ofSize: size)
        l.textColor = color
        l.isSelectable = true
        l.translatesAutoresizingMaskIntoConstraints = false
        return l
    }

    static func title(_ s: String) -> NSTextField { label(s, size: 22, weight: .bold) }
    static func headline(_ s: String) -> NSTextField { label(s, size: 15, weight: .semibold) }

    /// Liquid Glass 风格按钮（macOS 26）
    static func glassButton(_ title: String = "", symbol: String? = nil, symbolSize: CGFloat = 16,
                            target: AnyObject?, action: Selector?, tooltip: String? = nil,
                            prominent: Bool = false, tint: NSColor? = nil) -> NSButton {
        let img = symbol.flatMap { UI.symbol($0, size: symbolSize, weight: .medium) }
        let b: NSButton
        if let img { b = NSButton(title: title, image: img, target: target, action: action) }
        else { b = NSButton(title: title, target: target, action: action) }
        b.bezelStyle = .glass
        b.controlSize = .large
        b.imagePosition = title.isEmpty ? .imageOnly : .imageLeading
        if prominent { b.bezelColor = tint ?? .controlAccentColor; b.keyEquivalent = "" }
        else if let tint { b.contentTintColor = tint }
        b.toolTip = tooltip ?? (title.isEmpty ? nil : title)
        if title.isEmpty, let tooltip { b.setAccessibilityLabel(tooltip) }
        b.translatesAutoresizingMaskIntoConstraints = false
        return b
    }

    /// 标准系统按钮（表单内使用）
    static func button(_ title: String, symbol: String? = nil, target: AnyObject?, action: Selector?, prominent: Bool = false) -> NSButton {
        let b = glassButton(title, symbol: symbol, symbolSize: 13, target: target, action: action, prominent: prominent)
        b.controlSize = .regular
        return b
    }

    static func checkbox(_ title: String, on: Bool, target: AnyObject?, action: Selector?) -> NSButton {
        let b = NSButton(checkboxWithTitle: title, target: target, action: action)
        b.state = on ? .on : .off
        b.translatesAutoresizingMaskIntoConstraints = false
        return b
    }

    /// 玻璃面板：内容视图四边留白
    static func glass(_ content: NSView, cornerRadius: CGFloat = 18, padding: CGFloat = 10, tint: NSColor? = nil) -> NSGlassEffectView {
        let g = NSGlassEffectView()
        g.translatesAutoresizingMaskIntoConstraints = false
        g.cornerRadius = cornerRadius
        if let tint { g.tintColor = tint }
        let wrapper = NSView()
        wrapper.translatesAutoresizingMaskIntoConstraints = false
        content.translatesAutoresizingMaskIntoConstraints = false
        wrapper.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: wrapper.leadingAnchor, constant: padding),
            content.trailingAnchor.constraint(equalTo: wrapper.trailingAnchor, constant: -padding),
            content.topAnchor.constraint(equalTo: wrapper.topAnchor, constant: padding),
            content.bottomAnchor.constraint(equalTo: wrapper.bottomAnchor, constant: -padding),
        ])
        g.contentView = wrapper
        NSLayoutConstraint.activate([
            wrapper.leadingAnchor.constraint(equalTo: g.leadingAnchor),
            wrapper.trailingAnchor.constraint(equalTo: g.trailingAnchor),
            wrapper.topAnchor.constraint(equalTo: g.topAnchor),
            wrapper.bottomAnchor.constraint(equalTo: g.bottomAnchor),
        ])
        return g
    }

    static func vstack(_ views: [NSView], spacing: CGFloat = 8, alignment: NSLayoutConstraint.Attribute = .leading) -> NSStackView {
        let s = NSStackView(views: views)
        s.orientation = .vertical; s.spacing = spacing; s.alignment = alignment
        s.translatesAutoresizingMaskIntoConstraints = false
        return s
    }

    static func hstack(_ views: [NSView], spacing: CGFloat = 8, alignment: NSLayoutConstraint.Attribute = .centerY) -> NSStackView {
        let s = NSStackView(views: views)
        s.orientation = .horizontal; s.spacing = spacing; s.alignment = alignment
        s.translatesAutoresizingMaskIntoConstraints = false
        return s
    }

    static func pin(_ v: NSView, to c: NSView, inset: CGFloat = 0) {
        v.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            v.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: inset),
            v.trailingAnchor.constraint(equalTo: c.trailingAnchor, constant: -inset),
            v.topAnchor.constraint(equalTo: c.topAnchor, constant: inset),
            v.bottomAnchor.constraint(equalTo: c.bottomAnchor, constant: -inset),
        ])
    }

    static func pin(_ v: NSView, to g: NSLayoutGuide, inset: CGFloat = 0) {
        v.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            v.leadingAnchor.constraint(equalTo: g.leadingAnchor, constant: inset),
            v.trailingAnchor.constraint(equalTo: g.trailingAnchor, constant: -inset),
            v.topAnchor.constraint(equalTo: g.topAnchor, constant: inset),
            v.bottomAnchor.constraint(equalTo: g.bottomAnchor, constant: -inset),
        ])
    }

    /// 可滚动的表单页面容器（文档视图为垂直 stack，宽度跟随）
    static func scrollingPage(_ stack: NSStackView, maxWidth: CGFloat = 760) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        let doc = FlippedView()
        doc.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(stack)
        scroll.documentView = doc
        let w = stack.widthAnchor.constraint(equalTo: doc.widthAnchor, constant: -48)
        w.priority = .defaultHigh
        NSLayoutConstraint.activate([
            doc.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            doc.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            doc.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            stack.topAnchor.constraint(equalTo: doc.topAnchor, constant: 24),
            stack.bottomAnchor.constraint(equalTo: doc.bottomAnchor, constant: -24),
            stack.centerXAnchor.constraint(equalTo: doc.centerXAnchor),
            stack.widthAnchor.constraint(lessThanOrEqualToConstant: maxWidth),
            w,
        ])
        return scroll
    }

    static func separator() -> NSBox {
        let b = NSBox(); b.boxType = .separator; b.translatesAutoresizingMaskIntoConstraints = false; return b
    }

    static func copyToPasteboard(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }
}

@MainActor
final class FlippedView: NSView { override var isFlipped: Bool { true } }

/// 带圆角背景的分组卡片（系统风格）
@MainActor
final class CardView: NSView {
    init(_ content: NSView, padding: CGFloat = 16) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 14
        layer?.cornerCurve = .continuous
        addSubview(content)
        UI.pin(content, to: self, inset: padding)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func updateLayer() {
        layer?.backgroundColor = NSColor.quaternarySystemFill.cgColor
    }
    override var wantsUpdateLayer: Bool { true }
}

// MARK: 沉浸式取景用的深色 HUD 材质 / 渐变遮罩

/// 深色半透明 HUD 面板：NSVisualEffectView(.hudWindow) + 强制 darkAqua + 细描边 + 柔和阴影。
/// 在任意亮度的视频上都保证白色图标/文字的对比度（浅色 Liquid Glass 在亮画面上几乎看不清）。
@MainActor
final class HUDPanel: NSView {
    let contentView = NSView()
    private let blur = NSVisualEffectView()
    init(_ content: NSView, cornerRadius: CGFloat = 18, padding: CGFloat = 8) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        appearance = NSAppearance(named: .darkAqua)
        wantsLayer = true
        shadow = {
            let s = NSShadow(); s.shadowBlurRadius = 14; s.shadowOffset = NSSize(width: 0, height: -3)
            s.shadowColor = NSColor.black.withAlphaComponent(0.45); return s
        }()
        blur.material = .hudWindow
        blur.blendingMode = .withinWindow
        blur.state = .active
        blur.wantsLayer = true
        blur.layer?.cornerRadius = cornerRadius
        blur.layer?.cornerCurve = .continuous
        blur.layer?.masksToBounds = true
        blur.layer?.borderWidth = 0.5
        blur.layer?.borderColor = NSColor.white.withAlphaComponent(0.14).cgColor
        blur.translatesAutoresizingMaskIntoConstraints = false
        // 额外压暗一层，保证亮画面上的对比度
        let tint = NSView(); tint.wantsLayer = true
        tint.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.28).cgColor
        tint.translatesAutoresizingMaskIntoConstraints = false
        addSubview(blur); UI.pin(blur, to: self)
        blur.addSubview(tint); UI.pin(tint, to: blur)
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        UI.pin(content, to: self, inset: padding)
    }
    required init?(coder: NSCoder) { fatalError() }
}

/// 顶部 / 底部黑色渐变遮罩（流媒体 App 风格），不拦截鼠标
@MainActor
final class ScrimView: NSView {
    enum Edge { case top, bottom }
    private let gradient = CAGradientLayer()
    init(edge: Edge, opacity: CGFloat = 0.72) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        appearance = NSAppearance(named: .darkAqua)
        wantsLayer = true
        let dark = NSColor.black.withAlphaComponent(opacity).cgColor, clear = NSColor.black.withAlphaComponent(0).cgColor
        // AppKit 图层坐标 y 向上：startPoint (0.5,0) 为底部
        gradient.colors = edge == .top ? [clear, dark] : [dark, clear]
        gradient.startPoint = CGPoint(x: 0.5, y: 0); gradient.endPoint = CGPoint(x: 0.5, y: 1)
        layer?.addSublayer(gradient)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layout() { super.layout(); CATransaction.begin(); CATransaction.setDisableActions(true); gradient.frame = bounds; CATransaction.commit() }
    override func hitTest(_ point: NSPoint) -> NSView? {
        let v = super.hitTest(point); return v === self ? nil : v
    }
}

/// 深色胶囊状态标签（顶部遮罩里的连接 / 模式 / 录制 chip）
@MainActor
final class ChipView: NSView {
    let icon = NSImageView()
    let label = UI.label("", size: 12, weight: .semibold, color: .white)
    init(symbol: String) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        appearance = NSAppearance(named: .darkAqua)
        wantsLayer = true
        layer?.cornerRadius = 11; layer?.cornerCurve = .continuous
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.45).cgColor
        layer?.borderWidth = 0.5; layer?.borderColor = NSColor.white.withAlphaComponent(0.15).cgColor
        icon.image = UI.symbol(symbol, size: 11, weight: .semibold)
        icon.contentTintColor = .white
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let s = UI.hstack([icon, label], spacing: 5)
        addSubview(s)
        NSLayoutConstraint.activate([
            s.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 9), s.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            s.centerYAnchor.constraint(equalTo: centerYAnchor), heightAnchor.constraint(equalToConstant: 22),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }
    func set(_ text: String, symbol: String? = nil, tint: NSColor = .white, bg: NSColor? = nil) {
        label.stringValue = text
        if let symbol { icon.image = UI.symbol(symbol, size: 11, weight: .semibold) }
        icon.contentTintColor = tint
        layer?.backgroundColor = (bg ?? NSColor.black.withAlphaComponent(0.45)).cgColor
    }
}
