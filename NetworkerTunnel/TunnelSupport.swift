import Foundation
import Network

/// Monotonic clock used for all protocol timers (immune to wall-clock changes).
@inline(__always)
func monotonicNow() -> TimeInterval {
    Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
}

@inline(__always)
func readUInt16(_ bytes: [UInt8], _ offset: Int) -> UInt16 {
    UInt16(bytes[offset]) << 8 | UInt16(bytes[offset + 1])
}

@inline(__always)
func readUInt32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
    UInt32(bytes[offset]) << 24 | UInt32(bytes[offset + 1]) << 16 | UInt32(bytes[offset + 2]) << 8 | UInt32(bytes[offset + 3])
}

@inline(__always)
func appendUInt16(_ bytes: inout [UInt8], _ value: UInt16) {
    bytes.append(UInt8(truncatingIfNeeded: value >> 8))
    bytes.append(UInt8(truncatingIfNeeded: value))
}

@inline(__always)
func appendUInt32(_ bytes: inout [UInt8], _ value: UInt32) {
    bytes.append(UInt8(truncatingIfNeeded: value >> 24))
    bytes.append(UInt8(truncatingIfNeeded: value >> 16))
    bytes.append(UInt8(truncatingIfNeeded: value >> 8))
    bytes.append(UInt8(truncatingIfNeeded: value))
}

/// TCP sequence number comparisons that are correct across 32-bit wraparound.
@inline(__always)
func seqLessThan(_ a: UInt32, _ b: UInt32) -> Bool {
    Int32(bitPattern: a &- b) < 0
}

@inline(__always)
func seqLessOrEqual(_ a: UInt32, _ b: UInt32) -> Bool {
    Int32(bitPattern: a &- b) <= 0
}

enum TCPFlags {
    static let fin: UInt8 = 0x01
    static let syn: UInt8 = 0x02
    static let rst: UInt8 = 0x04
    static let psh: UInt8 = 0x08
    static let ack: UInt8 = 0x10
}

/// Identifies one transport flow between the device (local) and a remote endpoint.
struct FlowKey: Hashable {
    let transport: UInt8      // 6 = TCP, 17 = UDP
    let local: IPAddr
    let localPort: UInt16
    let remote: IPAddr
    let remotePort: UInt16

    /// The remote endpoint as Network.framework wants it.
    var remoteEndpoint: NWEndpoint? {
        let host: NWEndpoint.Host
        if remote.isV6 {
            guard let address = IPv6Address(Data(remote.bytes)) else { return nil }
            host = .ipv6(address)
        } else {
            guard let address = IPv4Address(Data(remote.bytes)) else { return nil }
            host = .ipv4(address)
        }
        return .hostPort(host: host, port: NWEndpoint.Port(integerLiteral: remotePort))
    }
}

/// The key under which statistics are aggregated: one row per (transport, remote address, remote port).
struct StatsKey: Hashable {
    let transport: String
    let remoteAddress: String
    let remotePort: UInt16

    var id: String {
        FlowStats.makeID(transport: transport, remoteAddress: remoteAddress, remotePort: remotePort)
    }
}
