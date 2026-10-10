// UDPFrame.swift — DJI 9004 端口 UDP 传输层封包（逐字移植自 pocket3/udp_protocol.py）
//
// 8 字节头: [len|0x8000 (LE16)] [session (LE16)] [seq (LE16)] [type] [XOR(前 7 字节)]

nonisolated public enum DJIUDPType {
    public static let handshake: UInt8 = 0x00
    public static let telemetry: UInt8 = 0x01
    public static let video: UInt8 = 0x02
    public static let ackTelemetry: UInt8 = 0x03
    public static let ack: UInt8 = 0x04
    public static let command: UInt8 = 0x05
    public static let ack6: UInt8 = 0x06

    public static let names: [UInt8: String] = [
        0: "HANDSHAKE", 1: "TELEMETRY", 2: "VIDEO", 3: "ACK_TELEM", 4: "ACK", 5: "COMMAND", 6: "ACK6",
    ]
}

nonisolated public struct DJIUDPHeader: Equatable, Sendable {
    public var length: Int
    public var sessionID: UInt16
    public var seq: UInt16
    public var type: UInt8
    public var xorOK: Bool
    public var body: Bytes
}

nonisolated public enum DJIUDPFrame {
    public static let cameraIP = "192.168.2.1"
    public static let cameraPort: UInt16 = 9004

    /// 16 位回绕序号比较：new 是否在 old 之后
    public static func seqAhead(_ new: UInt16, _ old: UInt16) -> Bool {
        let diff = new &- old
        return diff > 0 && diff < 0x8000
    }

    public static func header(length: Int, sessionID: UInt16, seq: UInt16, type: UInt8) -> Bytes {
        var b = Bytes(repeating: 0, count: 8)
        let l = UInt16(truncatingIfNeeded: length) | 0x8000
        b[0] = UInt8(l & 0xFF); b[1] = UInt8(l >> 8)
        b[2] = UInt8(sessionID & 0xFF); b[3] = UInt8(sessionID >> 8)
        b[4] = UInt8(seq & 0xFF); b[5] = UInt8(seq >> 8)
        b[6] = type
        var x: UInt8 = 0
        for i in 0 ..< 7 { x ^= b[i] }
        b[7] = x
        return b
    }

    public static func parse(_ data: Bytes) -> DJIUDPHeader? {
        guard data.count >= 8 else { return nil }
        var x: UInt8 = 0
        for i in 0 ..< 7 { x ^= data[i] }
        return DJIUDPHeader(
            length: Int(data.le16(0) & 0x7FFF),
            sessionID: data.le16(2),
            seq: data.le16(4),
            type: data[6],
            xorOK: x == data[7],
            body: data.count > 8 ? Array(data[8...]) : [])
    }

    /// 握手负载（40 字节，抓包自 DJI Mimo），seed 低 3 位必须为 0
    public static func handshakePayload(seed: UInt16) -> Bytes {
        [UInt8(seed & 0xFF), UInt8(seed >> 8),
         0x64, 0x00, 0x64, 0x00, 0xC0, 0x05,
         0x14, 0x00, 0x00, 0x64, 0x00, 0x00, 0x01, 0x90,
         0x01, 0xC0, 0x05, 0x14, 0x00, 0x00, 0x64, 0x00,
         0x14, 0x00, 0x64, 0x00, 0xC0, 0x05, 0x14, 0x00,
         0x00, 0x64, 0x00, 0x01, 0x01, 0x04, 0x01, 0x02]
    }

    public static func handshakePacket(sessionID: UInt16, seed: UInt16) -> Bytes {
        let p = handshakePayload(seed: seed)
        return header(length: 8 + p.count, sessionID: sessionID, seq: 0, type: DJIUDPType.handshake) + p
    }

    /// ACK (type 4) — 26 字节负载：视频窗口 / 应答遥测窗口 / 命令发送窗口 各 8 字节 + 2 字节 MB 长度
    public static func ackPacket(sessionID: UInt16, videoRx: UInt16, ackTelemRx: UInt16, cmdSeq: UInt16) -> Bytes {
        var p = Bytes()
        p.reserveCapacity(26)
        for v in [videoRx, ackTelemRx, cmdSeq] {
            p.appendLE16(v); p.appendLE16(v); p.appendLE16(0); p.appendLE16(0)
        }
        p.appendLE16(0)
        return header(length: 8 + p.count, sessionID: sessionID, seq: 0, type: DJIUDPType.ack) + p
    }

    /// COMMAND (type 5) 包：header + 发送窗口(4) + 重发状态(4) + 计数(1) + 0x01(1) + 0x0060(2) + DUML
    /// 关键：body 第 9 字节必须是 0x01，否则相机会丢包。
    /// `legacy` = 原 Python 布局（ack 字段 = seq−32、尾部 0x60 = 「无人机」标志）；
    /// 默认采用 OpenPocketCine 的 Pocket 布局（ack = seq−8、尾部 00 00）。OPC：「这里写错会静默丢弃写命令而读照常」。
    public static func commandPacket(sessionID: UInt16, seq: UInt16, msgSeq: UInt16, duml: Bytes, legacy: Bool = false) -> Bytes {
        var p = Bytes()
        p.reserveCapacity(12 + duml.count)
        p.appendLE16(seq &- (legacy ? 32 : 8))
        p.appendLE16(seq)
        p.appendLE16(0); p.appendLE16(0)
        p.append(UInt8(msgSeq & 0xFF)); p.append(0x01); p.appendLE16(legacy ? 0x0060 : 0x0000)
        p += duml
        return header(length: 8 + p.count, sessionID: sessionID, seq: seq, type: DJIUDPType.command) + p
    }
}
