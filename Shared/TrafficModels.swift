import Foundation

enum TrafficConstants {
    /// Resolution of the per-destination and 24 h history.
    static let historyBucketSeconds: TimeInterval = 60
    static let historyRetentionSeconds: TimeInterval = 24 * 60 * 60
    /// Resolution of the live throughput graph.
    static let liveBucketSeconds: TimeInterval = 1
    static let liveRetentionSeconds: TimeInterval = 120
    static let maxFlows = 2000
    /// Per-destination history is capped to bound the extension's memory (12 h of continuous activity).
    static let maxBucketsPerFlow = 720
    /// Upper bound on buckets across all destinations; the least recently seen flows are evicted first.
    static let maxTotalFlowBuckets = 50_000
    static let maxRecentSources = 12
    static let snapshotVersion = 1
}

/// Traffic counters for one time slice.
///
/// Encoded as a compact JSON array `[start, bytesOut, bytesIn, packetsOut, packetsIn, connections]`
/// because a snapshot can hold tens of thousands of buckets.
struct TrafficBucket: Codable, Hashable {
    var start: Date
    var bytesOut: UInt64 = 0
    var bytesIn: UInt64 = 0
    var packetsOut: UInt64 = 0
    var packetsIn: UInt64 = 0
    var connections: UInt64 = 0

    var totalBytes: UInt64 { bytesOut &+ bytesIn }

    init(start: Date, bytesOut: UInt64 = 0, bytesIn: UInt64 = 0,
         packetsOut: UInt64 = 0, packetsIn: UInt64 = 0, connections: UInt64 = 0) {
        self.start = start
        self.bytesOut = bytesOut
        self.bytesIn = bytesIn
        self.packetsOut = packetsOut
        self.packetsIn = packetsIn
        self.connections = connections
    }

    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        start = Date(timeIntervalSince1970: try container.decode(Double.self))
        bytesOut = try container.decode(UInt64.self)
        bytesIn = try container.decode(UInt64.self)
        packetsOut = try container.decode(UInt64.self)
        packetsIn = try container.decode(UInt64.self)
        connections = try container.decode(UInt64.self)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.unkeyedContainer()
        try container.encode(start.timeIntervalSince1970)
        try container.encode(bytesOut)
        try container.encode(bytesIn)
        try container.encode(packetsOut)
        try container.encode(packetsIn)
        try container.encode(connections)
    }
}

/// A local (on-device) source that opened a connection or UDP session.
struct SourceSample: Codable, Hashable {
    var address: String
    var port: UInt16
    var interface: String
    var time: Date
}

/// Everything recorded about one destination endpoint (transport + address + port).
struct FlowStats: Codable, Identifiable, Hashable {
    var transport: String            // "TCP" or "UDP"
    var remoteAddress: String
    var remotePort: UInt16
    var hostname: String?
    var firstSeen: Date
    var lastSeen: Date
    var connections: UInt64 = 0
    var packetsOut: UInt64 = 0
    var packetsIn: UInt64 = 0
    var bytesOut: UInt64 = 0
    var bytesIn: UInt64 = 0
    var bytesByInterface: [String: UInt64] = [:]
    var recentSources: [SourceSample] = []
    var buckets: [TrafficBucket] = []

    var id: String {
        FlowStats.makeID(transport: transport, remoteAddress: remoteAddress, remotePort: remotePort)
    }

    static func makeID(transport: String, remoteAddress: String, remotePort: UInt16) -> String {
        "\(transport)/\(remoteAddress)/\(remotePort)"
    }

    var totalBytes: UInt64 { bytesOut &+ bytesIn }
    var totalPackets: UInt64 { packetsOut &+ packetsIn }
}

/// The document the tunnel extension writes to the App Group container and the app reads.
struct TrafficSnapshot: Codable {
    var version: Int
    var generatedAt: Date
    var captureStartedAt: Date?
    var isCapturing: Bool
    var currentInterface: String
    var localIPv4: String?
    var localIPv6: String?
    var dnsServers: [String]
    var activeTCPConnections: Int
    var activeUDPSessions: Int
    var totalPacketsOut: UInt64
    var totalPacketsIn: UInt64
    var totalBytesOut: UInt64
    var totalBytesIn: UInt64
    var totalConnections: UInt64
    var unsupportedPackets: UInt64
    var flows: [FlowStats]
    var historyBuckets: [TrafficBucket]   // whole-device, 60 s resolution, last 24 h
    var liveBuckets: [TrafficBucket]      // whole-device, 1 s resolution, last 2 min

    init(generatedAt: Date, isCapturing: Bool) {
        version = TrafficConstants.snapshotVersion
        self.generatedAt = generatedAt
        captureStartedAt = nil
        self.isCapturing = isCapturing
        currentInterface = "Unknown"
        localIPv4 = nil
        localIPv6 = nil
        dnsServers = []
        activeTCPConnections = 0
        activeUDPSessions = 0
        totalPacketsOut = 0
        totalPacketsIn = 0
        totalBytesOut = 0
        totalBytesIn = 0
        totalConnections = 0
        unsupportedPackets = 0
        flows = []
        historyBuckets = []
        liveBuckets = []
    }

    var totalBytes: UInt64 { totalBytesOut &+ totalBytesIn }
}
