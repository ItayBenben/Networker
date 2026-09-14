import Foundation

enum TimeRange: String, CaseIterable, Identifiable {
    case hour = "1h"
    case sixHours = "6h"
    case day = "24h"

    var id: String { rawValue }

    var seconds: TimeInterval {
        switch self {
        case .hour: return 3600
        case .sixHours: return 6 * 3600
        case .day: return 24 * 3600
        }
    }

    /// Chart resolution for this range (60, 72 or 96 bars).
    var bucketSeconds: TimeInterval {
        switch self {
        case .hour: return 60
        case .sixHours: return 5 * 60
        case .day: return 15 * 60
        }
    }
}

enum TrafficMath {
    /// Merges 60 s buckets from one or more series into coarser buckets covering [start, end).
    static func rebucket(_ series: [[TrafficBucket]], seconds: TimeInterval, start: Date, end: Date) -> [TrafficBucket] {
        var merged: [Date: TrafficBucket] = [:]
        for buckets in series {
            for bucket in buckets where bucket.start >= start && bucket.start < end {
                let key = Date(timeIntervalSince1970: (bucket.start.timeIntervalSince1970 / seconds).rounded(.down) * seconds)
                var aggregate = merged[key] ?? TrafficBucket(start: key)
                aggregate.bytesIn &+= bucket.bytesIn
                aggregate.bytesOut &+= bucket.bytesOut
                aggregate.packetsIn &+= bucket.packetsIn
                aggregate.packetsOut &+= bucket.packetsOut
                aggregate.connections &+= bucket.connections
                merged[key] = aggregate
            }
        }
        return merged.values.sorted { $0.start < $1.start }
    }

    /// Average bytes per second over the most recent `seconds` of 1 s live buckets.
    static func currentRate(_ live: [TrafficBucket], seconds: Int, now: Date) -> (inbound: Double, outbound: Double) {
        let cutoff = now.addingTimeInterval(-Double(seconds))
        var inbound: UInt64 = 0
        var outbound: UInt64 = 0
        for bucket in live where bucket.start >= cutoff {
            inbound &+= bucket.bytesIn
            outbound &+= bucket.bytesOut
        }
        return (Double(inbound) / Double(seconds), Double(outbound) / Double(seconds))
    }

    /// Fills gaps in the live series with zero buckets so the graph drops to zero when idle.
    static func denseLive(_ live: [TrafficBucket], seconds: Int, now: Date) -> [TrafficBucket] {
        let end = Date(timeIntervalSince1970: now.timeIntervalSince1970.rounded(.down))
        var byStart: [Date: TrafficBucket] = [:]
        for bucket in live {
            byStart[bucket.start] = bucket
        }
        var result: [TrafficBucket] = []
        result.reserveCapacity(seconds)
        for offset in stride(from: seconds - 1, through: 0, by: -1) {
            let start = end.addingTimeInterval(-Double(offset))
            result.append(byStart[start] ?? TrafficBucket(start: start))
        }
        return result
    }
}
