import Foundation
import NetworkExtension

/// Installs, starts and stops the packet tunnel (the capture engine).
@MainActor
final class TunnelManager: ObservableObject {
    @Published private(set) var status: NEVPNStatus = .invalid
    @Published private(set) var isConfigured = false
    @Published private(set) var isBusy = false
    @Published var errorMessage: String?

    private var manager: NETunnelProviderManager?
    private var statusObserver: NSObjectProtocol?

    init() {
        statusObserver = NotificationCenter.default.addObserver(forName: .NEVPNStatusDidChange,
                                                                object: nil,
                                                                queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.updateStatus()
            }
        }
        Task { await refresh() }
    }

    var isCapturing: Bool { status == .connected }

    var statusDescription: String {
        switch status {
        case .connected: return "Capturing"
        case .connecting: return "Starting…"
        case .reasserting: return "Reconnecting…"
        case .disconnecting: return "Stopping…"
        case .disconnected: return isConfigured ? "Not capturing" : "Not set up"
        case .invalid: return "Not set up"
        @unknown default: return "Unknown"
        }
    }

    /// Re-reads the saved VPN configuration and its connection status.
    func refresh() async {
        do {
            manager = try await Self.loadExistingManager()
            isConfigured = manager != nil
            updateStatus()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func start() async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        errorMessage = nil
        do {
            let manager = try await ensureManager()
            if !manager.isEnabled {
                manager.isEnabled = true
                try await manager.saveToPreferences()
                try await manager.loadFromPreferences()
            }
            try manager.connection.startVPNTunnel()
            updateStatus()
        } catch {
            errorMessage = Self.describe(error)
        }
    }

    func stop() {
        errorMessage = nil
        manager?.connection.stopVPNTunnel()
        updateStatus()
    }

    func toggle() async {
        if isCapturing || status == .connecting || status == .reasserting {
            stop()
        } else {
            await start()
        }
    }

    /// Sends a command ("clear" or "flush") to the running extension. Returns false if it is not running.
    func sendCommand(_ command: String) async -> Bool {
        guard let session = manager?.connection as? NETunnelProviderSession, session.status == .connected else {
            return false
        }
        return await withCheckedContinuation { continuation in
            do {
                try session.sendProviderMessage(Data(command.utf8)) { _ in
                    continuation.resume(returning: true)
                }
            } catch {
                continuation.resume(returning: false)
            }
        }
    }

    func removeConfiguration() async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        errorMessage = nil
        do {
            if let manager {
                manager.connection.stopVPNTunnel()
                try await manager.removeFromPreferences()
            }
            manager = nil
            isConfigured = false
            status = .invalid
        } catch {
            errorMessage = Self.describe(error)
        }
    }

    // MARK: - Private

    private func updateStatus() {
        status = manager?.connection.status ?? .invalid
    }

    private static func loadExistingManager() async throws -> NETunnelProviderManager? {
        let managers = try await NETunnelProviderManager.loadAllFromPreferences()
        return managers.first { manager in
            (manager.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == AppIdentity.tunnelBundleID
        }
    }

    private func ensureManager() async throws -> NETunnelProviderManager {
        if let manager {
            return manager
        }
        let manager = try await Self.loadExistingManager() ?? NETunnelProviderManager()
        let configuration = (manager.protocolConfiguration as? NETunnelProviderProtocol) ?? NETunnelProviderProtocol()
        configuration.providerBundleIdentifier = AppIdentity.tunnelBundleID
        configuration.serverAddress = "On-device capture"
        manager.protocolConfiguration = configuration
        manager.localizedDescription = "Networker Traffic Monitor"
        manager.isEnabled = true
        try await manager.saveToPreferences()
        // Apple requires reloading after saving before the configuration can be started.
        try await manager.loadFromPreferences()
        self.manager = manager
        isConfigured = true
        return manager
    }

    private static func describe(_ error: Error) -> String {
        let nsError = error as NSError
        if nsError.domain == NEVPNErrorDomain, let code = NEVPNError.Code(rawValue: nsError.code) {
            switch code {
            case .configurationInvalid:
                return "The VPN configuration is invalid. Check that the extension's bundle identifier ends in \".tunnel\" and that both targets have the Network Extensions and App Groups capabilities."
            case .configurationDisabled:
                return "The VPN configuration is disabled. Enable it in Settings › General › VPN & Device Management."
            case .connectionFailed:
                return "The capture extension failed to start. Rebuild and reinstall the app, then try again."
            case .configurationStale:
                return "The VPN configuration is stale. Try again."
            case .configurationReadWriteFailed:
                return "Could not save the VPN configuration. Did you allow Networker to add a VPN configuration?"
            case .configurationUnknown:
                return "Unknown VPN configuration error."
            @unknown default:
                break
            }
        }
        return error.localizedDescription
    }
}
