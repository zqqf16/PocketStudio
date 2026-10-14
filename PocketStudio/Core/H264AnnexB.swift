// H264AnnexB.swift — Annex-B 字节流拆分为 NAL，并组装为访问单元（平台无关）
//
// Pocket 3：UDP type 2 去掉 12 字节头后是 H.264 Annex-B（原项目直接喂给 ffplay -f h264）。
// Pocket 4 / 4P（OpenPocketCine，未在本应用实机确认）：同一路径上是 HEVC，帧前可能有 16 字节
// `00 00 01 ff` 头。编码只在见到明确的参数集后才确定——0x28 既是 HEVC IDR_N_LP 也是 H.264 PPS。

nonisolated public enum VideoCodec: String, Sendable, Equatable {
    case h264, hevc
    public var displayName: String { self == .h264 ? "H.264" : "HEVC" }

    /// 只有参数集头能锁定编码。
    /// HEVC：VPS 0x40、SPS 0x42、PPS 0x44（layer id 0）。
    /// H.264：SPS 0x67、PPS 0x68（nal_ref_idc = 3）。
    /// 0x28 不锁定：HEVC IDR_N_LP（type 20）与 H.264 PPS（nal_ref_idc = 1）共用这个字节。
    /// 0x41 是 H.264 P 片，不是 HEVC VPS（VPS 是 0x40）。0x20 是常见的 HEVC BLA，也先不当参数集。
    public static func hint(nalHeader: UInt8) -> VideoCodec? {
        switch nalHeader {
        case 0x40, 0x42, 0x44: return .hevc
        case 0x67, 0x68: return .h264
        default: return nil
        }
    }
}

nonisolated public enum H264NALType {
    public static let slice: UInt8 = 1, idr: UInt8 = 5, sei: UInt8 = 6, sps: UInt8 = 7, pps: UInt8 = 8, aud: UInt8 = 9
    public static func of(_ nal: Bytes) -> UInt8 { nal.isEmpty ? 0 : nal[0] & 0x1F }
}

