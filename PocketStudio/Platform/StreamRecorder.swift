// StreamRecorder.swift — 将视频流录制到本地文件（原项目 --record：写入原始 .h264）
//
// 两种格式：
//  • .h264：逐字写入收到的 Annex-B 字节流（与原项目完全相同，可用 ffplay/VLC 播放）
//  • .mp4 ：AVAssetWriter 直通封装（不重新编码，无画质损失，QuickTime 可直接播放）

import Foundation
@preconcurrency import AVFoundation
@preconcurrency import CoreMedia

nonisolated enum RecordingFormat: String, CaseIterable, Sendable {
    case mp4, h264
    var displayName: String { self == .mp4 ? "MP4（推荐，QuickTime 可播放）" : "原始 H.264（与原项目一致）" }
}

/// 隔离：nonisolated，只在 VideoPipeline.recQueue 上使用。
nonisolated final class StreamRecorder: @unchecked Sendable {
    let url: URL
    let format: RecordingFormat
    private var handle: FileHandle?
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var started = false
    private var formatHint: CMFormatDescription?
    private(set) var bytesWritten = 0
    private(set) var startDate = Date()
    /// (已写字节, 排队样本数)
    var onProgress: (@Sendable (Int, Int) -> Void)?

    init(url: URL, format: RecordingFormat) throws {
        self.url = url; self.format = format
        switch format {
        case .h264:
            FileManager.default.createFile(atPath: url.path, contents: nil)
            handle = try FileHandle(forWritingTo: url)
        case .mp4:
            writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        }
    }

    /// 原始字节流（仅 .h264）
    func appendRaw(_ bytes: Bytes) {
        guard format == .h264, let h = handle else { return }
        h.write(Data(bytes)); bytesWritten += bytes.count
        onProgress?(bytesWritten, 0)
    }

    /// 压缩样本（仅 .mp4）。从第一个关键帧开始写入。
    func append(_ sb: CMSampleBuffer, isKeyframe: Bool) {
        guard format == .mp4, let writer else { return }
        let fd = CMSampleBufferGetFormatDescription(sb)
        if !started {
            guard isKeyframe, let fd else { return }
            let inp = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: fd)
            inp.expectsMediaDataInRealTime = true
            guard writer.canAdd(inp) else { return }
            writer.add(inp)
            guard writer.startWriting() else { return }
            writer.startSession(atSourceTime: CMSampleBufferGetPresentationTimeStamp(sb))
            input = inp; formatHint = fd; started = true; startDate = Date()
        }
        // 开始录制时会一次性灌入缓存的整个 GOP；写入器没准备好时先排队，不能丢帧（丢参考帧 = 花屏）
        pending.append(sb)
        drain()
    }

    private var pending: [CMSampleBuffer] = []

    private func drain() {
        guard let input, let writer, writer.status == .writing else { return }
        while !pending.isEmpty, input.isReadyForMoreMediaData {
            let sb = pending.removeFirst()
            if input.append(sb) { bytesWritten += CMSampleBufferGetTotalSampleSize(sb) }
        }
        if pending.count > 600 { pending.removeFirst(pending.count - 600) }   // 写盘严重落后：丢最旧的，防止内存无限增长
        onProgress?(bytesWritten, pending.count)
    }

    func finish(completion: @escaping @Sendable (URL?) -> Void) {
        if let h = handle { try? h.close(); handle = nil; completion(url); return }
        guard let writer, started, let input else {
            writer?.cancelWriting(); try? FileManager.default.removeItem(at: url); completion(nil); return
        }
        let u = url
        let box = WriterBox(writer: writer, input: input)
        let done: @Sendable () -> Void = {
            box.input.markAsFinished()
            box.writer.finishWriting {
                let ok = box.writer.status == .completed
                if !ok { try? FileManager.default.removeItem(at: u) }
                completion(ok ? u : nil)
            }
        }
        // 尽量写完排队的样本（最多等 2 秒）
        var tries = 0
        while !pending.isEmpty && tries < 200 && writer.status == .writing {
            drain(); if pending.isEmpty { break }
            Thread.sleep(forTimeInterval: 0.01); tries += 1
        }
        done()
    }
}

/// AVAssetWriter 跨到 finishWriting 的 @Sendable 回调里只读 status，用盒子显式声明。
nonisolated private struct WriterBox: @unchecked Sendable { let writer: AVAssetWriter; let input: AVAssetWriterInput }
