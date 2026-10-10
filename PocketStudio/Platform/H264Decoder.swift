// H264Decoder.swift — VideoToolbox 硬件解码 H.264（替代原项目的 ffplay）

import Foundation
@preconcurrency import CoreMedia
@preconcurrency import VideoToolbox
@preconcurrency import CoreVideo

/// 隔离：nonisolated。只在 VideoPipeline.queue（串行）上使用；VT 同步解码时回调也在该线程。

nonisolated final class H264Decoder: @unchecked Sendable {
    private(set) var formatDescription: CMVideoFormatDescription?
    private var session: VTDecompressionSession?
    var onDecoded: ((CVPixelBuffer, CMTime) -> Void)?
    var onError: ((String) -> Void)?

    deinit { invalidate() }

    func invalidate() {
        if let s = session { VTDecompressionSessionWaitForAsynchronousFrames(s); VTDecompressionSessionInvalidate(s) }
        session = nil
        formatDescription = nil
    }

    /// 由 SPS/PPS 创建（或重建）格式描述与解码会话
    @discardableResult
    func configure(sps: Bytes, pps: Bytes) -> Bool {
        invalidate()
        var fd: CMFormatDescription?
        let status: OSStatus = sps.withUnsafeBufferPointer { s in
            pps.withUnsafeBufferPointer { p in
                let ptrs: [UnsafePointer<UInt8>] = [s.baseAddress!, p.baseAddress!]
                let sizes: [Int] = [sps.count, pps.count]
                return ptrs.withUnsafeBufferPointer { pp in
                    sizes.withUnsafeBufferPointer { sz in
                        CMVideoFormatDescriptionCreateFromH264ParameterSets(
                            allocator: kCFAllocatorDefault, parameterSetCount: 2,
                            parameterSetPointers: pp.baseAddress!, parameterSetSizes: sz.baseAddress!,
                            nalUnitHeaderLength: 4, formatDescriptionOut: &fd)
                    }
                }
            }
        }
        guard status == noErr, let fd else { onError?("创建格式描述失败 \(status)"); return false }
        formatDescription = fd

        let attrs: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferIOSurfacePropertiesKey: [CFString: Any](),
            kCVPixelBufferMetalCompatibilityKey: true,
        ]
        var s: VTDecompressionSession?
        let st = VTDecompressionSessionCreate(allocator: kCFAllocatorDefault, formatDescription: fd,
                                              decoderSpecification: nil, imageBufferAttributes: attrs as CFDictionary,
                                              outputCallback: nil, decompressionSessionOut: &s)
        guard st == noErr, let s else { onError?("创建解码会话失败 \(st)"); return false }
        VTSessionSetProperty(s, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        session = s
        return true
    }

    /// 将访问单元封装为压缩 CMSampleBuffer（录制 MP4 直通也复用它）
    func makeSampleBuffer(_ au: H264AccessUnit, pts: CMTime) -> CMSampleBuffer? {
        guard let fd = formatDescription else { return nil }
        let data = au.avcc
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: data.count,
                                                 blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
                                                 dataLength: data.count, flags: 0, blockBufferOut: &block) == noErr,
              let block else { return nil }
        let copied = data.withUnsafeBytes { raw in
            CMBlockBufferReplaceDataBytes(with: raw.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: data.count)
        }
        guard copied == noErr else { return nil }
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 60), presentationTimeStamp: pts, decodeTimeStamp: .invalid)
        var size = data.count
        var sb: CMSampleBuffer?
        guard CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: fd,
                                        sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                                        sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sb) == noErr,
              let sb else { return nil }
        if let arr = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: true), CFArrayGetCount(arr) > 0 {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(arr, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dict,
                                 Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque(),
                                 Unmanaged.passUnretained(au.isKeyframe ? kCFBooleanFalse! : kCFBooleanTrue!).toOpaque())
        }
        return sb
    }

    /// 同步解码一帧
    func decode(_ sb: CMSampleBuffer) {
        guard let s = session else { return }
        var info = VTDecodeInfoFlags()
        let cb = StatusBox()
        let st = VTDecompressionSessionDecodeFrame(s, sampleBuffer: sb, flags: [], infoFlagsOut: &info) { [weak self] status, _, image, pts, _ in
            cb.status = status
            guard status == noErr, let image else { return }
            self?.onDecoded?(image, pts)
        }
        // ⚠️ 旧版只把 session 置 nil 却保留 formatDescription → VideoPipeline 以为解码器还在，永远不重建（画面永久冻结，
        //    只有改 SPS 才能恢复）。现在会话失效时整体 invalidate（formatDescription = nil），下一 AU 用缓存参数集重建。
        if st == kVTInvalidSessionErr || cb.status == kVTInvalidSessionErr {
            invalidate(); onError?("解码会话失效（\(st)），将用缓存的 SPS/PPS 重建并等待关键帧")
        } else if st != noErr { onError?("解码错误 \(st)") }
        else if cb.status != noErr { onError?("解码回调错误 \(cb.status)") }
    }

    /// 显示尺寸：考虑像素宽高比与 clean aperture（竖拍 / 非方形像素时与编码尺寸不同）
    var dimensions: CMVideoDimensions? {
        guard let fd = formatDescription else { return nil }
        let s = CMVideoFormatDescriptionGetPresentationDimensions(fd, usePixelAspectRatio: true, useCleanAperture: true)
        guard s.width > 0, s.height > 0 else { return CMVideoFormatDescriptionGetDimensions(fd) }
        return CMVideoDimensions(width: Int32(s.width.rounded()), height: Int32(s.height.rounded()))
    }
}

/// 将解码后的像素缓冲包装为可直接显示的 CMSampleBuffer
nonisolated enum DisplaySample {
    static func make(_ pb: CVPixelBuffer, pts: CMTime) -> CMSampleBuffer? {
        var fd: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pb, formatDescriptionOut: &fd) == noErr,
              let fd else { return nil }
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: pts, decodeTimeStamp: .invalid)
        var sb: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pb, formatDescription: fd,
                                                       sampleTiming: &timing, sampleBufferOut: &sb) == noErr, let sb else { return nil }
        if let arr = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: true), CFArrayGetCount(arr) > 0 {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(arr, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dict,
                                 Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue!).toOpaque())
        }
        return sb
    }
}

/// 同步解码回调里回传状态（回调与调用在同一线程；flags 为空 = 同步解码）
nonisolated private final class StatusBox: @unchecked Sendable { var status: OSStatus = noErr }
