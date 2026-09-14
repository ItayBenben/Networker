import Foundation
import Network

/// A user-space TCP endpoint that terminates one connection coming from the kernel through the
/// tunnel and relays it to the real destination over a regular `NWConnection`.
///
/// The kernel side is a lossless, in-order, near-zero-latency link, so this implementation keeps
/// the protocol machinery deliberately small: no SACK, no window scaling, no timestamps,
/// go-back-N style retransmission with a conservative timer, and a 64 KiB receive window.
final class TCPConnection {
    enum State {
        case connecting    // SYN received, waiting for the remote side to accept
        case synAckSent    // SYN-ACK sent, waiting for the kernel's ACK
        case established
        case closed
    }

    let key: FlowKey
    let statsKey: StatsKey
    let version: IPVersion
    private unowned let router: PacketRouter
    private var connection: NWConnection?
    private(set) var state: State = .connecting

    // Sequence space. All arithmetic is wrapping.
    private var rcvNxt: UInt32          // next byte expected from the kernel
    private let iss: UInt32             // our initial sequence number
    private var sndUna: UInt32          // oldest byte sent to the kernel that is not yet acknowledged
    private var sndNxt: UInt32          // next byte to send to the kernel
    private var peerWindow: UInt32      // receive window advertised by the kernel
    private let mss: Int                // largest payload we send to the kernel
    private let ourMSS: UInt16          // MSS we advertise to the kernel

    private var unacked = ByteQueue()    // sent to the kernel, not yet acknowledged; starts at sndUna
    private var pendingOut = ByteQueue() // received from the remote host, not yet sent to the kernel
    private var inflightToRemote = 0     // bytes handed to NWConnection.send that are not yet processed
    private var remoteEOF = false
    private var remoteHalfClosed = false
    private var finSent = false
    private var finAcked = false
    private var finSeq: UInt32 = 0
    private var clientFinReceived = false
    private var receiveActive = false
    private var receivePaused = false

    private let createdAt: TimeInterval
    private var lastActivity: TimeInterval
    private var lastSendTime: TimeInterval
    private var rto: TimeInterval = 1.0
    private var retransmits = 0
    private var lastAdvertisedWindow: UInt16 = 0xffff

    private static let maxInflightToClient = 256 * 1024
    private static let receiveHighWater = 192 * 1024
    private static let receiveLowWater = 64 * 1024
    private static let maxRetransmits = 8
    private static let maxRTO: TimeInterval = 8
    private static let connectTimeout: TimeInterval = 40
    private static let idleTimeout: TimeInterval = 2 * 60 * 60
    private static let finWaitTimeout: TimeInterval = 60

    init(key: FlowKey, statsKey: StatsKey, version: IPVersion, syn: TCPSegment, router: PacketRouter, now: TimeInterval) {
        self.key = key
        self.statsKey = statsKey
        self.version = version
        self.router = router
        rcvNxt = syn.seq &+ 1
        iss = UInt32.random(in: 0 ... UInt32.max)
        sndUna = iss
        sndNxt = iss
        peerWindow = UInt32(syn.window)
        ourMSS = version == .v4 ? 1460 : 1440
        let peerMSS = syn.mss ?? (version == .v4 ? 536 : 1220)
        mss = Int(min(peerMSS, ourMSS))
        createdAt = now
        lastActivity = now
        lastSendTime = now
    }

    // MARK: - Lifecycle

