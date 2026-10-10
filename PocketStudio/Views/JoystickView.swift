// JoystickView.swift — 屏幕虚拟摇杆（拖动旋钮控制云台速度，松开自动停止）

import AppKit

@MainActor
final class JoystickView: NSView {
    /// 归一化输出：x = 偏航（右为正），y = 俯仰（上为正）
    var onChange: ((CGPoint) -> Void)?
    private(set) var value = CGPoint.zero
    private var tracking = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityElement(true)
        setAccessibilityRole(.slider)
        setAccessibilityLabel("云台摇杆")
        setAccessibilityHelp("拖动旋钮控制云台转动，松开即停止。也可使用方向键或 WASD。")
    }
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize { NSSize(width: 132, height: 132) }
    override var acceptsFirstResponder: Bool { false }

    private var radius: CGFloat { min(bounds.width, bounds.height) / 2 - 4 }
    private var knobRadius: CGFloat { radius * 0.38 }

    override func draw(_ dirtyRect: NSRect) {
        let c = CGPoint(x: bounds.midX, y: bounds.midY)
        let base = NSBezierPath(ovalIn: NSRect(x: c.x - radius, y: c.y - radius, width: radius * 2, height: radius * 2))
        NSColor.white.withAlphaComponent(0.08).setFill(); base.fill()
        NSColor.white.withAlphaComponent(0.25).setStroke(); base.lineWidth = 1; base.stroke()

        // 十字刻度
        NSColor.white.withAlphaComponent(0.35).setStroke()
        for (dx, dy) in [(0.0, 1.0), (0.0, -1.0), (1.0, 0.0), (-1.0, 0.0)] {
            let p = NSBezierPath()
            p.move(to: CGPoint(x: c.x + dx * radius * 0.72, y: c.y + dy * radius * 0.72))
            p.line(to: CGPoint(x: c.x + dx * radius * 0.86, y: c.y + dy * radius * 0.86))
            p.lineWidth = 2; p.lineCapStyle = .round; p.stroke()
        }

        let travel = radius - knobRadius
        let k = CGPoint(x: c.x + value.x * travel, y: c.y + value.y * travel)
        let knob = NSBezierPath(ovalIn: NSRect(x: k.x - knobRadius, y: k.y - knobRadius, width: knobRadius * 2, height: knobRadius * 2))
        (tracking ? NSColor.controlAccentColor : NSColor.white.withAlphaComponent(0.85)).setFill()
        knob.fill()
    }

    private func update(_ event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let travel = max(1, radius - knobRadius)
        var v = CGPoint(x: (p.x - bounds.midX) / travel, y: (p.y - bounds.midY) / travel)
        let len = hypot(v.x, v.y)
        if len > 1 { v = CGPoint(x: v.x / len, y: v.y / len) }
        // 小死区，避免误触
        if hypot(v.x, v.y) < 0.08 { v = .zero }
        value = v
        needsDisplay = true
        onChange?(v)
    }

    override func mouseDown(with event: NSEvent) { tracking = true; update(event) }
    override func mouseDragged(with event: NSEvent) { update(event) }
    /// 外部复位（不回调）
    func reset() { tracking = false; value = .zero; needsDisplay = true }
    override func mouseUp(with event: NSEvent) {
        tracking = false; value = .zero; needsDisplay = true; onChange?(.zero)
    }
}
