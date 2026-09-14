import Foundation

/// Aggregates per-destination and whole-device traffic statistics and periodically publishes them
/// to the App Group container for the app to read. All methods must be called on the tunnel queue.
final class StatsCollector {
    private let queue: DispatchQueue
    private let writeQueue = DispatchQueue(label: "networker.snapshot-writer", qos: .utility)
    private var flows: [String: FlowStats] = [:]
    private var dnsMap: [String: String] = [:]
    private var base: TrafficSnapshot
    private var dirty = true
    private var writeInFlight = false
    private var flushCount = 0
    private var totalFlowBuckets = 0

    var activeTCP = 0
    var activeUDP = 0

    var currentInterface: String {
        get { base.currentInterface }
        set {
            if base.currentInterface != newValue {
                base.currentInterface = newValue
                dirty = true
            }
        }
    }

    init(previous: TrafficSnapshot?, queue: DispatchQueue, now: Date,
         localIPv4: String?, localIPv6: String?, dnsServers: [String]) {
        self.queue = queue
        var snapshot = previous ?? TrafficSnapshot(generatedAt: now, isCapturing: true)
        snapshot.version = TrafficConstants.snapshotVersion
        snapshot.captureStartedAt = now
        snapshot.isCapturing = true
        snapshot.localIPv4 = localIPv4
        snapshot.localIPv6 = localIPv6
        snapshot.dnsServers = dnsServers
        snapshot.liveBuckets = []
        for flow in snapshot.flows {
            flows[flow.id] = flow
            totalFlowBuckets += flow.buckets.count
            if let hostname = flow.hostname {
                dnsMap[flow.remoteAddress] = hostname
            }
        }
        snapshot.flows = []
        base = snapshot
        pruneStaleFlows(now: now)
    }

    // MARK: - Recording

    func recordOutbound(_ key: StatsKey, bytes: Int, now: Date) {
        let count = UInt64(bytes)
        base.totalPacketsOut &+= 1
        base.totalBytesOut &+= count
        Self.touchBucket(&base.historyBuckets, now: now,
                         size: TrafficConstants.historyBucketSeconds,
                         retention: TrafficConstants.historyRetentionSeconds) { bucket in
            bucket.packetsOut &+= 1
            bucket.bytesOut &+= count
        }
        Self.touchBucket(&base.liveBuckets, now: now,
                         size: TrafficConstants.liveBucketSeconds,
                         retention: TrafficConstants.liveRetentionSeconds) { bucket in
            bucket.packetsOut &+= 1
            bucket.bytesOut &+= count
        }
        let interface = base.currentInterface
        withFlow(key, now: now) { flow in
            flow.lastSeen = now
            flow.packetsOut &+= 1
            flow.bytesOut &+= count
            flow.bytesByInterface[interface, default: 0] &+= count
            self.touchFlowBucket(&flow.buckets, now: now) { bucket in
                bucket.packetsOut &+= 1
                bucket.bytesOut &+= count
            }
        }
    }

    func recordInbound(_ key: StatsKey, bytes: Int, now: Date) {
        let count = UInt64(bytes)
        base.totalPacketsIn &+= 1
        base.totalBytesIn &+= count
        Self.touchBucket(&base.historyBuckets, now: now,
                         size: TrafficConstants.historyBucketSeconds,
                         retention: TrafficConstants.historyRetentionSeconds) { bucket in
            bucket.packetsIn &+= 1
            bucket.bytesIn &+= count
        }
        Self.touchBucket(&base.liveBuckets, now: now,
                         size: TrafficConstants.liveBucketSeconds,
                         retention: TrafficConstants.liveRetentionSeconds) { bucket in
            bucket.packetsIn &+= 1
            bucket.bytesIn &+= count
        }
        let interface = base.currentInterface
        withFlow(key, now: now) { flow in
            flow.lastSeen = now
            flow.packetsIn &+= 1
            flow.bytesIn &+= count
            flow.bytesByInterface[interface, default: 0] &+= count
            self.touchFlowBucket(&flow.buckets, now: now) { bucket in
                bucket.packetsIn &+= 1
                bucket.bytesIn &+= count
            }
        }
    }

    /// A new TCP connection or UDP session was opened by the device.
    func recordConnection(_ key: StatsKey, localAddress: String, localPort: UInt16, now: Date) {
        base.totalConnections &+= 1
        Self.touchBucket(&base.historyBuckets, now: now,
                         size: TrafficConstants.historyBucketSeconds,
                         retention: TrafficConstants.historyRetentionSeconds) { bucket in
            bucket.connections &+= 1
        }
        let interface = base.currentInterface
        withFlow(key, now: now) { flow in
            flow.lastSeen = now
            flow.connections &+= 1
            flow.recentSources.append(SourceSample(address: localAddress, port: localPort, interface: interface, time: now))
            if flow.recentSources.count > TrafficConstants.maxRecentSources {
                flow.recentSources.removeFirst(flow.recentSources.count - TrafficConstants.maxRecentSources)
            }
            self.touchFlowBucket(&flow.buckets, now: now) { bucket in
                bucket.connections &+= 1
            }
        }
    }

    func recordUnsupported() {
        base.unsupportedPackets &+= 1
        dirty = true
    }

    func recordDNSResponse(_ message: [UInt8]) {
        let records = DNSParser.parseResponse(message)
        guard !records.isEmpty else { return }
        if dnsMap.count > 20_000 {
            dnsMap.removeAll(keepingCapacity: true)
        }
        for record in records {
            dnsMap[record.address] = record.name
        }
    }

