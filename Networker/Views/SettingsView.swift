import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var tunnel: TunnelManager
    @EnvironmentObject private var store: TrafficStore
    @AppStorage("reverseDNS") private var reverseDNS = true
    @State private var confirmClear = false
    @State private var confirmRemove = false
    @State private var exportURL: URL?

    var body: some View {
        NavigationStack {
            List {
                Section("Capture") {
                    CaptureStatusRow()
                    LabeledContent("VPN configuration", value: tunnel.isConfigured ? "Installed" : "Not installed")
                }

                Section("Data") {
                    Toggle("Reverse-DNS unnamed addresses", isOn: $reverseDNS)
                    if let exportURL {
                        ShareLink(item: exportURL) {
                            Label("Export recorded data (JSON)", systemImage: "square.and.arrow.up")
                        }
                    }
                    Button(role: .destructive) {
                        confirmClear = true
                    } label: {
                        Label("Clear recorded data", systemImage: "trash")
                    }
                }

                Section("Advanced") {
                    Button(role: .destructive) {
                        confirmRemove = true
                    } label: {
                        Text("Remove VPN configuration")
                    }
                    .disabled(!tunnel.isConfigured || tunnel.isBusy)
                }

                Section("How it works") {
                    Text("Networker installs an on-device VPN (a Packet Tunnel extension). While capturing, every IP packet the iPhone sends passes through the extension, which records the destination, direction, size and time, then relays the traffic to its real destination. Nothing leaves the device except your own traffic.")
                    Text("DNS resolvers while capturing: " + TunnelDefaults.dnsServers.joined(separator: ", "))
                }

                Section("Limitations") {
                    Text("• iOS does not reveal which app sent a packet, so sources are shown per local address and port, not per app.")
                    Text("• Only TCP and UDP are relayed. ICMP (ping) does not work while capturing.")
                    Text("• iCloud Private Relay and other VPNs are paused while capturing.")
                    Text("• Traffic from the Networker app itself is captured too (for example its reverse-DNS lookups).")
                    Text("• The tunnel extension only runs on a real iPhone, not in the Simulator.")
                }

                Section {
                    LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—")
                    LabeledContent("App Group", value: AppIdentity.appGroupID)
                }
            }
            .navigationTitle("Settings")
            .onAppear {
                exportURL = store.exportURL()
            }
            .confirmationDialog("Delete all recorded traffic data?", isPresented: $confirmClear, titleVisibility: .visible) {
                Button("Clear", role: .destructive) {
                    Task { await clearHistory() }
                }
            }
            .confirmationDialog("Remove the VPN configuration? Capture stops and the app must set it up again next time.",
                                isPresented: $confirmRemove, titleVisibility: .visible) {
                Button("Remove", role: .destructive) {
                    Task { await tunnel.removeConfiguration() }
                }
            }
        }
    }

    private func clearHistory() async {
        let handledByExtension = await tunnel.sendCommand("clear")
        if !handledByExtension {
            store.clearLocalData()
        }
        store.reload(force: true)
        exportURL = store.exportURL()
    }
}
