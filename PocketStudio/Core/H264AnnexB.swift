// H264AnnexB.swift — Annex-B 字节流拆分为 NAL，并组装为访问单元（平台无关）
//
// Pocket 3：UDP type 2 去掉 12 字节分片头后就是 H.264 Annex-B（原项目直接喂给 ffplay -f h264）。
// 不要再在这条流上找 16 字节帧头：`00 00 01` 是 Annex-B 起始码，后面紧跟的字节会被误当成
// `00 00 01 ff` 帧头，按「长度」把 NAL 从中间切开，VideoToolbox 连续报 -12909。
// Pocket 4 / 4P（OpenPocketCine，未在本应用实机确认）才可能在访问单元前另有 16 字节
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

/// 把「16 字节 DJI 帧头 + 声明长度的编码字节」从码流里拆开。
/// 头为 `00 00 01 ff` | u32le 编码长度 | 8 字节元数据（OpenPocketCine 对 Pocket 4/4P 与 Nano 的描述）。
///
/// `armed == false`（Pocket 3、未识别机型）时字节原样送出，和加这个类型之前一样。
/// `armed == true` 时，只有「下一帧头正好落在声明长度处，且载荷以 Annex-B 起始码开头」才剥离。
/// 单独的 `00 00 01` + `ff`（起始码，或 4 字节起始码 `00 00 00 01` 错一位）不会被当成帧头。
nonisolated public struct DJILiveViewDeframer {
    public static let headerLength = 16
    public static let maxEncoded = 1_500_000
    /// 只对 Pocket 4 / 4P 打开。Pocket 3 的 12 字节分片头已经在 UDP 层去掉。
    public var armed = false
    private var buf = Bytes()
    private var searching = true
    public private(set) var usesFrameHeader = false
    public private(set) var frames = 0
    public private(set) var bytesSeen = 0
    public var stillSearching: Bool { searching }

    public init(armed: Bool = false) { self.armed = armed }
    public mutating func reset() {
        buf = []; searching = true; usesFrameHeader = false; frames = 0; bytesSeen = 0
    }

    public struct Output: Sendable, Equatable {
        public var bytes: Bytes
        public var resetParser: Bool
    }

    public mutating func push(_ chunk: Bytes) -> Output {
        bytesSeen += chunk.count
        if !armed { return Output(bytes: chunk, resetParser: false) }
        buf += chunk
        if searching {
            switch Self.probe(buf, allowExactEnd: false) {
            case let .confirmed(idx):
                searching = false
                usesFrameHeader = true
                let prefix: Bytes = idx > 0 ? Bytes(buf.prefix(idx)) : []
                buf.removeFirst(idx)
                return Output(bytes: prefix + drain(allowExactEnd: false), resetParser: true)
            case let .holdFrom(idx):
                if idx == 0 { return Output(bytes: [], resetParser: false) }
                let out = Bytes(buf.prefix(idx))
                buf.removeFirst(idx)
                return Output(bytes: out, resetParser: false)
            case .none:
                return Output(bytes: release(keep: 24), resetParser: false)
            }
        }
        return Output(bytes: drain(allowExactEnd: false), resetParser: false)
    }

    /// 流结束时吐出尾部。帧头模式里，缓冲恰好停在一帧末尾也算证明（没有「下一帧」了）。
    public mutating func flush() -> Bytes {
        if !armed {
            defer { buf = [] }
            return buf
        }
        if searching, case let .confirmed(idx) = Self.probe(buf, allowExactEnd: true) {
            searching = false
            usesFrameHeader = true
            buf.removeFirst(idx)
        }
        let out = drain(allowExactEnd: true)
        if searching {
            let tail = buf
            buf = []
            return out + tail
        }
        return out
    }

    private enum Probe {
        case confirmed(Int)
        case holdFrom(Int)
        case none
    }

    private static func isMarker(_ b: Bytes, _ i: Int) -> Bool {
        i >= 0 && i + 3 < b.count && b[i] == 0 && b[i + 1] == 0 && b[i + 2] == 1 && b[i + 3] == 0xFF
    }

    /// 帧头后面的载荷必须以 Annex-B 起始码开头，且 NAL 禁止位是 0。
    /// `00 00 00 01 ff`（4 字节起始码错一位）或起始码后直接跟着 `ff` 的 NAL，偏移 16 处不是起始码。
    private static func payloadLooksLikeAnnexB(_ b: Bytes, _ payload: Int) -> Bool {
        guard payload >= 0 else { return false }
        if payload + 3 < b.count, b[payload] == 0, b[payload + 1] == 0, b[payload + 2] == 1 {
            return (b[payload + 3] & 0x80) == 0
        }
        if payload + 4 < b.count, b[payload] == 0, b[payload + 1] == 0, b[payload + 2] == 0, b[payload + 3] == 1 {
            return (b[payload + 4] & 0x80) == 0
        }
        return false
    }

    /// 证明是帧头：声明长度处还能看到下一帧的 `00 00 01 ff`。
    /// `allowExactEnd` 只在 flush 时使用，避免半个 UDP 包刚好凑满长度就提前剥。
    private static func probe(_ b: Bytes, allowExactEnd: Bool) -> Probe {
        guard b.count >= 8 else { return .none }
        var i = 0
        while i + 8 <= b.count {
            if isMarker(b, i) {
                let n = Int(b.le32(i + 4))
                if (4 ... maxEncoded).contains(n) {
                    let payload = i + headerLength
                    let end = payload + n
                    if b.count < payload + 4 {
                        return .holdFrom(i)
                    }
                    if payloadLooksLikeAnnexB(b, payload) {
                        if b.count >= end + 4, isMarker(b, end) { return .confirmed(i) }
                        if allowExactEnd, b.count == end { return .confirmed(i) }
                        if b.count < end + 4 { return .holdFrom(i) }
                    }
                }
            }
            i += 1
        }
        return .none
    }

    private mutating func release(keep: Int) -> Bytes {
        guard buf.count > keep else { return [] }
        let n = buf.count - keep
        let out = Bytes(buf.prefix(n))
        buf.removeFirst(n)
        return out
    }

    private mutating func drain(allowExactEnd: Bool) -> Bytes {
        var out = Bytes()
        while true {
            switch Self.probe(buf, allowExactEnd: allowExactEnd) {
            case let .confirmed(idx):
                if idx > 0 {
                    out.append(contentsOf: buf.prefix(idx))
                    buf.removeFirst(idx)
                }
                let n = Int(buf.le32(4))
                let total = Self.headerLength + n
                guard buf.count >= total else { return out }
                out.append(contentsOf: buf[Self.headerLength ..< total])
                buf.removeFirst(total)
                frames += 1
            case let .holdFrom(idx):
                if idx > 0 {
                    out.append(contentsOf: buf.prefix(idx))
                    buf.removeFirst(idx)
                }
                return out
            case .none:
                out.append(contentsOf: release(keep: 24))
                return out
            }
        }
    }
}

/// 录制用 GOP 缓存的上限。Pocket 3 经常几十秒才来一个 IDR；没有上限时每个 AU 都留在数组里。
nonisolated public enum GOPCacheLimit {
    public static let maxFrames = 900
    public static let maxBytes = 48 * 1024 * 1024
    public static func exceeded(frames: Int, bytes: Int) -> Bool {
        frames > maxFrames || bytes > maxBytes
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
