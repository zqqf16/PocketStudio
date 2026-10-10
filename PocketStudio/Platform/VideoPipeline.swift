// VideoPipeline.swift — H.264 片段 → NAL → 访问单元 → VideoToolbox 解码 → 显示 / 录制 / 截图
//
// 队列划分（互不阻塞）：
//   CameraLink.queue  网络收发 / ACK / 云台 30Hz（与视频无关，画面卡住云台照常）
//   VideoPipeline.queue  拆包 + 解码 + 显示
//   VideoPipeline.recQueue  录制写文件（AVAssetWriter / FileHandle），慢磁盘不会拖住解码
//   主线程只读 `health()` / `stats()` 的锁保护快照，绝不 queue.sync 到视频队列。

import Foundation
@preconcurrency import CoreMedia
@preconcurrency import CoreVideo
@preconcurrency import CoreImage
import ImageIO
import UniformTypeIdentifiers

/// 主线程可读的诊断快照
nonisolated struct VideoHealth: Sendable {
    var lastDecodedAt: Double? = nil
    var lastAUAt: Double? = nil
    var waitingKeyframe = true
    var decodeErrors = 0
    var lastDecodeError: String? = nil
    var decoderResets = 0
    var rendererFlushes = 0
    var keyframeRequests = 0
    var droppedWhileWaiting = 0
    var rxChunksPerSec = 0
    var ausPerSec = 0
    var recPending = 0
    var gopFrames = 0
    var pendingIngest = 0
}

