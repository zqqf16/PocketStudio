// ShutterButton.swift — 类 iOS 相机的统一快门：外圈白环 + 内部随模式变化（白圆 / 红圆 / 红色圆角方块）

import AppKit

@MainActor
final class ShutterButton: NSControl {
    var style: ShutterStyle = .photo { didSet { if style != oldValue { animateChange() } } }
    private var pressed = false
    private let ring = CAShapeLayer()
    private let core = CAShapeLayer()
    private let badge = NSImageView()
    static let size: CGFloat = 50

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        ring.fillColor = nil
        ring.strokeColor = NSColor.white.cgColor
        ring.lineWidth = 3
        layer?.addSublayer(ring)
        layer?.addSublayer(core)
        badge.contentTintColor = .white
        badge.translatesAutoresizingMaskIntoConstraints = false
        addSubview(badge)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Self.size),
            heightAnchor.constraint(equalToConstant: Self.size),
            badge.centerXAnchor.constraint(equalTo: centerXAnchor),
            badge.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        update(animated: false)
    }
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize { NSSize(width: Self.size, height: Self.size) }
    override var isEnabled: Bool { didSet { alphaValue = isEnabled ? 1 : 0.4 } }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func layout() { super.layout(); update(animated: false) }

    private func animateChange() { update(animated: true) }

    private func update(animated: Bool) {
        let b = bounds
        guard b.width > 0 else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(!animated)
        CATransaction.setAnimationDuration(0.2)
        ring.frame = b
        ring.path = CGPath(ellipseIn: b.insetBy(dx: 2, dy: 2), transform: nil)
        let inner: CGRect, radius: CGFloat, color: NSColor
        switch style {
        case .photo: inner = b.insetBy(dx: 6, dy: 6); radius = inner.width / 2; color = .white
        case .record: inner = b.insetBy(dx: 6, dy: 6); radius = inner.width / 2; color = .systemRed
        case .stop: inner = b.insetBy(dx: 15, dy: 15); radius = 4; color = .systemRed
        }
        let r = pressed ? inner.insetBy(dx: 3, dy: 3) : inner
        core.path = CGPath(roundedRect: r, cornerWidth: min(radius, r.width / 2), cornerHeight: min(radius, r.height / 2), transform: nil)
        core.fillColor = color.cgColor
        CATransaction.commit()
        if case let .record(sym?) = style { badge.image = UI.symbol(sym, size: 16, weight: .semibold); badge.isHidden = false }
        else { badge.isHidden = true }
        switch style {
        case .photo: setAccessibilityLabel("拍照")
        case .record: setAccessibilityLabel("开始录制")
        case .stop: setAccessibilityLabel("停止录制")
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        pressed = true; update(animated: true)
    }
    override func mouseUp(with event: NSEvent) {
        guard pressed else { return }
        pressed = false; update(animated: true)
        if bounds.contains(convert(event.locationInWindow, from: nil)) { _ = sendAction(action, to: target) }
    }
    override func accessibilityPerformPress() -> Bool { _ = sendAction(action, to: target); return true }
}
