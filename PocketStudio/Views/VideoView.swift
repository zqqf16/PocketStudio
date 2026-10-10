// VideoView.swift — AVSampleBufferDisplayLayer 承载的实时画面；支持拖拽 / 触控板控制云台

import AppKit
@preconcurrency import AVFoundation

@MainActor
final class VideoView: NSView {
    let displayLayer = AVSampleBufferDisplayLayer()
    /// 拖拽控制云台：返回归一化 (yaw, pitch)，结束时传 nil
    var onDrag: ((CGPoint?) -> Void)?
    private var dragStart: CGPoint?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        displayLayer.videoGravity = .resizeAspect
        displayLayer.backgroundColor = NSColor.black.cgColor
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel("相机实时画面")
    }
    required init?(coder: NSCoder) { fatalError() }

    override func makeBackingLayer() -> CALayer { displayLayer }
    override var wantsUpdateLayer: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric) }

    /// 返回一个可在视频队列上调用的显示闭包（只捕获 renderer，避免跨线程访问视图）
    /// AVSampleBufferVideoRenderer 设计上允许在任意线程 enqueue（Apple 文档），用盒子显式声明跨隔离域。
    /// `onFlush(reason)`：渲染器失败 / 需要冲刷时回调（视频队列），用于诊断计数与日志。
    func makeSink(onFlush: @escaping @Sendable (String) -> Void = { _ in }) -> @Sendable (CMSampleBuffer) -> Void {
        let box = RendererBox(renderer: displayLayer.sampleBufferRenderer)
        return { sb in
            let r = box.renderer
            // ⚠️ 渲染器进入 .failed（如 GPU 重置、显示器切换、系统睡眠）或 requiresFlushToResumeDecoding 时
            //    继续 enqueue 不会显示任何东西 —— 画面会「冻结」在最后一帧。必须 flush 后再送。
            if r.status == .failed {
                let e = r.error.map { "\($0.localizedDescription)" } ?? "未知"
                r.flush(); onFlush("渲染器失败：\(e)")
            } else if r.requiresFlushToResumeDecoding {
                r.flush(); onFlush("渲染器要求冲刷")
            }
            r.enqueue(sb)
        }
    }

    /// 可跨线程调用的「冲刷渲染器」
    func makeFlusher() -> @Sendable () -> Void {
        let box = RendererBox(renderer: displayLayer.sampleBufferRenderer)
        // 保留最后一帧（重连 / 恢复期间压暗显示，不清空、不改变尺寸）
        return { box.renderer.flush(removingDisplayedImage: false, completionHandler: nil) }
    }

    /// 当前渲染器状态（主线程，诊断用）
    var rendererStatusText: String {
        let r = displayLayer.sampleBufferRenderer
        switch r.status {
        case .rendering: return "rendering"
        case .failed: return "failed(\(r.error?.localizedDescription ?? "?"))"
        default: return "unknown"
        }
    }

    func clear() { displayLayer.sampleBufferRenderer.flush(removingDisplayedImage: true, completionHandler: nil) }

    override func mouseDown(with event: NSEvent) {
        dragStart = convert(event.locationInWindow, from: nil)
    }
    override func mouseDragged(with event: NSEvent) {
        guard let s = dragStart else { return }
        let p = convert(event.locationInWindow, from: nil)
        let scale = max(120, min(bounds.width, bounds.height) / 3)
        onDrag?(CGPoint(x: max(-1, min(1, (p.x - s.x) / scale)), y: max(-1, min(1, (p.y - s.y) / scale))))
        NSCursor.closedHand.set()
    }
    /// 外部取消拖动（窗口失焦等）：不回调，由调用方负责停止
    func cancelDrag() {
        if dragStart != nil { dragStart = nil; NSCursor.arrow.set() }
    }
    override func mouseUp(with event: NSEvent) {
        if dragStart != nil { onDrag?(nil) }
        dragStart = nil
        NSCursor.arrow.set()
    }
}

nonisolated private struct RendererBox: @unchecked Sendable { let renderer: AVSampleBufferVideoRenderer }
