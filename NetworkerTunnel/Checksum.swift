import Foundation

/// Internet checksum (RFC 1071) helpers.
enum Checksum {
    /// One's-complement sum of the 16-bit big-endian words in `bytes`, folded so the result fits in 17 bits.
    static func sum(_ bytes: [UInt8]) -> UInt32 {
        sum(bytes, from: 0, count: bytes.count)
    }

    static func sum(_ bytes: [UInt8], from start: Int, count: Int) -> UInt32 {
        // A 64 KiB packet has at most 32768 words of 0xFFFF, so a UInt32 accumulator cannot overflow.
        var accumulator: UInt32 = 0
        var index = start
        let end = start + count
        while index + 1 < end {
            accumulator += UInt32(bytes[index]) << 8 | UInt32(bytes[index + 1])
            index += 2
        }
        if index < end {
            accumulator += UInt32(bytes[index]) << 8
        }
        return (accumulator & 0xffff) + (accumulator >> 16)
    }

    /// Folds the accumulated sum and returns its one's complement.
    static func finish(_ accumulator: UInt32) -> UInt16 {
        var value = accumulator
        while value > 0xffff {
            value = (value & 0xffff) + (value >> 16)
        }
        return ~UInt16(truncatingIfNeeded: value)
    }
}
