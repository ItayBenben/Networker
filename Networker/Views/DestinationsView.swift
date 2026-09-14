import SwiftUI

enum FlowSort: String, CaseIterable, Identifiable {
    case traffic = "Most traffic"
    case recent = "Most recent"
    case connections = "Most connections"
    case name = "Name"

    var id: String { rawValue }
}

enum FlowGrouping: String, CaseIterable, Identifiable {
    case host = "By host"
    case endpoint = "By endpoint"

    var id: String { rawValue }
}

/// What a destination row links to: the flows are looked up live so the detail view keeps updating.
struct DestinationRef: Hashable {
    let title: String
    let flowIDs: [String]
}

struct DestinationEntry: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let flowIDs: [String]
    let bytesIn: UInt64
    let bytesOut: UInt64
    let connections: UInt64
    let lastSeen: Date

    var totalBytes: UInt64 { bytesIn &+ bytesOut }
}

struct DestinationsView: View {
    @EnvironmentObject private var store: TrafficStore
    @EnvironmentObject private var resolver: ReverseDNSResolver
    @AppStorage("reverseDNS") private var reverseDNS = true
    @State private var searchText = ""
    @State private var sort: FlowSort = .traffic
    @State private var grouping: FlowGrouping = .host

    var body: some View {
        NavigationStack {
            Group {
                if let snapshot = store.snapshot, !snapshot.flows.isEmpty {
                    DestinationList(entries: entries, searchText: searchText)
                } else {
                    ContentUnavailableView("No destinations yet",
                                           systemImage: "globe",
                                           description: Text("Destinations appear here while capture is running."))
                }
            }
            .navigationTitle("Destinations")
            .navigationDestination(for: DestinationRef.self) { reference in
                FlowDetailView(reference: reference)
            }
            .searchable(text: $searchText, prompt: "Host, address or port")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Picker("Sort by", selection: $sort) {
                            ForEach(FlowSort.allCases) { option in
                                Text(option.rawValue).tag(option)
                            }
                        }
                        Picker("Group", selection: $grouping) {
                            ForEach(FlowGrouping.allCases) { option in
                                Text(option.rawValue).tag(option)
                            }
                        }
                    } label: {
                        Label("Sort and group", systemImage: "line.3.horizontal.decrease.circle")
                    }
                }
            }
        }
    }

    private func displayName(_ flow: FlowStats) -> String {
        if let hostname = flow.hostname { return hostname }
        if reverseDNS, let name = resolver.name(for: flow.remoteAddress) { return name }
        return flow.remoteAddress
    }

    private var entries: [DestinationEntry] {
        guard let flows = store.snapshot?.flows else { return [] }
        var result: [DestinationEntry] = []

        switch grouping {
        case .endpoint:
            for flow in flows {
                result.append(DestinationEntry(id: flow.id,
                                               title: displayName(flow),
                                               subtitle: "\(flow.remoteAddress) · \(flow.transport) port \(flow.remotePort)",
                                               flowIDs: [flow.id],
                                               bytesIn: flow.bytesIn,
                                               bytesOut: flow.bytesOut,
                                               connections: flow.connections,
                                               lastSeen: flow.lastSeen))
            }
        case .host:
            var groups: [String: [FlowStats]] = [:]
            for flow in flows {
                groups[displayName(flow), default: []].append(flow)
            }
            for (name, group) in groups {
                let addresses = Set(group.map(\.remoteAddress))
                let ports = Set(group.map { "\($0.transport) \($0.remotePort)" }).sorted()
                var subtitle = addresses.count == 1 ? (addresses.first ?? "") : "\(addresses.count) addresses"
                subtitle += " · " + ports.prefix(3).joined(separator: ", ")
                if ports.count > 3 { subtitle += " +\(ports.count - 3)" }
                result.append(DestinationEntry(id: "host/" + name,
                                               title: name,
                                               subtitle: subtitle,
                                               flowIDs: group.map(\.id),
                                               bytesIn: group.reduce(0) { $0 &+ $1.bytesIn },
                                               bytesOut: group.reduce(0) { $0 &+ $1.bytesOut },
                                               connections: group.reduce(0) { $0 &+ $1.connections },
                                               lastSeen: group.map(\.lastSeen).max() ?? Date.distantPast))
            }
        }

        let query = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        if !query.isEmpty {
            result = result.filter { $0.title.lowercased().contains(query) || $0.subtitle.lowercased().contains(query) }
        }

        switch sort {
        case .traffic:
            result.sort { $0.totalBytes != $1.totalBytes ? $0.totalBytes > $1.totalBytes : $0.title < $1.title }
        case .recent:
            result.sort { $0.lastSeen != $1.lastSeen ? $0.lastSeen > $1.lastSeen : $0.title < $1.title }
        case .connections:
            result.sort { $0.connections != $1.connections ? $0.connections > $1.connections : $0.title < $1.title }
        case .name:
            result.sort { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        }
        return result
    }
}

private struct DestinationList: View {
    let entries: [DestinationEntry]
    let searchText: String

    var body: some View {
        List(entries) { entry in
            NavigationLink(value: DestinationRef(title: entry.title, flowIDs: entry.flowIDs)) {
                DestinationRow(entry: entry)
            }
        }
        .overlay {
            if entries.isEmpty {
                ContentUnavailableView.search(text: searchText)
            }
        }
    }
}

struct DestinationRow: View {
    let entry: DestinationEntry

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.title)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(entry.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 2) {
                Text(Format.bytes(entry.totalBytes))
                    .font(.body.monospacedDigit())
                Text("\(entry.connections) conn · \(Format.relative(entry.lastSeen))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}