nonisolated final class VideoPipeline: @unchecked Sendable {
    let queue = DispatchQueue(label: "pocketstudio.video", qos: .userInteractive)
    let recQueue = DispatchQueue(label: "pocketstudio.record", qos: .utility)
    private var parser = AnnexBParser()
    private var assembler = H264AccessUnitAssembler()
    private let decoder = H264Decoder()
    private var recorder: StreamRecorder?          // 引用只在 queue 上改；写入只在 recQueue 上发生
    private var frameTimes: [TimeInterval] = []
    private var bytesWindow: [(TimeInterval, Int)] = []
    private var chunkTimes: [TimeInterval] = []
    private var auTimes: [TimeInterval] = []
    private let ciContext = CIContext()
    private var waitingKeyframe = true
    /// 开始等 IDR 的时间；Pocket 3 实时流几乎不发 IDR（日志 GOP 716 帧≈24s），等待超过 1.2s 就直接解 P 帧（帧内刷新会自愈）
    private var waitSince: Double? = nil
    static let maxKeyframeWait = 1.2
    private var consecutiveErrors = 0
    private var lastNeedKeyframeAt = -100.0
    private var gopCache: [CMSampleBuffer] = []
    private var gopBytes = 0
    private static let gopMaxBytes = 48 * 1024 * 1024

    // 锁保护：主线程读取
    private let lock = NSLock()
    private var _health = VideoHealth()
    private var _stats = Stats(fps: 0, kbps: 0, frames: 0, bytes: 0, width: 0, height: 0)
    private var _lastPixelBuffer: CVPixelBuffer?
    private var _recordInfo: (Date, Int)?
    private var _recordingActive = false
    private var pendingIngest = 0                      // 已投递未处理的片段数（锁保护）

    /// 解码后的显示样本（在 video queue 上回调）
    var onDisplaySample: (@Sendable (CMSampleBuffer) -> Void)?
    /// 冲刷渲染器（重建解码器 / 完全重置时调用）
    var onFlushRenderer: (@Sendable () -> Void)?
    var onError: (@Sendable (String) -> Void)?
    /// 需要新的 IDR（解码器重建 / 连续解码错误 / 录制开始而无 GOP 缓存）；已在此限频 3s
    var onNeedKeyframe: (@Sendable (String) -> Void)?

    private static func now() -> Double { ProcessInfo.processInfo.systemUptime }

    init() {
        decoder.onDecoded = { [weak self] pb, pts in
            guard let self else { return }
            let now = Self.now()
            self.consecutiveErrors = 0
            self.frameTimes.append(now)
            self.frameTimes.removeAll { now - $0 > 1 }
            self.lock.withLock {
                self._lastPixelBuffer = pb
                self._health.lastDecodedAt = now
                self._stats.frames += 1
            }
            if let sb = DisplaySample.make(pb, pts: pts) { self.onDisplaySample?(sb) }
        }
        decoder.onError = { [weak self] e in self?.decoderFailed(e) }
    }

    private func updateHealth(_ f: (inout VideoHealth) -> Void) { lock.withLock { f(&_health) } }

    /// 完全重置（断开 / 刷新视频）：清空拆包、组帧、参数集、解码器、GOP 缓存、渲染器
    func reset() {
        queue.async { [self] in
            parser.reset(); assembler.reset(); decoder.invalidate(); waitingKeyframe = true; waitSince = nil
            frameTimes = []; bytesWindow = []; chunkTimes = []; auTimes = []
            gopCache = []; gopBytes = 0; consecutiveErrors = 0
            onFlushRenderer?()
            lock.withLock {
                _lastPixelBuffer = nil
                let resets = _health.decoderResets
                _health = VideoHealth(); _health.decoderResets = resets
                _stats = Stats(fps: 0, kbps: 0, frames: 0, bytes: 0, width: 0, height: 0)
            }
        }
    }

    /// 只重建解码器 + 冲刷渲染器（保留 SPS/PPS，下一个 IDR 立即恢复）
    func resetDecoder(reason: String) {
        queue.async { [self] in
            decoder.invalidate(); consecutiveErrors = 0
            onFlushRenderer?()
            updateHealth { $0.decoderResets += 1 }
            needKeyframe("重建解码器：\(reason)")
        }
    }

    /// 由 CameraLink 回调（link queue）。只做一次 async 投递，绝不阻塞网络线程。
    func ingest(_ bytes: Bytes) {
        lock.withLock { pendingIngest += 1 }
        queue.async { [self] in
            lock.withLock { pendingIngest -= 1 }
            let now = Self.now()
            bytesWindow.append((now, bytes.count)); bytesWindow.removeAll { now - $0.0 > 1 }
            chunkTimes.append(now); chunkTimes.removeAll { now - $0 > 1 }
            if let r = recorder, r.format == .h264 { recQueue.async { r.appendRaw(bytes) } }
            for nal in parser.push(bytes) {
                for au in assembler.push(nal) { handle(au, now: now) }
            }
            lock.withLock { _stats.bytes += bytes.count }
        }
    }

    private func needKeyframe(_ reason: String, force: Bool = false) {
        let now = Self.now()
        guard force || now - lastNeedKeyframeAt >= 10 else { return }
        lastNeedKeyframeAt = now
        updateHealth { $0.keyframeRequests += 1 }
        onNeedKeyframe?(reason)
    }

    private func decoderFailed(_ e: String) {
        consecutiveErrors += 1
        updateHealth { $0.decodeErrors += 1; $0.lastDecodeError = e }
        onError?(e)
        // 会话失效：H264Decoder 已清空 formatDescription，下一 AU 用缓存的 SPS/PPS 重建，并等 IDR
        // 连续 3 个错误（丢包导致参考帧缺失）：等下一个 IDR 并主动请求，避免一直花屏/冻结
        // 13:33 日志：-12909（丢包坏数据）后 v1 改为「等 IDR」，而 IDR 再也没来（丢 128 帧）→ 冻结。
        // 现在：不丢帧，继续解码（花屏几帧后由帧内刷新自愈），只低频请求一次关键帧。
        if consecutiveErrors >= 3 { needKeyframe("解码错误：\(e)") }
    }

    private func handle(_ au: H264AccessUnit, now: Double) {
        auTimes.append(now); auTimes.removeAll { now - $0 > 1 }
        updateHealth { $0.lastAUAt = now }
        if assembler.parameterSetsChanged || decoder.formatDescription == nil {
            guard let sps = assembler.sps, let pps = assembler.pps else { return }
            assembler.parameterSetsChanged = false
            if !decoder.configure(sps: sps, pps: pps) { return }
        }
        if waitingKeyframe {
            if waitSince == nil { waitSince = now }
            guard au.isKeyframe || now - (waitSince ?? now) > Self.maxKeyframeWait else {
                updateHealth { $0.droppedWhileWaiting += 1 }
                needKeyframe("等待关键帧")
                return
            }
            waitingKeyframe = false; waitSince = nil
            updateHealth { $0.waitingKeyframe = false }
        }
        let pts = CMClockGetTime(CMClockGetHostTimeClock())
        guard let sb = decoder.makeSampleBuffer(au, pts: pts) else { return }
        cacheGOP(sb, isKeyframe: au.isKeyframe)
        if let r = recorder, r.format == .mp4 { let box = SampleBox(sb: sb); recQueue.async { r.append(box.sb, isKeyframe: au.isKeyframe) } }
        decoder.decode(sb)
        if consecutiveErrors > 0, au.isKeyframe { consecutiveErrors = 0 }
    }

    struct Stats: Sendable { var fps: Int; var kbps: Int; var frames: Int; var bytes: Int; var width: Int; var height: Int }

    /// 主线程调用：只读锁内快照（由 publishStats 每次调用时在视频队列刷新）
    func stats() -> Stats {
        queue.async { [self] in
            let d = decoder.dimensions
            let fps = frameTimes.count, kbps = bytesWindow.reduce(0) { $0 + $1.1 } * 8 / 1000
            let chunks = chunkTimes.count, aus = auTimes.count, gop = gopCache.count
            lock.withLock {
                _stats.fps = fps; _stats.kbps = kbps
                _stats.width = Int(d?.width ?? 0); _stats.height = Int(d?.height ?? 0)
                _health.rxChunksPerSec = chunks; _health.ausPerSec = aus; _health.gopFrames = gop
            }
        }
        return lock.withLock { _stats }
    }

    func health() -> VideoHealth {
        lock.withLock { var h = _health; h.pendingIngest = pendingIngest; return h }
    }

    func noteRendererFlush() { updateHealth { $0.rendererFlushes += 1 } }

    private func cacheGOP(_ sb: CMSampleBuffer, isKeyframe: Bool) {
        if isKeyframe { gopCache = []; gopBytes = 0 }
        guard isKeyframe || !gopCache.isEmpty else { return }
        let n = CMSampleBufferGetTotalSampleSize(sb)
        if gopBytes + n > Self.gopMaxBytes { gopCache = []; gopBytes = 0; return }
        gopCache.append(sb); gopBytes += n
    }

    // MARK: Recording

    var isRecording: Bool { lock.withLock { _recordingActive } }

    func startRecording(to url: URL, format: RecordingFormat) throws {
        let r = try StreamRecorder(url: url, format: format)
        lock.withLock { _recordingActive = true; _recordInfo = (Date(), 0) }
        r.onProgress = { [weak self] bytes, pending in
            guard let self else { return }
            self.lock.withLock {
                if let i = self._recordInfo { self._recordInfo = (i.0, bytes) }
                self._health.recPending = pending
            }
        }
        queue.async { [self] in
            recorder = r
            if format == .mp4 {
                if gopCache.isEmpty { needKeyframe("开始录制（无 GOP 缓存）", force: true) }
                else {
                    let gop = gopCache.map(SampleBox.init(sb:))
                    recQueue.async { for (i, b) in gop.enumerated() { r.append(b.sb, isKeyframe: i == 0) } }
                }
            } else if let sps = assembler.sps, let pps = assembler.pps {
                let sc: Bytes = [0, 0, 0, 1]
                recQueue.async { r.appendRaw(sc + sps + sc + pps) }
                needKeyframe("开始录制 .h264", force: true)
            }
        }
    }

    func stopRecording(completion: @escaping @Sendable (URL?) -> Void) {
        lock.withLock { _recordingActive = false; _recordInfo = nil }
        queue.async { [self] in
            guard let r = recorder else { DispatchQueue.main.async { completion(nil) }; return }
            recorder = nil
            recQueue.async { r.finish { u in DispatchQueue.main.async { completion(u) } } }
        }
    }

    var recordingInfo: (Date, Int)? { lock.withLock { _recordInfo } }

    // MARK: Snapshot

    func saveSnapshot(to url: URL) -> Bool {
        guard let pb = lock.withLock({ _lastPixelBuffer }) else { return false }
        let ci = CIImage(cvPixelBuffer: pb)
        guard let cg = ciContext.createCGImage(ci, from: ci.extent),
              let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { return false }
        CGImageDestinationAddImage(dest, cg, nil)
        return CGImageDestinationFinalize(dest)
    }
}

/// CMSampleBuffer 跨队列传递（只读，CoreMedia 对象本身线程安全）
nonisolated struct SampleBox: @unchecked Sendable { let sb: CMSampleBuffer }