    func reset(now: Date) {
        flows = [:]
        dnsMap = [:]
        totalFlowBuckets = 0
        var snapshot = TrafficSnapshot(generatedAt: now, isCapturing: true)
        snapshot.captureStartedAt = now
        snapshot.currentInterface = base.currentInterface
        snapshot.localIPv4 = base.localIPv4
        snapshot.localIPv6 = base.localIPv6
        snapshot.dnsServers = base.dnsServers
        base = snapshot
        dirty = true
    }

    // MARK: - Publishing

    /// Writes the snapshot asynchronously if anything changed since the last write.
    func flushIfNeeded(now: Date) {
        guard dirty, !writeInFlight else { return }
        flushCount += 1
        if flushCount % 20 == 0 {
            pruneStaleFlows(now: now)
        }
        let snapshot = makeSnapshot(now: now, isCapturing: true)
        dirty = false
        writeInFlight = true
        writeQueue.async { [weak self] in
            Self.write(snapshot)
            self?.queue.async {
                self?.writeInFlight = false
            }
        }
    }

    /// Writes the snapshot before returning. Used when the tunnel stops or the device sleeps.
    func flushSync(now: Date, isCapturing: Bool) {
        let snapshot = makeSnapshot(now: now, isCapturing: isCapturing)
        dirty = false
        writeQueue.sync {
            Self.write(snapshot)
        }
    }

    private static func write(_ snapshot: TrafficSnapshot) {
        do {
            let data = try SnapshotStore.encode(snapshot)
            try SnapshotStore.save(data)
        } catch {
            NSLog("Networker: failed to write traffic snapshot: \(error)")
        }
    }

    private func makeSnapshot(now: Date, isCapturing: Bool) -> TrafficSnapshot {
        var snapshot = base
        snapshot.generatedAt = now
        snapshot.isCapturing = isCapturing
        snapshot.activeTCPConnections = activeTCP
        snapshot.activeUDPSessions = activeUDP
        snapshot.flows = Array(flows.values)
        return snapshot
    }

    // MARK: - Helpers

    private func withFlow(_ key: StatsKey, now: Date, _ body: (inout FlowStats) -> Void) {
        let id = key.id
        if flows[id] == nil {
            if flows.count >= TrafficConstants.maxFlows {
                evictOldestFlow()
            }
            flows[id] = FlowStats(transport: key.transport,
                                  remoteAddress: key.remoteAddress,
                                  remotePort: key.remotePort,
                                  hostname: dnsMap[key.remoteAddress],
                                  firstSeen: now,
                                  lastSeen: now)
        } else if flows[id]?.hostname == nil, let hostname = dnsMap[key.remoteAddress] {
            flows[id]?.hostname = hostname
        }
        body(&flows[id]!)
        dirty = true
        // Enforced here rather than inside `body`, which holds an exclusive borrow of `flows`.
        var guardCount = 0
        while totalFlowBuckets > TrafficConstants.maxTotalFlowBuckets && flows.count > 1 && guardCount < 64 {
            evictOldestFlow()
            guardCount += 1
        }
    }

    private func evictOldestFlow() {
        guard let oldest = flows.min(by: { $0.value.lastSeen < $1.value.lastSeen }) else { return }
        totalFlowBuckets -= oldest.value.buckets.count
        flows.removeValue(forKey: oldest.key)
    }

    /// Like `touchBucket` but also enforces the per-flow cap and tracks the global bucket count.
    private func touchFlowBucket(_ buckets: inout [TrafficBucket], now: Date, _ update: (inout TrafficBucket) -> Void) {
        let before = buckets.count
        Self.touchBucket(&buckets, now: now,
                         size: TrafficConstants.historyBucketSeconds,
                         retention: TrafficConstants.historyRetentionSeconds, update)
        if buckets.count > TrafficConstants.maxBucketsPerFlow {
            buckets.removeFirst(buckets.count - TrafficConstants.maxBucketsPerFlow)
        }
        totalFlowBuckets += buckets.count - before
    }

    /// Drops flows and buckets older than the retention window.
    private func pruneStaleFlows(now: Date) {
        let cutoff = now.addingTimeInterval(-TrafficConstants.historyRetentionSeconds)
        for (id, flow) in flows {
            if flow.lastSeen < cutoff {
                flows.removeValue(forKey: id)
            } else if let first = flow.buckets.first, first.start < cutoff {
                flows[id]?.buckets.removeAll { $0.start < cutoff }
            }
        }
        totalFlowBuckets = flows.values.reduce(0) { $0 + $1.buckets.count }
        if let first = base.historyBuckets.first, first.start < cutoff {
            base.historyBuckets.removeAll { $0.start < cutoff }
        }
        dirty = true
    }

    private static func bucketStart(_ now: Date, size: TimeInterval) -> Date {
        Date(timeIntervalSince1970: (now.timeIntervalSince1970 / size).rounded(.down) * size)
    }

    private static func touchBucket(_ buckets: inout [TrafficBucket], now: Date, size: TimeInterval,
                                    retention: TimeInterval, _ update: (inout TrafficBucket) -> Void) {
        let start = bucketStart(now, size: size)
        if let last = buckets.last, last.start >= start {
            // Same bucket, or the clock moved backwards: fold into the latest bucket.
            update(&buckets[buckets.count - 1])
            return
        }
        buckets.append(TrafficBucket(start: start))
        update(&buckets[buckets.count - 1])
        let cutoff = now.addingTimeInterval(-retention)
        if let first = buckets.first, first.start < cutoff {
            buckets.removeAll { $0.start < cutoff }
        }
    }
}