    func start() {
        guard let endpoint = key.remoteEndpoint else {
            abort(reset: true)
            return
        }
        let parameters = NWParameters.tcp
        if let tcpOptions = parameters.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
            tcpOptions.connectionTimeout = 30
            tcpOptions.noDelay = true
        }
        let connection = NWConnection(to: endpoint, using: parameters)
        self.connection = connection
        connection.stateUpdateHandler = { [weak self] newState in
            self?.connectionStateChanged(newState)
        }
        connection.start(queue: router.queue)
    }

    private func connectionStateChanged(_ newState: NWConnection.State) {
        guard state != .closed else { return }
        switch newState {
        case .ready:
            if state == .connecting {
                sendSynAck(now: monotonicNow())
                state = .synAckSent
                startReceive()
            }
        case .waiting, .failed:
            // Unreachable, refused, timed out or the path went away: reset the kernel side.
            abort(reset: true)
        case .cancelled:
            close()
        default:
            break
        }
    }

    /// Sends a RST to the kernel (if requested) and tears the connection down.
    func abort(reset: Bool) {
        if reset && state != .closed {
            sendSegment(flags: TCPFlags.rst | TCPFlags.ack, seq: sndNxt)
        }
        close()
    }

    func close() {
        guard state != .closed else { return }
        state = .closed
        let connection = self.connection
        self.connection = nil
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        pendingOut.removeAll()
        unacked.removeAll()
        router.tcpConnectionDidClose(key)
    }

    // MARK: - Segments from the kernel

    func handle(_ segment: TCPSegment, bytes: [UInt8], now: TimeInterval) {
        guard state != .closed else { return }
        lastActivity = now

        if segment.flags & TCPFlags.rst != 0 {
            close()
            return
        }

        switch state {
        case .connecting:
            // The kernel is retransmitting its SYN while we wait for the remote host. Reply later.
            return
        case .synAckSent:
            if segment.flags & TCPFlags.syn != 0 {
                sendSynAck(now: now)   // retransmitted SYN: repeat our SYN-ACK
                return
            }
            guard segment.flags & TCPFlags.ack != 0 else { return }
            guard segment.ack == iss &+ 1 else {
                // RFC 9293 3.10.7.4: an unacceptable ACK in SYN-RECEIVED gets <SEQ=SEG.ACK><CTL=RST>.
                sendSegment(flags: TCPFlags.rst, seq: segment.ack)
                close()
                return
            }
            state = .established
        case .established:
            if segment.flags & TCPFlags.syn != 0 {
                sendAck()
                return
            }
        case .closed:
            return
        }

        guard segment.flags & TCPFlags.ack != 0 else { return }
        processAck(segment, now: now)
        processData(segment, bytes: bytes)
        guard state != .closed else { return }
        flushToClient(now: now)
        checkFullyClosed()
    }

    private func processAck(_ segment: TCPSegment, now: TimeInterval) {
        let ack = segment.ack
        // Acceptable: SND.UNA <= SEG.ACK <= SND.NXT
        guard seqLessOrEqual(sndUna, ack), seqLessOrEqual(ack, sndNxt) else { return }
        let ackedBytes = Int(ack &- sndUna)
        if ackedBytes > 0 {
            unacked.removeFirst(min(ackedBytes, unacked.count))   // the FIN occupies one sequence number but no buffer byte
            sndUna = ack
            rto = 1
            retransmits = 0
            lastSendTime = now
            if finSent && !finAcked && ack == finSeq &+ 1 {
                finAcked = true
            }
        }
        peerWindow = UInt32(segment.window)
        resumeReceiveIfNeeded()
    }

    private func processData(_ segment: TCPSegment, bytes: [UInt8]) {
        let length = segment.payloadLength
        var newData: ArraySlice<UInt8>? = nil
        if length > 0 {
            if segment.seq == rcvNxt {
                newData = bytes[segment.payloadOffset ..< segment.payloadOffset + length]
            } else if seqLessThan(segment.seq, rcvNxt) {
                // Partly or wholly retransmitted data: keep only the part we have not seen.
                let skip = Int(rcvNxt &- segment.seq)
                if skip < length {
                    newData = bytes[(segment.payloadOffset + skip) ..< (segment.payloadOffset + length)]
                }
            } else {
                // A gap: cannot happen on a lossless link, but the kernel would retransmit anyway.
                sendAck()
                return
            }
        }

        if let data = newData, !data.isEmpty {
            rcvNxt = rcvNxt &+ UInt32(data.count)
            forwardToRemote(Array(data))
        }

        if segment.flags & TCPFlags.fin != 0 {
            let finSequence = segment.seq &+ UInt32(length)
            if finSequence == rcvNxt && !clientFinReceived {
                rcvNxt = rcvNxt &+ 1
                clientFinReceived = true
                halfCloseRemote()
            }
            sendAck()   // acknowledges the FIN, or re-acknowledges a retransmitted one
            return
        }

        if length > 0 {
            sendAck()
        }
    }

    // MARK: - Relay towards the remote host

    private func forwardToRemote(_ data: [UInt8]) {
        guard let connection, !remoteHalfClosed else { return }
        let count = data.count
        inflightToRemote += count
        connection.send(content: Data(data), completion: .contentProcessed { [weak self] error in
            guard let self, self.state != .closed else { return }
            self.inflightToRemote -= count
            if error != nil {
                self.abort(reset: true)
                return
            }
            self.maybeSendWindowUpdate()
        })
    }

    private func halfCloseRemote() {
        guard let connection, !remoteHalfClosed else { return }
        remoteHalfClosed = true
        connection.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in })
    }

    private func advertisedWindow() -> UInt16 {
        UInt16(clamping: 65535 - inflightToRemote)
    }

    private func maybeSendWindowUpdate() {
        guard state == .established else { return }
        let window = advertisedWindow()
        if lastAdvertisedWindow < 16384 && window >= 32768 {
            sendAck()
        }
    }

    // MARK: - Relay towards the kernel

    private func startReceive() {
        guard let connection, !receiveActive, !remoteEOF, state != .closed else { return }
        if pendingOut.count + unacked.count >= Self.receiveHighWater {
            receivePaused = true
            return
        }
        receivePaused = false
        receiveActive = true
        connection.receive(minimumIncompleteLength: 1, maximumLength: 32768) { [weak self] content, _, isComplete, error in
            guard let self else { return }
            self.receiveActive = false
            guard self.state != .closed else { return }
            if error != nil {
                // Connection reset or similar: propagate as a reset to the kernel.
                self.abort(reset: true)
                return
            }
            if let content, !content.isEmpty {
                self.pendingOut.append(content)
            }
            if isComplete {
                self.remoteEOF = true
            }
            let now = monotonicNow()
            self.lastActivity = now
            self.flushToClient(now: now)
            self.checkFullyClosed()
            if self.state != .closed && !self.remoteEOF {
                self.startReceive()
            }
        }
    }

    private func resumeReceiveIfNeeded() {
        if receivePaused && pendingOut.count + unacked.count < Self.receiveLowWater {
            startReceive()
        }
    }

    /// Sends as much buffered remote data to the kernel as its window allows, then the FIN if due.
    private func flushToClient(now: TimeInterval) {
        guard state == .established else { return }
        while !pendingOut.isEmpty {
            let inflight = Int(sndNxt &- sndUna)
            let room = min(Int(peerWindow) - inflight, Self.maxInflightToClient - inflight)
            let length = min(pendingOut.count, mss, room)
            if length <= 0 { break }
            let chunk = Array(pendingOut.prefix(length))
            pendingOut.removeFirst(length)
            let push: UInt8 = pendingOut.isEmpty ? TCPFlags.psh : 0
            if unacked.isEmpty {
                lastSendTime = now
            }
            sendSegment(flags: TCPFlags.ack | push, seq: sndNxt, payload: chunk[...])
            unacked.append(chunk)
            sndNxt = sndNxt &+ UInt32(length)
        }
        if pendingOut.isEmpty && remoteEOF && !finSent {
            finSeq = sndNxt
            if unacked.isEmpty {
                lastSendTime = now
            }
            sendSegment(flags: TCPFlags.fin | TCPFlags.ack, seq: sndNxt)
            sndNxt = sndNxt &+ 1
            finSent = true
        }
        resumeReceiveIfNeeded()
    }

    private func checkFullyClosed() {
        if state == .established && clientFinReceived && finAcked {
            close()
        }
    }

    // MARK: - Timers

    func tick(now: TimeInterval) {
        switch state {
        case .closed:
            return
        case .connecting:
            if now - createdAt > Self.connectTimeout {
                abort(reset: true)
            }
        case .synAckSent:
            if now - lastSendTime > rto {
                retransmits += 1
                if retransmits > Self.maxRetransmits {
                    abort(reset: true)
                    return
                }
                rto = min(rto * 2, Self.maxRTO)
                sendSynAck(now: now)
            }
        case .established:
            if !unacked.isEmpty || (finSent && !finAcked) {
                if now - lastSendTime > rto {
                    retransmit(now: now)
                }
            } else if peerWindow == 0 && !pendingOut.isEmpty && now - lastSendTime > 1.0 {
                sendZeroWindowProbe(now: now)
            }
            guard state != .closed else { return }
            if finAcked && !clientFinReceived && now - lastActivity > Self.finWaitTimeout {
                close()   // the app never closed its socket; equivalent to a FIN-WAIT-2 timeout
                return
            }
            if now - lastActivity > Self.idleTimeout {
                abort(reset: true)
            }
        }
    }

    private func retransmit(now: TimeInterval) {
        if peerWindow > 0 {
            retransmits += 1
            if retransmits > Self.maxRetransmits {
                abort(reset: true)
                return
            }
        }
        rto = min(rto * 2, Self.maxRTO)
        lastSendTime = now
        if !unacked.isEmpty {
            let chunk = Array(unacked.prefix(min(mss, unacked.count)))
            sendSegment(flags: TCPFlags.ack | TCPFlags.psh, seq: sndUna, payload: chunk[...])
        } else if finSent && !finAcked {
            sendSegment(flags: TCPFlags.fin | TCPFlags.ack, seq: finSeq)
        }
    }

    /// With a zero window the kernel will not accept data; send one byte so it answers with its
    /// current window (the retransmission timer repeats the probe until the window opens).
    private func sendZeroWindowProbe(now: TimeInterval) {
        let chunk = Array(pendingOut.prefix(1))
        pendingOut.removeFirst(1)
        lastSendTime = now
        sendSegment(flags: TCPFlags.ack | TCPFlags.psh, seq: sndNxt, payload: chunk[...])
        unacked.append(chunk)
        sndNxt = sndNxt &+ 1
    }

    // MARK: - Segment output

    private func sendSynAck(now: TimeInterval) {
        let options: [UInt8] = [2, 4, UInt8(truncatingIfNeeded: ourMSS >> 8), UInt8(truncatingIfNeeded: ourMSS)]
        lastSendTime = now
        sendSegment(flags: TCPFlags.syn | TCPFlags.ack, seq: iss, options: options)
        sndNxt = iss &+ 1
    }

    private func sendAck() {
        sendSegment(flags: TCPFlags.ack, seq: sndNxt)
    }

    private func sendSegment(flags: UInt8, seq: UInt32, options: [UInt8] = [], payload: ArraySlice<UInt8> = []) {
        let window = advertisedWindow()
        lastAdvertisedWindow = window
        let packet = PacketBuilder.tcp(version: version,
                                       src: key.remote, srcPort: key.remotePort,
                                       dst: key.local, dstPort: key.localPort,
                                       seq: seq, ack: rcvNxt,
                                       flags: flags, window: window,
                                       options: options, payload: payload)
        router.write(packet: packet, version: version, statsKey: statsKey)
    }
}
