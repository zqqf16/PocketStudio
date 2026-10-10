// ByteIO.swift — 小端字节读写工具（平台无关，可在 Linux 上测试）

import Foundation

public typealias Bytes = [UInt8]

nonisolated extension Array where Element == UInt8 {
    @inlinable public mutating func appendLE16(_ v: UInt16) {
        append(UInt8(truncatingIfNeeded: v))
        append(UInt8(truncatingIfNeeded: v >> 8))
    }
    @inlinable public mutating func appendLE32(_ v: UInt32) {
        for s in stride(from: 0, to: 32, by: 8) { append(UInt8(truncatingIfNeeded: v >> UInt32(s))) }
    }
    @inlinable public func le16(_ o: Int) -> UInt16 {
        UInt16(self[o]) | (UInt16(self[o + 1]) << 8)
    }
    @inlinable public func le16s(_ o: Int) -> Int16 { Int16(bitPattern: le16(o)) }
    @inlinable public func le32(_ o: Int) -> UInt32 {
        UInt32(self[o]) | (UInt32(self[o + 1]) << 8) | (UInt32(self[o + 2]) << 16) | (UInt32(self[o + 3]) << 24)
    }

    /// 十六进制字符串（可选分隔符），与 Python bytes.hex(sep) 一致
    public func hexString(separator: String = "") -> String {
        let digits = Swift.Array<Character>("0123456789abcdef")
        var parts: [String] = []
        parts.reserveCapacity(count)
        for b in self { parts.append(String([digits[Int(b >> 4)], digits[Int(b & 0x0F)]])) }
        return parts.joined(separator: separator)
    }

    /// 解析十六进制字符串（容忍空格、冒号、0x 前缀）。失败返回 nil。
    public init?(hexString: String) {
        var cleaned = hexString.lowercased().replacingOccurrences(of: "0x", with: "")
        cleaned.removeAll { $0 == " " || $0 == ":" || $0 == "," || $0 == "\n" || $0 == "\t" }
        guard cleaned.count % 2 == 0 else { return nil }
        var out: [UInt8] = []
        var it = cleaned.makeIterator()
        while let h = it.next(), let l = it.next() {
            guard let v = UInt8(String([h, l]), radix: 16) else { return nil }
            out.append(v)
        }
        self = out
    }
}
