import Foundation
import Network

/// Relays one UDP "flow" (same local and remote address/port) to the real destination.
final class UDPSession {
    let key: FlowKey
    let statsKey: StatsKey
    let version: IPVersion
    private unowned let router: PacketRouter
    private var connection: NWConnection?
    private var ready = false
    private var closed = false
    private var queued: [Data] = []
    private(set) var lastActivity: TimeInterval
    private let isDNS: Bool

    private static let idleTimeout: TimeInterval = 90
    private static let dnsIdleTimeout: TimeInterval = 20
    private static let maxQueued = 64

    init(key: FlowKey, statsKey: StatsKey, version: IPVersion, router: PacketRouter, now: TimeInterval) {
        self.key = key
        self.statsKey = statsKey
        self.version = version
        self.router = router
        lastActivity = now
        isDNS = key.remotePort == 53
    }

    func start() {
        guard let endpoint = key.remoteEndpoint else {
            close()
            return
        }
        let connection = NWConnection(to: endpoint, using: .udp)
        self.connection = connection
        connection.stateUpdateHandler = { [weak self] newState in
            guard let self, !self.closed else { return }
            switch newState {
            case .ready:
                self.ready = true
                let pending = self.queued
                self.queued = []
                for datagram in pending {
                    self.transmit(datagram)
                }
                self.receive()
            case .waiting, .failed, .cancelled:
                self.close()
            default:
                break
            }
        }
        connection.start(queue: router.queue)
    }

    func send(_ payload: ArraySlice<UInt8>, now: TimeInterval) {
        guard !closed else { return }
        lastActivity = now
        let datagram = Data(payload)
        if ready {
            transmit(datagram)
        } else if queued.count < Self.maxQueued {
            queued.append(datagram)
        }
    }

    private func transmit(_ datagram: Data) {
        connection?.send(content: datagram, completion: .contentProcessed { [weak self] error in
            if error != nil {
                self?.close()
            }
        })
    }

    private func receive() {
        guard let connection, !closed else { return }
        connection.receiveMessage { [weak self] content, _, _, error in
            guard let self, !self.closed else { return }
            if error != nil {
                self.close()
                return
            }
            if let content, !content.isEmpty {
                let bytes = [UInt8](content)
                self.lastActivity = monotonicNow()
                if self.isDNS {
                    self.router.stats.recordDNSResponse(bytes)
                }
                let packet = PacketBuilder.udp(version: self.version,
                                               src: self.key.remote, srcPort: self.key.remotePort,
                                               dst: self.key.local, dstPort: self.key.localPort,
                                               payload: bytes[...])
                self.router.write(packet: packet, version: self.version, statsKey: self.statsKey)
            }
            self.receive()
        }
    }

    func tick(now: TimeInterval) {
        let timeout = isDNS ? Self.dnsIdleTimeout : Self.idleTimeout
        if now - lastActivity > timeout {
            close()
        }
    }

    func close() {
        guard !closed else { return }
        closed = true
        let connection = self.connection
        self.connection = nil
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        queued = []
        router.udpSessionDidClose(key)
    }
}
