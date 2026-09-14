import SwiftUI

struct OverviewView: View {
    @EnvironmentObject private var tunnel: TunnelManager
    @EnvironmentObject private var store: TrafficStore
    @State private var range: TimeRange = .hour

    var body: some View {
        NavigationStack {
            List {
                Section {
                    CaptureStatusRow()
                }
                if let snapshot = store.snapshot {
                    liveSection(snapshot)
                    historySection(snapshot)
                    totalsSection(snapshot)
                } else {
                    Section {
                        ContentUnavailableView("No traffic recorded yet",
                                               systemImage: "antenna.radiowaves.left.and.right",
                                               description: Text("Tap Start to begin capturing this iPhone's network traffic."))
                    }
                }
            }
            .navigationTitle("Networker")
        }
    }

    @ViewBuilder
    private func liveSection(_ snapshot: TrafficSnapshot) -> some View {
        let now = Date()
        let rate = TrafficMath.currentRate(snapshot.liveBuckets, seconds: 3, now: now)
        Section {
            LiveThroughputChart(buckets: TrafficMath.denseLive(snapshot.liveBuckets, seconds: 120, now: now))
                .frame(height: 170)
            HStack {
                Label(Format.rate(rate.inbound), systemImage: "arrow.down.circle.fill")
                    .foregroundStyle(.blue)
                Spacer()
                Label(Format.rate(rate.outbound), systemImage: "arrow.up.circle.fill")
                    .foregroundStyle(.orange)
            }
            .font(.subheadline.monospacedDigit())
        } header: {
            Text("Live throughput · last 2 minutes")
        }
    }

    @ViewBuilder
    private func historySection(_ snapshot: TrafficSnapshot) -> some View {
        let window = range.window(endingAt: Date())
        let buckets = TrafficMath.rebucket([snapshot.historyBuckets], seconds: range.bucketSeconds,
                                           start: window.start, end: window.end)
        Section {
            TimeRangePicker(range: $range)
            TrafficBarChart(buckets: buckets, bucketSeconds: range.bucketSeconds,
                            start: window.start, end: window.end)
                .frame(height: 200)
            ConnectionsChart(buckets: buckets, bucketSeconds: range.bucketSeconds,
                             start: window.start, end: window.end)
                .frame(height: 110)
        } header: {
            Text("Throughput and new connections over time")
        }
    }

    @ViewBuilder
    private func totalsSection(_ snapshot: TrafficSnapshot) -> some View {
        Section("Totals (last 24 h retained)") {
            LabeledContent("Received", value: Format.bytes(snapshot.totalBytesIn))
            LabeledContent("Sent", value: Format.bytes(snapshot.totalBytesOut))
            LabeledContent("Packets", value: Format.count(snapshot.totalPacketsIn &+ snapshot.totalPacketsOut))
            LabeledContent("Connections opened", value: Format.count(snapshot.totalConnections))
            LabeledContent("Destinations", value: Format.count(UInt64(snapshot.flows.count)))
            LabeledContent("Active flows", value: "\(snapshot.activeTCPConnections) TCP · \(snapshot.activeUDPSessions) UDP")
            LabeledContent("Network", value: snapshot.currentInterface)
            if let started = snapshot.captureStartedAt {
                LabeledContent("Capture started", value: Format.dateTime(started))
            }
            LabeledContent("Last update", value: Format.relative(snapshot.generatedAt))
            if snapshot.unsupportedPackets > 0 {
                LabeledContent("Unsupported packets", value: Format.count(snapshot.unsupportedPackets))
            }
        }
    }
}

/// Status line with the Start / Stop button; shared by Overview and Settings.
struct CaptureStatusRow: View {
    @EnvironmentObject private var tunnel: TunnelManager

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Circle()
                    .fill(tunnel.isCapturing ? Color.green : Color.secondary)
                    .frame(width: 10, height: 10)
                Text(tunnel.statusDescription)
                    .font(.headline)
                Spacer()
                Button {
                    Task { await tunnel.toggle() }
                } label: {
                    Text(tunnel.isCapturing || tunnel.status == .connecting ? "Stop" : "Start")
                        .frame(minWidth: 56)
                }
                .buttonStyle(.borderedProminent)
                .tint(tunnel.isCapturing ? .red : .accentColor)
                .disabled(tunnel.isBusy || tunnel.status == .disconnecting)
            }
            if let error = tunnel.errorMessage {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        }
        .padding(.vertical, 4)
    }
}
