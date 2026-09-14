import Foundation

/// Builds IP packets (with correct checksums) that are handed back to the kernel through the tunnel.
enum PacketBuilder {
    /// Only touched on the tunnel queue.
    private static var nextIdentification = UInt16.random(in: 0 ... UInt16.max)

    static func tcp(version: IPVersion,
                    src: IPAddr, srcPort: UInt16,
                    dst: IPAddr, dstPort: UInt16,
                    seq: UInt32, ack: UInt32,
                    flags: UInt8, window: UInt16,
                    options: [UInt8] = [],
                    payload: ArraySlice<UInt8> = []) -> Data {
        precondition(options.count % 4 == 0 && options.count <= 40, "TCP options must be padded to 32-bit words")
        let headerLength = 20 + options.count
        var segment = [UInt8]()
        segment.reserveCapacity(headerLength + payload.count)
        appendUInt16(&segment, srcPort)
        appendUInt16(&segment, dstPort)
        appendUInt32(&segment, seq)
        appendUInt32(&segment, ack)
        segment.append(UInt8(truncatingIfNeeded: headerLength / 4) << 4)
        segment.append(flags)
        appendUInt16(&segment, window)
        segment.append(0); segment.append(0)   // checksum, filled in below
        segment.append(0); segment.append(0)   // urgent pointer
        segment.append(contentsOf: options)
        segment.append(contentsOf: payload)
        let checksum = transportChecksum(version: version, src: src, dst: dst, protocolNumber: 6, segment: segment)
        segment[16] = UInt8(truncatingIfNeeded: checksum >> 8)
        segment[17] = UInt8(truncatingIfNeeded: checksum)
        return wrap(version: version, src: src, dst: dst, protocolNumber: 6, payload: segment)
    }

    static func udp(version: IPVersion,
                    src: IPAddr, srcPort: UInt16,
                    dst: IPAddr, dstPort: UInt16,
                    payload: ArraySlice<UInt8>) -> Data {
        var datagram = [UInt8]()
        datagram.reserveCapacity(8 + payload.count)
        appendUInt16(&datagram, srcPort)
        appendUInt16(&datagram, dstPort)
        appendUInt16(&datagram, UInt16(truncatingIfNeeded: 8 + payload.count))
        datagram.append(0); datagram.append(0)  // checksum, filled in below
        datagram.append(contentsOf: payload)
        var checksum = transportChecksum(version: version, src: src, dst: dst, protocolNumber: 17, segment: datagram)
        if checksum == 0 { checksum = 0xffff }   // RFC 768: a computed zero is transmitted as all ones
        datagram[6] = UInt8(truncatingIfNeeded: checksum >> 8)
        datagram[7] = UInt8(truncatingIfNeeded: checksum)
        return wrap(version: version, src: src, dst: dst, protocolNumber: 17, payload: datagram)
    }

    /// Pseudo-header + segment checksum shared by TCP and UDP over IPv4 and IPv6.
    private static func transportChecksum(version: IPVersion, src: IPAddr, dst: IPAddr,
                                          protocolNumber: UInt8, segment: [UInt8]) -> UInt16 {
        var accumulator: UInt32 = 0
        accumulator += Checksum.sum(src.bytes)
        accumulator += Checksum.sum(dst.bytes)
        let length = UInt32(segment.count)
        // IPv4 pseudo header: zero, protocol, 16-bit length. IPv6: 32-bit length, zeros, next header.
        // Both reduce to the same word sum.
        accumulator += UInt32(protocolNumber)
        accumulator += length & 0xffff
        accumulator += length >> 16
        accumulator += Checksum.sum(segment)
        return Checksum.finish(accumulator)
    }

    private static func wrap(version: IPVersion, src: IPAddr, dst: IPAddr,
                             protocolNumber: UInt8, payload: [UInt8]) -> Data {
        switch version {
        case .v4:
            let totalLength = 20 + payload.count
            var packet = [UInt8]()
            packet.reserveCapacity(totalLength)
            packet.append(0x45)                 // version 4, header length 5 words
            packet.append(0x00)                 // DSCP / ECN
            appendUInt16(&packet, UInt16(truncatingIfNeeded: totalLength))
            appendUInt16(&packet, nextIdentification)
            nextIdentification &+= 1
            packet.append(0x40); packet.append(0x00)  // flags: don't fragment; offset 0
            packet.append(64)                   // TTL
            packet.append(protocolNumber)
            packet.append(0); packet.append(0)  // header checksum, filled in below
            packet.append(contentsOf: src.bytes)
            packet.append(contentsOf: dst.bytes)
            let checksum = Checksum.finish(Checksum.sum(packet, from: 0, count: 20))
            packet[10] = UInt8(truncatingIfNeeded: checksum >> 8)
            packet[11] = UInt8(truncatingIfNeeded: checksum)
            packet.append(contentsOf: payload)
            return Data(packet)
        case .v6:
            var packet = [UInt8]()
            packet.reserveCapacity(40 + payload.count)
            packet.append(0x60); packet.append(0); packet.append(0); packet.append(0)  // version 6, class 0, flow 0
            appendUInt16(&packet, UInt16(truncatingIfNeeded: payload.count))
            packet.append(protocolNumber)
            packet.append(64)                   // hop limit
            packet.append(contentsOf: src.bytes)
            packet.append(contentsOf: dst.bytes)
            packet.append(contentsOf: payload)
            return Data(packet)
        }
    }
}
