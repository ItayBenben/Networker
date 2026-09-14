import Foundation
import Network

/// Owns every relayed flow. Receives raw IP packets from the tunnel, dispatches them to TCP
/// connections or UDP sessions, and writes the replies back. Everything runs on `queue`.
final class PacketRouter {
    let queue: DispatchQueue
    let stats: StatsCollector
    private let writePackets: ([Data], [NSNumber]) -> Void
    private var tcp: [FlowKey: TCPConnection] = [:]
    private var udp: [FlowKey: UDPSession] = [:]
    private var timer: DispatchSourceTimer?
    private let pathMonitor = NWPathMonitor()
    private var tickCount = 0
    private var stopped = false

    private static let maxTCPConnections = 512
    private static let maxUDPSessions = 512
    private static let tickInterval: TimeInterval = 0.25
    private static let ticksPerFlush = 20   // every 5 s

    init(queue: DispatchQueue, stats: StatsCollector, writePackets: @escaping ([Data], [NSNumber]) -> Void) {
        self.queue = queue
        self.stats = stats
        self.writePackets = writePackets
    }

    func start() {
        pathMonitor.pathUpdateHandler = { [weak self] path in
            self?.stats.currentInterface = Self.describe(path)
        }
        pathMonitor.start(queue: queue)

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + Self.tickInterval, repeating: Self.tickInterval)
        timer.setEventHandler { [weak self] in
            self?.tick()
        }
        timer.resume()
        self.timer = timer
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        timer?.cancel()
        timer = nil
        pathMonitor.cancel()
        for connection in Array(tcp.values) {
            connection.close()
        }
        for session in Array(udp.values) {
            session.close()
        }
        tcp.removeAll()
        udp.removeAll()
        stats.activeTCP = 0
        stats.activeUDP = 0
        stats.flushSync(now: Date(), isCapturing: false)
    }

    // MARK: - Packets from the kernel

    func handle(_ packets: [Data]) {
        guard !stopped else { return }
        for packet in packets {
            route(packet)
        }
    }

    private func route(_ data: Data) {
        guard let packet = ParsedPacket.parse(data) else {
            stats.recordUnsupported()
            return
        }
        guard packet.destination.isUnicastRoutable else {
            return   // multicast, broadcast, link-local: nothing to relay
        }
        let now = Date()
        let mono = monotonicNow()

        switch packet.protocolNumber {
        case 6:
            guard let segment = TCPSegment.parse(packet) else {
                stats.recordUnsupported()
                return
            }
            let key = FlowKey(transport: 6, local: packet.source, localPort: segment.srcPort,
                              remote: packet.destination, remotePort: segment.dstPort)
            if let connection = tcp[key] {
                stats.recordOutbound(connection.statsKey, bytes: packet.totalLength, now: now)
                connection.handle(segment, bytes: packet.bytes, now: mono)
            } else if segment.flags & TCPFlags.syn != 0 && segment.flags & TCPFlags.ack == 0 {
                let statsKey = StatsKey(transport: "TCP", remoteAddress: packet.destination.string, remotePort: segment.dstPort)
                stats.recordOutbound(statsKey, bytes: packet.totalLength, now: now)
                guard segment.dstPort != 0, tcp.count < Self.maxTCPConnections else {
                    return   // dropped; the kernel retransmits the SYN
                }
                stats.recordConnection(statsKey, localAddress: packet.source.string, localPort: segment.srcPort, now: now)
                let connection = TCPConnection(key: key, statsKey: statsKey, version: packet.version,
                                               syn: segment, router: self, now: mono)
                tcp[key] = connection
                connection.start()
            } else if segment.flags & TCPFlags.rst == 0 {
                // A connection we know nothing about (for example one that predates this capture).
                sendResetForUnknownSegment(packet, segment)
            }
        case 17:
            guard let datagram = UDPDatagram.parse(packet) else {
                stats.recordUnsupported()
                return
            }
            guard datagram.dstPort != 0 else { return }
            let key = FlowKey(transport: 17, local: packet.source, localPort: datagram.srcPort,
                              remote: packet.destination, remotePort: datagram.dstPort)
            let session: UDPSession
            if let existing = udp[key] {
                session = existing
            } else {
                let statsKey = StatsKey(transport: "UDP", remoteAddress: packet.destination.string, remotePort: datagram.dstPort)
                stats.recordOutbound(statsKey, bytes: packet.totalLength, now: now)
                guard udp.count < Self.maxUDPSessions else { return }
                stats.recordConnection(statsKey, localAddress: packet.source.string, localPort: datagram.srcPort, now: now)
                session = UDPSession(key: key, statsKey: statsKey, version: packet.version, router: self, now: mono)
                udp[key] = session
                session.start()
                session.send(packet.bytes[datagram.payloadOffset ..< datagram.payloadOffset + datagram.payloadLength], now: mono)
                return
            }
            stats.recordOutbound(session.statsKey, bytes: packet.totalLength, now: now)
            session.send(packet.bytes[datagram.payloadOffset ..< datagram.payloadOffset + datagram.payloadLength], now: mono)
        default:
            stats.recordUnsupported()   // ICMP and friends cannot be relayed through a user-space tunnel
        }
    }

    /// RFC 9293 3.10.7.1: reply to a stray segment with a RST so the kernel gives up quickly.
    private func sendResetForUnknownSegment(_ packet: ParsedPacket, _ segment: TCPSegment) {
        let reset: Data
        if segment.flags & TCPFlags.ack != 0 {
            reset = PacketBuilder.tcp(version: packet.version,
                                      src: packet.destination, srcPort: segment.dstPort,
                                      dst: packet.source, dstPort: segment.srcPort,
                                      seq: segment.ack, ack: 0,
                                      flags: TCPFlags.rst, window: 0)
        } else {
            var ack = segment.seq &+ UInt32(segment.payloadLength)
            if segment.flags & TCPFlags.syn != 0 { ack = ack &+ 1 }
            if segment.flags & TCPFlags.fin != 0 { ack = ack &+ 1 }
            reset = PacketBuilder.tcp(version: packet.version,
                                      src: packet.destination, srcPort: segment.dstPort,
                                      dst: packet.source, dstPort: segment.srcPort,
                                      seq: 0, ack: ack,
                                      flags: TCPFlags.rst | TCPFlags.ack, window: 0)
        }
        writeRaw(reset, version: packet.version)
    }

    // MARK: - Packets to the kernel

    func write(packet: Data, version: IPVersion, statsKey: StatsKey) {
        writeRaw(packet, version: version)
        stats.recordInbound(statsKey, bytes: packet.count, now: Date())
    }

    private func writeRaw(_ packet: Data, version: IPVersion) {
        guard !stopped else { return }
        let family: Int32 = version == .v4 ? AF_INET : AF_INET6
        writePackets([packet], [NSNumber(value: family)])
    }

    // MARK: - Flow bookkeeping

    func tcpConnectionDidClose(_ key: FlowKey) {
        tcp.removeValue(forKey: key)
    }

    func udpSessionDidClose(_ key: FlowKey) {
        udp.removeValue(forKey: key)
    }

    private func tick() {
        guard !stopped else { return }
        let now = monotonicNow()
        for connection in Array(tcp.values) {
            connection.tick(now: now)
        }
        for session in Array(udp.values) {
            session.tick(now: now)
        }
        tickCount += 1
        if tickCount % Self.ticksPerFlush == 0 {
            stats.activeTCP = tcp.count
            stats.activeUDP = udp.count
            stats.flushIfNeeded(now: Date())
        }
    }

    private static func describe(_ path: NWPath) -> String {
        if path.usesInterfaceType(.wifi) { return "Wi-Fi" }
        if path.usesInterfaceType(.cellular) { return "Cellular" }
        if path.usesInterfaceType(.wiredEthernet) { return "Wired" }
        return path.status == .satisfied ? "Other" : "Offline"
    }
}
