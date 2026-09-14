import Foundation

enum IPVersion {
    case v4
    case v6
}

/// An IPv4 (4 bytes) or IPv6 (16 bytes) address.
struct IPAddr: Hashable {
    let bytes: [UInt8]

    var isV6: Bool { bytes.count == 16 }

    var family: Int32 { isV6 ? AF_INET6 : AF_INET }

    /// Textual form, e.g. "17.253.144.10" or "2a00:1450:4001:80b::200e".
    var string: String {
        var buffer = [CChar](repeating: 0, count: 64)
        let family = self.family
        let text: String? = bytes.withUnsafeBytes { raw -> String? in
            buffer.withUnsafeMutableBufferPointer { out -> String? in
                guard let base = out.baseAddress,
                      inet_ntop(family, raw.baseAddress, base, socklen_t(out.count)) != nil else {
                    return nil
                }
                return String(cString: base)
            }
        }
        return text ?? bytes.map { String($0) }.joined(separator: ".")
    }

    /// True for globally or privately routable unicast destinations. Multicast, broadcast,
    /// link-local, loopback and unspecified addresses cannot be relayed and are dropped.
    var isUnicastRoutable: Bool {
        if isV6 {
            if bytes[0] == 0xff { return false }                              // multicast
            if bytes[0] == 0xfe && (bytes[1] & 0xc0) == 0x80 { return false } // link-local
            if bytes[0 ..< 15].allSatisfy({ $0 == 0 }) { return false }       // :: and ::1
            return true
        }
        if bytes[0] == 0 || bytes[0] == 127 || bytes[0] >= 224 { return false }
        if bytes[0] == 169 && bytes[1] == 254 { return false }
        return true
    }
}

/// A parsed IP packet. `bytes` holds the whole packet; offsets index into it.
struct ParsedPacket {
    let version: IPVersion
    let protocolNumber: UInt8
    let source: IPAddr
    let destination: IPAddr
    let totalLength: Int
    let transportOffset: Int
    let bytes: [UInt8]

    /// Parses an IPv4 or IPv6 packet. Fragments and malformed packets yield nil.
    static func parse(_ data: Data) -> ParsedPacket? {
        let b = [UInt8](data)
        guard b.count >= 20 else { return nil }
        switch b[0] >> 4 {
        case 4:
            let headerLength = Int(b[0] & 0x0f) * 4
            guard headerLength >= 20, b.count >= headerLength else { return nil }
            let totalLength = Int(readUInt16(b, 2))
            guard totalLength >= headerLength, totalLength <= b.count else { return nil }
            let fragmentBits = Int(readUInt16(b, 6)) & 0x3fff   // "more fragments" flag or a fragment offset
            guard fragmentBits == 0 else { return nil }
            return ParsedPacket(version: .v4,
                                protocolNumber: b[9],
                                source: IPAddr(bytes: Array(b[12 ..< 16])),
                                destination: IPAddr(bytes: Array(b[16 ..< 20])),
                                totalLength: totalLength,
                                transportOffset: headerLength,
                                bytes: b)
        case 6:
            guard b.count >= 40 else { return nil }
            let totalLength = 40 + Int(readUInt16(b, 4))
            guard totalLength <= b.count else { return nil }
            var nextHeader = b[6]
            var offset = 40
            var hops = 0
            while hops < 8 {
                hops += 1
                if nextHeader == 0 || nextHeader == 43 || nextHeader == 60 {
                    // Hop-by-hop, routing and destination options headers: (length + 1) * 8 bytes.
                    guard offset + 8 <= totalLength else { return nil }
                    let extensionLength = (Int(b[offset + 1]) + 1) * 8
                    nextHeader = b[offset]
                    offset += extensionLength
                    guard offset <= totalLength else { return nil }
                    continue
                }
                if nextHeader == 44 || nextHeader == 59 {
                    return nil   // fragment header or "no next header"
                }
                break
            }
            return ParsedPacket(version: .v6,
                                protocolNumber: nextHeader,
                                source: IPAddr(bytes: Array(b[8 ..< 24])),
                                destination: IPAddr(bytes: Array(b[24 ..< 40])),
                                totalLength: totalLength,
                                transportOffset: offset,
                                bytes: b)
        default:
            return nil
        }
    }
}

struct TCPSegment {
    let srcPort: UInt16
    let dstPort: UInt16
    let seq: UInt32
    let ack: UInt32
    let flags: UInt8
    let window: UInt16
    let payloadOffset: Int
    let payloadLength: Int
    let mss: UInt16?

    static func parse(_ packet: ParsedPacket) -> TCPSegment? {
        let b = packet.bytes
        let o = packet.transportOffset
        guard packet.totalLength - o >= 20 else { return nil }
        let dataOffset = Int(b[o + 12] >> 4) * 4
        guard dataOffset >= 20, o + dataOffset <= packet.totalLength else { return nil }

        var mss: UInt16? = nil
        var index = o + 20
        let optionsEnd = o + dataOffset
        while index < optionsEnd {
            let kind = b[index]
            if kind == 0 { break }               // end of options
            if kind == 1 { index += 1; continue } // no-op
            guard index + 1 < optionsEnd else { break }
            let length = Int(b[index + 1])
            guard length >= 2, index + length <= optionsEnd else { break }
            if kind == 2 && length == 4 {
                mss = readUInt16(b, index + 2)
            }
            index += length
        }

        return TCPSegment(srcPort: readUInt16(b, o),
                          dstPort: readUInt16(b, o + 2),
                          seq: readUInt32(b, o + 4),
                          ack: readUInt32(b, o + 8),
                          flags: b[o + 13],
                          window: readUInt16(b, o + 14),
                          payloadOffset: o + dataOffset,
                          payloadLength: packet.totalLength - o - dataOffset,
                          mss: mss)
    }
}

struct UDPDatagram {
    let srcPort: UInt16
    let dstPort: UInt16
    let payloadOffset: Int
    let payloadLength: Int

    static func parse(_ packet: ParsedPacket) -> UDPDatagram? {
        let b = packet.bytes
        let o = packet.transportOffset
        guard packet.totalLength - o >= 8 else { return nil }
        let length = Int(readUInt16(b, o + 4))
        guard length >= 8, o + length <= packet.totalLength else { return nil }
        return UDPDatagram(srcPort: readUInt16(b, o),
                           dstPort: readUInt16(b, o + 2),
                           payloadOffset: o + 8,
                           payloadLength: length - 8)
    }
}
