import SwiftUI

/// Everything recorded about one host or endpoint: throughput over time, frequency, sources.
struct FlowDetailView: View {
    let reference: DestinationRef

    @EnvironmentObject private var store: TrafficStore
    @State private var range: TimeRange = .hour

    private var flows: [FlowStats] {
        guard let all = store.snapshot?.flows else { return [] }
        let ids = Set(reference.flowIDs)
        return all.filter { ids.contains($0.id) }.sorted { $0.totalBytes > $1.totalBytes }
    }

    var body: some View {
        List {
            if flows.isEmpty {
                ContentUnavailableView("No longer recorded", systemImage: "clock.arrow.circlepath")
            } else {
                throughputSection
                frequencySection
                volumeSection
                interfaceSection
                if flows.count > 1 {
                    endpointsSection
                }
                sourcesSection
            }
        }
        .navigationTitle(reference.title)
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private var throughputSection: some View {
        let window = range.window(endingAt: Date())
        let buckets = TrafficMath.rebucket(flows.map(\.buckets), seconds: range.bucketSeconds,
                                           start: window.start, end: window.end)
        Section("Throughput over time") {
            TimeRangePicker(range: $range)
            TrafficBarChart(buckets: buckets, bucketSeconds: range.bucketSeconds,
                            start: window.start, end: window.end)
                .frame(height: 200)
            ConnectionsChart(buckets: buckets, bucketSeconds: range.bucketSeconds,
                             start: window.start, end: window.end)
                .frame(height: 110)
        }
    }

    @ViewBuilder
    private var frequencySection: some View {
        let firstSeen = flows.map(\.firstSeen).min() ?? Date()
        let lastSeen = flows.map(\.lastSeen).max() ?? Date()
        let connections = flows.reduce(0) { $0 &+ $1.connections }
        let activeMinutes = Set(flows.flatMap { $0.buckets.map(\.start) }).count
        Section("Frequency") {
            LabeledContent("Connections opened", value: Format.count(connections))
            LabeledContent("Rate", value: Format.frequency(connections: connections, over: lastSeen.timeIntervalSince(firstSeen)))
            LabeledContent("Active minutes", value: Format.count(UInt64(activeMinutes)))
            LabeledContent("First seen", value: Format.dateTime(firstSeen))
            LabeledContent("Last seen", value: Format.relative(lastSeen))
            LabeledContent("Observed for", value: Format.duration(lastSeen.timeIntervalSince(firstSeen)))
        }
    }

    @ViewBuilder
    private var volumeSection: some View {
        let bytesIn = flows.reduce(0) { $0 &+ $1.bytesIn }
        let bytesOut = flows.reduce(0) { $0 &+ $1.bytesOut }
        let packetsIn = flows.reduce(0) { $0 &+ $1.packetsIn }
        let packetsOut = flows.reduce(0) { $0 &+ $1.packetsOut }
        Section("Volume") {
            LabeledContent("Received", value: Format.bytes(bytesIn))
            LabeledContent("Sent", value: Format.bytes(bytesOut))
            LabeledContent("Packets received", value: Format.count(packetsIn))
            LabeledContent("Packets sent", value: Format.count(packetsOut))
        }
    }

    @ViewBuilder
    private var interfaceSection: some View {
        let totals = FlowDetailView.interfaceTotals(flows)
        if !totals.isEmpty {
            Section("Network interface") {
                ForEach(totals, id: \.name) { item in
                    LabeledContent(item.name, value: Format.bytes(item.bytes))
                }
            }
        }
    }

    private var endpointsSection: some View {
        Section("Endpoints") {
            ForEach(flows) { flow in
                NavigationLink(value: DestinationRef(title: "\(flow.remoteAddress):\(flow.remotePort)", flowIDs: [flow.id])) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(flow.transport) port \(flow.remotePort)")
                            Text(flow.remoteAddress)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(Format.bytes(flow.totalBytes)).monospacedDigit()
                            Text("\(flow.connections) conn")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var sourcesSection: some View {
        let samples: [RecentConnection] = RecentConnection.collect(from: flows, limit: 30, useHostnames: false)
        Section {
            if samples.isEmpty {
                Text("No connection records yet.")
                    .foregroundStyle(.secondary)
            }
            ForEach(samples) { item in
                RecentConnectionRow(item: item, showDestination: flows.count > 1)
            }
        } header: {
            Text("Recent sources on this iPhone")
        } footer: {
            Text("iOS does not reveal which app opened a connection; the source is always this device's tunnel address and an ephemeral port.")
        }
    }

    static func interfaceTotals(_ flows: [FlowStats]) -> [(name: String, bytes: UInt64)] {
        var totals: [String: UInt64] = [:]
        for flow in flows {
            for (name, bytes) in flow.bytesByInterface {
                totals[name, default: 0] &+= bytes
            }
        }
        return totals.map { (name: $0.key, bytes: $0.value) }.sorted { $0.bytes > $1.bytes }
    }
}

struct RecentConnection: Identifiable {
    let id: String
    let source: String
    let destination: String
    let transport: String
    let interface: String
    let time: Date

    /// The most recent local sources across `flows`, newest first.
    static func collect(from flows: [FlowStats], limit: Int, useHostnames: Bool) -> [RecentConnection] {
        var items: [RecentConnection] = []
        for flow in flows {
            let destinationName = useHostnames ? (flow.hostname ?? flow.remoteAddress) : flow.remoteAddress
            for sample in flow.recentSources {
                items.append(RecentConnection(id: "\(flow.id)/\(sample.port)/\(sample.time.timeIntervalSince1970)",
                                              source: "\(sample.address):\(sample.port)",
                                              destination: "\(destinationName):\(flow.remotePort)",
                                              transport: flow.transport,
                                              interface: sample.interface,
                                              time: sample.time))
            }
        }
        items.sort { $0.time > $1.time }
        if items.count > limit {
            items.removeLast(items.count - limit)
        }
        return items
    }
}

struct RecentConnectionRow: View {
    let item: RecentConnection
    var showDestination = true

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(item.source)
                    .font(.body.monospacedDigit())
                if showDestination {
                    Image(systemName: "arrow.right")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(item.destination)
                        .font(.body.monospacedDigit())
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Text("\(item.transport) · \(item.interface) · \(Format.relative(item.time))")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
