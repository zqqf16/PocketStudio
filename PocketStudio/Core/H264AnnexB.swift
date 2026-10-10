// H264AnnexB.swift — H.264 Annex-B 字节流拆分为 NAL，并组装为访问单元（平台无关）
//
// 相机视频包 (UDP type 2) 去掉 12 字节头后是连续的 Annex-B 字节流片段（原项目直接喂给 ffplay -f h264）。

nonisolated public enum H264NALType {
    public static let slice: UInt8 = 1, idr: UInt8 = 5, sei: UInt8 = 6, sps: UInt8 = 7, pps: UInt8 = 8, aud: UInt8 = 9
    public static func of(_ nal: Bytes) -> UInt8 { nal.isEmpty ? 0 : nal[0] & 0x1F }
}

nonisolated public struct AnnexBParser {
    private var buf: Bytes = []
    private var nalStart: Int? = nil
    private var scanFrom = 0
    public init() {}

    public mutating func reset() { buf = []; nalStart = nil; scanFrom = 0 }

    /// 追加字节，返回已完整的 NAL（不含起始码）
    public mutating func push(_ bytes: Bytes) -> [Bytes] {
        buf += bytes
        var out: [Bytes] = []
        var i = scanFrom
        while i + 2 < buf.count {
            if buf[i + 2] > 1 { i += 3; continue } // 快速跳过
            if buf[i] == 0, buf[i + 1] == 0, buf[i + 2] == 1 {
                let lower = nalStart ?? 0
                let scStart = (i > lower && buf[i - 1] == 0) ? i - 1 : i
                if let s = nalStart, scStart > s {
                    var nal = Array(buf[s ..< scStart])
                    while nal.last == 0 { nal.removeLast() } // trailing_zero_8bits
                    if !nal.isEmpty { out.append(nal) }
                }
                nalStart = i + 3
                i += 3
            } else {
                i += 1
            }
        }
        // 压缩缓冲区
        if let s = nalStart {
            if s > 0 { buf.removeFirst(s); i -= s; nalStart = 0 }
        } else if buf.count > 3 {
            let drop = buf.count - 3
            buf.removeFirst(drop); i = max(0, i - drop)
        }
        scanFrom = max(0, i)
        if buf.count > 8 * 1024 * 1024 { reset() } // 保护：异常流
        return out
    }

    /// 输出缓冲区中剩余的最后一个 NAL
    public mutating func flush() -> Bytes? {
        defer { reset() }
        guard let s = nalStart, s < buf.count else { return nil }
        var nal = Array(buf[s...])
        while nal.last == 0 { nal.removeLast() }
        return nal.isEmpty ? nil : nal
    }
}

nonisolated public struct H264AccessUnit: Equatable, Sendable {
    public var nals: [Bytes]
    public var isKeyframe: Bool
    /// AVCC 格式（每个 NAL 前 4 字节大端长度），可直接放入 CMBlockBuffer
    public var avcc: Bytes {
        var out = Bytes()
        out.reserveCapacity(nals.reduce(0) { $0 + $1.count + 4 })
        for n in nals {
            let l = UInt32(n.count)
            out += [UInt8(l >> 24), UInt8((l >> 16) & 0xFF), UInt8((l >> 8) & 0xFF), UInt8(l & 0xFF)]
            out += n
        }
        return out
    }
}

nonisolated public struct H264AccessUnitAssembler {
    public private(set) var sps: Bytes?
    public private(set) var pps: Bytes?
    /// SPS/PPS 发生变化后置 true，由解码器读取后清除
    public var parameterSetsChanged = false
    private var current: [Bytes] = []
    private var hasVCL = false
    private var keyframe = false
    public init() {}

    public mutating func reset() { sps = nil; pps = nil; current = []; hasVCL = false; keyframe = false; parameterSetsChanged = false }

    private mutating func flush() -> H264AccessUnit? {
        defer { current = []; hasVCL = false; keyframe = false }
        guard hasVCL else { return nil }
        return H264AccessUnit(nals: current, isKeyframe: keyframe)
    }

    public mutating func push(_ nal: Bytes) -> [H264AccessUnit] {
        guard !nal.isEmpty else { return [] }
        var out: [H264AccessUnit] = []
        let t = H264NALType.of(nal)
        switch t {
        case H264NALType.sps, H264NALType.pps, H264NALType.aud, H264NALType.sei:
            if hasVCL, let au = flush() { out.append(au) }
            if t == H264NALType.sps { if sps != nal { sps = nal; parameterSetsChanged = true } }
            else if t == H264NALType.pps { if pps != nal { pps = nal; parameterSetsChanged = true } }
            else if t == H264NALType.sei { current.append(nal) }
        case H264NALType.slice, H264NALType.idr, 2, 3, 4:
            let firstMbZero = nal.count > 1 && (nal[1] & 0x80) != 0
            if hasVCL && firstMbZero, let au = flush() { out.append(au) }
            current.append(nal)
            hasVCL = true
            if t == H264NALType.idr { keyframe = true }
        default:
            current.append(nal)
        }
        return out
    }
}
