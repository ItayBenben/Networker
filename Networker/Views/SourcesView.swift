import SwiftUI

/// Where traffic originates: this device's tunnel addresses, the physical interface, and the
/// most recent (local address, port) pairs that opened connections.
struct SourcesView: View {
    @EnvironmentObject private var store: TrafficStore

    var body: some View {
        NavigationStack {
            List {
                if let snapshot = store.snapshot {
                    Section("This iPhone") {
                        LabeledContent("Tunnel IPv4", value: snapshot.localIPv4 ?? "—")
                        LabeledContent("Tunnel IPv6", value: snapshot.localIPv6 ?? "Not available")
                        LabeledContent("Current network", value: snapshot.currentInterface)
                        Text("Every packet captured here was sent by this iPhone. iOS does not expose which app sent it, so sources are shown as local address and port.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    interfaceSection(snapshot)
                    recentSection(snapshot)
                } else {
                    ContentUnavailableView("No traffic recorded yet",
                                           systemImage: "iphone.radiowaves.left.and.right",
                                           description: Text("Start capture from the Overview tab."))
                }
            }
            .navigationTitle("Sources")
        }
    }

    @ViewBuilder
    private func interfaceSection(_ snapshot: TrafficSnapshot) -> some View {
        let totals = FlowDetailView.interfaceTotals(snapshot.flows)
        Section("Traffic by network interface") {
            if totals.isEmpty {
                Text("Nothing recorded yet.").foregroundStyle(.secondary)
            } else {
                InterfaceChart(totals: totals)
                    .frame(height: CGFloat(40 * totals.count + 20))
                ForEach(totals, id: \.name) { item in
                    LabeledContent(item.name, value: Format.bytes(item.bytes))
                }
            }
        }
    }

    @ViewBuilder
    private func recentSection(_ snapshot: TrafficSnapshot) -> some View {
        let items: [RecentConnection] = RecentConnection.collect(from: snapshot.flows, limit: 100, useHostnames: true)
        Section("Recent connections from this iPhone") {
            if items.isEmpty {
                Text("No connections recorded yet.").foregroundStyle(.secondary)
            }
            ForEach(items) { item in
                RecentConnectionRow(item: item)
            }
        }
    }
}
