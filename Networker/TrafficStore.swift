import Foundation

/// Loads the snapshot written by the tunnel extension and keeps it fresh while the app is visible.
@MainActor
final class TrafficStore: ObservableObject {
    @Published private(set) var snapshot: TrafficSnapshot?
    @Published private(set) var lastLoaded: Date?

    private var lastModified: Date?
    private var loading = false

    static let pollInterval: TimeInterval = 2

    func pollForever() async {
        while !Task.isCancelled {
            reload(force: false)
            try? await Task.sleep(nanoseconds: UInt64(Self.pollInterval * 1_000_000_000))
        }
    }

    /// Reads the snapshot from disk if it changed (or always, when `force` is set).
    func reload(force: Bool) {
        guard !loading else { return }
        let modified = SnapshotStore.modificationDate()
        if !force, snapshot != nil, let modified, let lastModified, modified == lastModified {
            return
        }
        if modified == nil && snapshot == nil && !force {
            return
        }
        loading = true
        Task.detached(priority: .userInitiated) { [weak self] in
            let loaded = SnapshotStore.load()
            await MainActor.run {
                guard let self else { return }
                self.loading = false
                self.lastModified = modified
                self.snapshot = loaded
                self.lastLoaded = Date()
            }
        }
    }

    func clearLocalData() {
        SnapshotStore.delete()
        snapshot = nil
        lastModified = nil
    }

    /// Copies the current snapshot to a temporary file for sharing.
    func exportURL() -> URL? {
        guard let url = AppIdentity.snapshotURL, FileManager.default.fileExists(atPath: url.path) else { return nil }
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent("networker-traffic.json")
        do {
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.copyItem(at: url, to: destination)
            return destination
        } catch {
            return nil
        }
    }
}
