// DJIBLEMessage.swift — DJI BLE 消息编解码（移植自 pocket3/ble.py，源自 Moblin）
//
// 帧: 0x55 | len(1) | 0x04 | CRC8(前3) | target(LE16) | id(LE16) | type(LE24) | payload | CRC16
// GATT: FFF4 = Notify（相机→App），FFF5 = Write（App→相机，无响应写）

import Foundation

nonisolated public struct DJIBLEMessage: Equatable, Sendable {
    public var target: UInt16
    public var id: UInt16
    public var type: UInt32
    public var payload: Bytes
    public init(target: UInt16, id: UInt16, type: UInt32, payload: Bytes) {
        self.target = target; self.id = id; self.type = type; self.payload = payload
    }
}

nonisolated public enum DJIBLEError: Error, Equatable, Sendable, CustomStringConvertible {
    case invalid, lengthMismatch(got: Int, expected: Int), badVersion(UInt8), crc8, crc16
    public var description: String {
        switch self {
        case .invalid: return "无效的 BLE 消息"
        case let .lengthMismatch(g, e): return "长度不符：收到 \(g)，期望 \(e)"
        case let .badVersion(v): return "版本错误：\(v)"
        case .crc8: return "CRC8 校验失败"
        case .crc16: return "CRC16 校验失败"
        }
    }
}

nonisolated public enum DJIBLE {
    public static let notifyCharacteristic = "FFF4"
    public static let writeCharacteristic = "FFF5"

    public static let djiCompanyID: Bytes = [0xAA, 0x08]
    public static let xtraCompanyID: Bytes = [0xAA, 0xF7]

    public static let models: [Bytes: String] = [
        [0x10, 0x00]: "OsmoAction2",
        [0x12, 0x00]: "OsmoAction3",
        [0x14, 0x00]: "OsmoAction4",
        [0x15, 0x00]: "OsmoAction5Pro",
        [0x17, 0x00]: "Osmo360",
        [0x18, 0x00]: "OsmoAction6",
        [0x20, 0x00]: "OsmoPocket3",
    ]
    public static let pocket3Model = "OsmoPocket3"

    // 事务 ID / 目标 / 类型（来自 Moblin）
    public static let pairID: UInt16 = 0x8092, pairTarget: UInt16 = 0x0702, pairType: UInt32 = 0x450740
    public static let stopStreamID: UInt16 = 0xEAC8, stopStreamTarget: UInt16 = 0x0802, stopStreamType: UInt32 = 0x8E0240
    public static let prepareLiveID: UInt16 = 0x8C12, prepareLiveTarget: UInt16 = 0x0802, prepareLiveType: UInt32 = 0xE10240
    public static let setupWiFiID: UInt16 = 0x8C19, setupWiFiTarget: UInt16 = 0x0702, setupWiFiType: UInt32 = 0x470740
    public static let startStreamID: UInt16 = 0x8C2C, startStreamTarget: UInt16 = 0x0802, startStreamType: UInt32 = 0x780840
    public static let batteryType: UInt32 = 0x020D00

    public static let pairHash: Bytes = [
        0x20, 0x32, 0x38, 0x34, 0x61, 0x65, 0x35, 0x62,
        0x38, 0x64, 0x37, 0x36, 0x62, 0x33, 0x33, 0x37,
        0x35, 0x61, 0x30, 0x34, 0x61, 0x36, 0x34, 0x31,
        0x37, 0x61, 0x64, 0x37, 0x31, 0x62, 0x65, 0x61,
        0x33,
    ]
    public static let pairPIN = "mbln"

    public static func packString(_ s: String) -> Bytes {
        let d = Array(s.utf8)
        return [UInt8(truncatingIfNeeded: d.count)] + d
    }

    public static func build(target: UInt16, id: UInt16, type: UInt32, payload: Bytes) -> Bytes {
        var b: Bytes = [0x55, UInt8(truncatingIfNeeded: 13 + payload.count), 0x04]
        b.append(DJICRC.crc8(b))
        b.appendLE16(target)
        b.appendLE16(id)
        b.append(UInt8(type & 0xFF)); b.append(UInt8((type >> 8) & 0xFF)); b.append(UInt8((type >> 16) & 0xFF))
        b += payload
        b.appendLE16(DJICRC.crc16(b))
        return b
    }

    public static func build(_ m: DJIBLEMessage) -> Bytes { build(target: m.target, id: m.id, type: m.type, payload: m.payload) }

    public static func parse(_ d: Bytes) throws -> DJIBLEMessage {
        guard d.count >= 13, d[0] == 0x55 else { throw DJIBLEError.invalid }
        let length = Int(d[1])
        guard d.count == length else { throw DJIBLEError.lengthMismatch(got: d.count, expected: length) }
        guard d[2] == 0x04 else { throw DJIBLEError.badVersion(d[2]) }
        guard DJICRC.crc8(d[0 ..< 3]) == d[3] else { throw DJIBLEError.crc8 }
        guard DJICRC.crc16(d[0 ..< length - 2]) == d.le16(length - 2) else { throw DJIBLEError.crc16 }
        let type = UInt32(d[8]) | (UInt32(d[9]) << 8) | (UInt32(d[10]) << 16)
        return DJIBLEMessage(target: d.le16(4), id: d.le16(6), type: type, payload: Array(d[11 ..< length - 2]))
    }

    /// 解析广播中的厂商数据（CoreBluetooth 的 kCBAdvDataManufacturerData 已包含 2 字节厂商 ID）
    public static func identify(manufacturerData full: Bytes) -> (isDJI: Bool, model: String?) {
        guard full.count >= 4 else { return (false, nil) }
        let cid = Array(full[0 ..< 2])
        guard cid == djiCompanyID || cid == xtraCompanyID else { return (false, nil) }
        return (true, models[Array(full[2 ..< 4])] ?? "Unknown")
    }

    // MARK: 负载构造

    public static var pairMessage: DJIBLEMessage {
        DJIBLEMessage(target: pairTarget, id: pairID, type: pairType, payload: pairHash + packString(pairPIN))
    }
    public static var stopStreamingMessage: DJIBLEMessage {
        DJIBLEMessage(target: stopStreamTarget, id: stopStreamID, type: stopStreamType, payload: [0x01, 0x01, 0x1A, 0x00, 0x01, 0x02])
    }
    public static var prepareLivestreamMessage: DJIBLEMessage {
        DJIBLEMessage(target: prepareLiveTarget, id: prepareLiveID, type: prepareLiveType, payload: [0x1A])
    }
    public static func setupWiFiMessage(ssid: String, password: String) -> DJIBLEMessage {
        DJIBLEMessage(target: setupWiFiTarget, id: setupWiFiID, type: setupWiFiType, payload: packString(ssid) + packString(password))
    }

    public enum RTMPResolution: String, CaseIterable, Sendable { case p480 = "480p", p720 = "720p", p1080 = "1080p"
        var byte: UInt8 { switch self { case .p480: return 0x47; case .p720: return 0x04; case .p1080: return 0x0A } }
    }

    public static func startRTMPMessage(url: String, resolution: RTMPResolution = .p1080, fps: Int = 30, bitrateKbps: Int = 6000) -> DJIBLEMessage {
        let urlData = Array(url.utf8)
        var p: Bytes = [0x00, 0x2E, 0x00, resolution.byte]
        p.appendLE16(UInt16(truncatingIfNeeded: bitrateKbps))
        p += [0x02, 0x00]
        p.append(fps == 25 ? 2 : 3)
        p += [0x00, 0x00, 0x00]
        p.append(UInt8(truncatingIfNeeded: urlData.count))
        p.append(0x00)
        p += urlData
        return DJIBLEMessage(target: startStreamTarget, id: startStreamID, type: startStreamType, payload: p)
    }

    /// 电池推送 (type 0x020D00)：payload[20]
    public static func battery(from m: DJIBLEMessage) -> Int? {
        guard m.type == batteryType, m.payload.count >= 21 else { return nil }
        return Int(m.payload[20])
    }
}

