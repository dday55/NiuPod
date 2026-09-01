import Foundation

/// 纯 Swift MD5（CryptoKit 不提供 MD5，而飞牛 FN Connect 的 authx 签名必须用它）。
///
/// 实现 RFC 1321 标准算法，无任何第三方/CommonCrypto 依赖，便于单测。
enum MD5 {
    private static let s: [UInt32] = [
        7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22,
        5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20,
        4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23,
        6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21,
    ]

    /// K 表 = floor(2^32 × |sin(i+1)|)，RFC 1321 第 3.4 节
    private static let k: [UInt32] = (0..<64).map { i in
        // |sin| < 1，乘积 < 2^32，不会溢出 UInt32
        UInt32(abs(sin(Double(i) + 1)) * 4_294_967_296.0)
    }

    /// 计算 MD5，返回 32 位小写 hex 字符串
    static func hex(_ input: String) -> String {
        hex(Array(input.utf8))
    }

    static func hex(_ bytes: [UInt8]) -> String {
        digest(bytes).map { String(format: "%02x", $0) }.joined()
    }

    static func digest(_ bytes: [UInt8]) -> [UInt8] {
        var message = bytes
        let bitLen = UInt64(bytes.count) &* 8

        // 补位：0x80 开头，补 0 至长度 ≡ 56 (mod 64)，再追加 64 位小端原长
        message.append(0x80)
        while message.count % 64 != 56 {
            message.append(0)
        }
        for i in 0..<8 {
            message.append(UInt8(truncatingIfNeeded: bitLen >> (8 * i)))
        }

        var a0: UInt32 = 0x6745_2301
        var b0: UInt32 = 0xefcd_ab89
        var c0: UInt32 = 0x98ba_dcfe
        var d0: UInt32 = 0x1032_5476

        for chunkStart in stride(from: 0, to: message.count, by: 64) {
            var m = [UInt32](repeating: 0, count: 16)
            for j in 0..<16 {
                let o = chunkStart + j * 4
                m[j] = UInt32(message[o])
                    | (UInt32(message[o + 1]) << 8)
                    | (UInt32(message[o + 2]) << 16)
                    | (UInt32(message[o + 3]) << 24)
            }

            var (a, b, c, d) = (a0, b0, c0, d0)

            for i in 0..<64 {
                var (f, g): (UInt32, Int)
                switch i {
                case 0..<16:
                    f = (b & c) | (~b & d)
                    g = i
                case 16..<32:
                    f = (d & b) | (~d & c)
                    g = (5 &* i &+ 1) % 16
                case 32..<48:
                    f = b ^ c ^ d
                    g = (3 &* i &+ 5) % 16
                default:
                    f = c ^ (b | ~d)
                    g = (7 &* i) % 16
                }

                f = f &+ a &+ k[i] &+ m[g]
                a = d
                d = c
                c = b
                let r = s[i]
                b = b &+ ((f << r) | (f >> (32 - r)))
            }

            a0 = a0 &+ a
            b0 = b0 &+ b
            c0 = c0 &+ c
            d0 = d0 &+ d
        }

        var out = [UInt8]()
        out.reserveCapacity(16)
        for v in [a0, b0, c0, d0] {
            for i in 0..<4 {
                out.append(UInt8(truncatingIfNeeded: v >> (8 * i)))
            }
        }
        return out
    }
}
