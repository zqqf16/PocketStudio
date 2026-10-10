// DUML.swift — DJI DUML 帧构造 / 解析（逐字移植自 pocket3/duml.py）
//
// 帧格式（小端）:
//  [0]    0x55 SOF
//  [1..2] len(10bit) | version(6bit)<<10
//  [3]    CRC8(前 3 字节)
//  [4]    sender  = id<<5 | type
//  [5]    receiver= id<<5 | type
//  [6..7] seq
//  [8]    cmdType<<5 | encrypt
//  [9]    cmdSet
//  [10]   cmdId
//  [11..] payload
//  [-2..] CRC16(之前所有字节)

nonisolated public enum DUMLDevice {
    public static let any: UInt8 = 0, camera: UInt8 = 1, app: UInt8 = 2, flightController: UInt8 = 3
    public static let gimbal: UInt8 = 4, center: UInt8 = 5, rc: UInt8 = 6, wifi: UInt8 = 7
    public static let dm368: UInt8 = 8, hdLink: UInt8 = 9, controller: UInt8 = 10, pc: UInt8 = 11
    public static let battery: UInt8 = 12, esc: UInt8 = 13

    public static let names: [UInt8: String] = [
        0: "Any", 1: "Camera", 2: "App", 3: "FC", 4: "Gimbal",
        5: "Center", 6: "RC", 7: "WiFi", 8: "DM368", 9: "HDLink",
        10: "Controller", 11: "PC", 12: "Battery", 13: "ESC",
    ]
    public static func name(_ t: UInt8) -> String { names[t] ?? "Dev\(t)" }
}

nonisolated public enum DUMLCmdSet {
    public static let general: UInt8 = 0, special: UInt8 = 1, camera: UInt8 = 2, fc: UInt8 = 3
    public static let gimbal: UInt8 = 4, center: UInt8 = 5, rc: UInt8 = 6, wifi: UInt8 = 7
    public static let dm368: UInt8 = 8, hdLink: UInt8 = 9, controller: UInt8 = 10, esc: UInt8 = 13

    public static let names: [UInt8: String] = [
        0: "General", 1: "Special", 2: "Camera", 3: "FC", 4: "Gimbal",
        5: "Center", 6: "RC", 7: "WiFi", 8: "DM368", 9: "HDLink",
        10: "Controller", 13: "ESC",
    ]
    public static func name(_ s: UInt8) -> String { names[s] ?? "Set\(s)" }
}

/// DUML 第 8 字节高 3 位（flags = cmdType << 5）。
/// ⚠️ 原 Python 项目把 0x00 叫 REQ、0x40 叫 PUSH，与实际语义相反（OpenPocketCine DumlFrame.swift 抓包结论）：
///   0x00 = notify（无需应答，如云台摇杆流、相机状态推送）
///   0x40 = request（需要应答 —— 相机/云台命令必须用它，否则相机常常忽略）
///   0x80 = write / ack 类（DM368 注册、云台模式应答）
///   0xC0 = response
nonisolated public enum DUMLCmdType {
    public static let notify: UInt8 = 0
    public static let ack: UInt8 = 1
    public static let request: UInt8 = 2
    /// DM368 注册命令使用（cmd_byte=0x80）
    public static let write: UInt8 = 4
    public static let response: UInt8 = 6

    /// 是否是对我们请求的应答（flags 最高位 0x80 置位：0x80 / 0xC0）
    public static func isReply(_ t: UInt8) -> Bool { t & 0x04 != 0 }

    public static func name(_ t: UInt8) -> String {
        switch t {
        case 0: return "NTFY"; case 1: return "ACK"; case 2: return "REQ"; case 4: return "W/ACK"; case 6: return "RSP"
        default: return "T\(t)"
        }
    }
}

nonisolated public struct DUMLPacket: Equatable, Sendable {
    public var offset: Int
    public var length: Int
    public var version: UInt8
    public var senderType: UInt8
    public var senderID: UInt8
    public var receiverType: UInt8
    public var receiverID: UInt8
    public var seq: UInt16
    public var cmdType: UInt8
    public var encrypt: UInt8
    public var cmdSet: UInt8
    public var cmdID: UInt8
    public var payload: Bytes
    public var raw: Bytes
}

nonisolated public enum DUML {
    public static let sof: UInt8 = 0x55

    public static func build(
        senderType: UInt8, senderID: UInt8,
        receiverType: UInt8, receiverID: UInt8,
        cmdSet: UInt8, cmdID: UInt8,
        payload: Bytes = [],
        seq: UInt16 = 0,
        cmdType: UInt8 = DUMLCmdType.notify,
        encrypt: UInt8 = 0,
        version: UInt8 = 1
    ) -> Bytes {
        let pktLen = 11 + payload.count + 2
        let lenVer = UInt16(pktLen & 0x03FF) | (UInt16(version & 0x3F) << 10)
        var buf: Bytes = [sof]
        buf.reserveCapacity(pktLen)
        buf.appendLE16(lenVer)
        buf.append(DJICRC.crc8(buf))
        buf.append(((senderID & 0x07) << 5) | (senderType & 0x1F))
        buf.append(((receiverID & 0x07) << 5) | (receiverType & 0x1F))
        buf.appendLE16(seq)
        buf.append(((cmdType & 0x07) << 5) | (encrypt & 0x07))
        buf.append(cmdSet)
        buf.append(cmdID)
        buf += payload
        buf.appendLE16(DJICRC.crc16(buf))
        return buf
    }

    /// 从任意字节流中扫描出所有 CRC 校验通过的 DUML 帧（与 Python parse_duml 行为一致）
    public static func parse(_ data: Bytes, offset: Int = 0) -> [DUMLPacket] {
        var packets: [DUMLPacket] = []
        var i = offset
        while i < data.count - 4 {
            if data[i] != sof { i += 1; continue }
            if i + 3 > data.count { break }
            let lenVer = Int(data[i + 1]) | (Int(data[i + 2]) << 8)
            let pktLen = lenVer & 0x3FF
            let version = UInt8((lenVer >> 10) & 0x3F)
            if pktLen < 13 || pktLen > 2048 || i + pktLen > data.count { i += 1; continue }
            let pkt = Array(data[i ..< i + pktLen])
            if DJICRC.crc8(pkt[0 ..< 3]) != pkt[3] { i += 1; continue }
            let crc16 = pkt.le16(pktLen - 2)
            if DJICRC.crc16(pkt[0 ..< pktLen - 2]) != crc16 { i += 1; continue }

            let s = pkt[4], r = pkt[5], c = pkt[8]
            packets.append(DUMLPacket(
                offset: i, length: pktLen, version: version,
                senderType: s & 0x1F, senderID: (s >> 5) & 0x07,
                receiverType: r & 0x1F, receiverID: (r >> 5) & 0x07,
                seq: pkt.le16(6),
                cmdType: (c >> 5) & 0x07, encrypt: c & 0x07,
                cmdSet: pkt[9], cmdID: pkt[10],
                payload: Array(pkt[11 ..< pktLen - 2]),
                raw: pkt))
            i += pktLen
        }
        return packets
    }
}
