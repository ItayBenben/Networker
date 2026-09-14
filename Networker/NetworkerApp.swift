import SwiftUI

@main
struct NetworkerApp: App {
    @StateObject private var tunnel = TunnelManager()
    @StateObject private var store = TrafficStore()
    @StateObject private var resolver = ReverseDNSResolver()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(tunnel)
                .environmentObject(store)
                .environmentObject(resolver)
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var store: TrafficStore
    @EnvironmentObject private var tunnel: TunnelManager
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        TabView {
            OverviewView()
                .tabItem { Label("Overview", systemImage: "waveform.path.ecg") }
            DestinationsView()
                .tabItem { Label("Destinations", systemImage: "globe") }
            SourcesView()
                .tabItem { Label("Sources", systemImage: "iphone.radiowaves.left.and.right") }
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
        }
        .task {
            await store.pollForever()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                store.reload(force: true)
                Task { await tunnel.refresh() }
            }
        }
    }
}