/// BLE 通知分片重组（原项目假定一次通知即完整帧；这里额外容忍分片）
nonisolated public struct DJIBLEReassembler {
    private var buffer: Bytes = []
    public init() {}
    public mutating func push(_ chunk: Bytes) -> [Bytes] {
        if buffer.isEmpty, chunk.first != 0x55 { return [chunk] } // 交给 parse 报错/记录
        buffer += chunk
        var out: [Bytes] = []
        while buffer.count >= 2 {
            guard buffer[0] == 0x55 else { out.append(buffer); buffer = []; break }
            let len = Int(buffer[1])
            if len < 13 { out.append(buffer); buffer = []; break }
            if buffer.count < len { break }
            out.append(Array(buffer[0 ..< len]))
            buffer.removeFirst(len)
        }
        if buffer.count > 512 { buffer = [] }
        return out
    }
}


/// TCP 7001「戳一下」（OpenPocketCine：Pocket 系列在 UDP 握手前先在 TCP 7001 发送 SetPairingPIN，并在整个会话期间保持该 TCP 连接；
/// 关闭它会让相机 RST）。载荷与 BLE 配对相同（同一 identifier + PIN），这样相机视为已配对的同一个 App。
nonisolated public enum DJITCPPoke {
    public static let port: UInt16 = 7001
    public static var frame: Bytes {
        DUML.build(senderType: DUMLDevice.app, senderID: 0, receiverType: 0x07, receiverID: 0,
                   cmdSet: 0x07, cmdID: 0x45, payload: DJIBLE.pairHash + DJIBLE.packString(DJIBLE.pairPIN),
                   seq: 0x8092, cmdType: DUMLCmdType.request)
    }
}