nonisolated public enum HEVCNALType {
    public static let vps: UInt8 = 32, sps: UInt8 = 33, pps: UInt8 = 34, aud: UInt8 = 35
    public static let prefixSEI: UInt8 = 39, suffixSEI: UInt8 = 40
    public static func of(_ nal: Bytes) -> UInt8 { nal.isEmpty ? 0 : (nal[0] >> 1) & 0x3F }
    /// BLA / IDR / CRA。Pocket 4 预览常见 BLA_W_LP（16，首字节 0x20），不一定是 type 20。
    public static func isIRAP(_ type: UInt8) -> Bool { (16 ... 21).contains(type) }
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

/// 把「16 字节 DJI 帧头 + 声明长度的编码字节」从 Annex-B 里拆开。
/// 头为 `00 00 01 ff` | u32le 编码长度 | 8 字节元数据（OpenPocketCine，Pocket 4/4P 与 Nano；本应用未实机确认）。
/// 看不到这个头时，字节原样送出（Pocket 3 的 Annex-B 不变，只多留末尾 24 字节以免把头从包边界切开）。
nonisolated public struct DJILiveViewDeframer {
    public static let headerLength = 16
    public static let maxEncoded = 4_000_000
    private var buf = Bytes()
    private var searching = true
    public private(set) var usesFrameHeader = false
    public private(set) var frames = 0
    public private(set) var bytesSeen = 0
    public var stillSearching: Bool { searching }

    public init() {}
    public mutating func reset() {
        buf = []; searching = true; usesFrameHeader = false; frames = 0; bytesSeen = 0
    }

    public struct Output: Sendable, Equatable {
        public var bytes: Bytes
        public var resetParser: Bool
    }

    public mutating func push(_ chunk: Bytes) -> Output {
        bytesSeen += chunk.count
        buf += chunk
        if searching {
            if let idx = Self.findHeader(buf) {
                searching = false
                usesFrameHeader = true
                buf.removeFirst(idx)
                return Output(bytes: drain(), resetParser: true)
            }
            let hold = 24
            if buf.count > hold {
                let n = buf.count - hold
                let out = Bytes(buf.prefix(n))
                buf.removeFirst(n)
                return Output(bytes: out, resetParser: false)
            }
            return Output(bytes: [], resetParser: false)
        }
        return Output(bytes: drain(), resetParser: false)
    }

    /// 搜索结束时把尾部吐出。已经进入帧头模式时，只吐出完整帧，半帧留到下次。
    public mutating func flush() -> Bytes {
        if searching {
            defer { buf = [] }
            return buf
        }
        return drain()
    }

    private static func findHeader(_ b: Bytes) -> Int? {
        guard b.count >= 8 else { return nil }
        var i = 0
        let last = b.count - 8
        while i <= last {
            if b[i] == 0, b[i + 1] == 0, b[i + 2] == 1, b[i + 3] == 0xFF {
                let n = Int(b.le32(i + 4))
                if (1 ... maxEncoded).contains(n) { return i }
                i += 4
                continue
            }
            i += 1
        }
        return nil
    }

    private mutating func drain() -> Bytes {
        if buf.count >= 8, Self.findHeader(buf).map({ $0 > 0 }) == true, let idx = Self.findHeader(buf) {
            buf.removeFirst(idx)
        }
        var out = Bytes()
        while buf.count >= Self.headerLength
            && buf[0] == 0 && buf[1] == 0 && buf[2] == 1 && buf[3] == 0xFF {
            let n = Int(buf.le32(4))
            guard (1 ... Self.maxEncoded).contains(n) else { break }
            let total = Self.headerLength + n
            if buf.count < total { break }
            out.append(contentsOf: buf[Self.headerLength ..< total])
            buf.removeFirst(total)
            frames += 1
        }
        return out
    }
}

nonisolated public struct H264AccessUnit: Equatable, Sendable {
    public var nals: [Bytes]
    public var isKeyframe: Bool
    public var codec: VideoCodec = .h264
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
    public private(set) var codec: VideoCodec?
    public private(set) var vps: Bytes?
    public private(set) var sps: Bytes?
    public private(set) var pps: Bytes?
    /// 参数集发生变化后置 true，由解码器读取后清除
    public var parameterSetsChanged = false
    private var current: [Bytes] = []
    private var hasVCL = false
    private var keyframe = false
    public init() {}

    public mutating func reset() {
        codec = nil; vps = nil; sps = nil; pps = nil
        current = []; hasVCL = false; keyframe = false; parameterSetsChanged = false
    }

    private mutating func flush() -> H264AccessUnit? {
        defer { current = []; hasVCL = false; keyframe = false }
        guard hasVCL else { return nil }
        return H264AccessUnit(nals: current, isKeyframe: keyframe, codec: codec ?? .h264)
    }

    public mutating func push(_ nal: Bytes) -> [H264AccessUnit] {
        guard !nal.isEmpty else { return [] }
        if codec == nil {
            // 在 VPS/SPS/PPS 出现前不分类。0x28 单独出现不得当成 H.264 PPS 或 HEVC 关键帧。
            guard let hint = VideoCodec.hint(nalHeader: nal[0]) else { return [] }
            codec = hint
            parameterSetsChanged = true
        }
        if codec == .hevc { return pushHEVC(nal) }
        return pushH264(nal)
    }

    private mutating func pushH264(_ nal: Bytes) -> [H264AccessUnit] {
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

    private mutating func pushHEVC(_ nal: Bytes) -> [H264AccessUnit] {
        var out: [H264AccessUnit] = []
        let t = HEVCNALType.of(nal)
        switch t {
        case HEVCNALType.vps, HEVCNALType.sps, HEVCNALType.pps, HEVCNALType.aud, HEVCNALType.prefixSEI, HEVCNALType.suffixSEI:
            if hasVCL, let au = flush() { out.append(au) }
            if t == HEVCNALType.vps { if vps != nal { vps = nal; parameterSetsChanged = true } }
            else if t == HEVCNALType.sps { if sps != nal { sps = nal; parameterSetsChanged = true } }
            else if t == HEVCNALType.pps { if pps != nal { pps = nal; parameterSetsChanged = true } }
            else if t == HEVCNALType.prefixSEI || t == HEVCNALType.suffixSEI { current.append(nal) }
        default:
            if t <= 31 {
                let firstSlice = nal.count < 3 || (nal[2] & 0x80) != 0
                if hasVCL && firstSlice, let au = flush() { out.append(au) }
                current.append(nal)
                hasVCL = true
                if HEVCNALType.isIRAP(t) { keyframe = true }
            } else {
                current.append(nal)
            }
        }
        return out
    }
}
