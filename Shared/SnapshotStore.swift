import Foundation

enum SnapshotStoreError: Error {
    case noAppGroupContainer
}

/// Reads and writes the traffic snapshot in the shared App Group container.
enum SnapshotStore {
    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        return encoder
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }

    static func encode(_ snapshot: TrafficSnapshot) throws -> Data {
        try makeEncoder().encode(snapshot)
    }

    static func decode(_ data: Data) throws -> TrafficSnapshot {
        try makeDecoder().decode(TrafficSnapshot.self, from: data)
    }

    /// Returns nil when there is no snapshot yet or it was written by an incompatible version.
    static func load() -> TrafficSnapshot? {
        guard let url = AppIdentity.snapshotURL,
              let data = try? Data(contentsOf: url),
              let snapshot = try? decode(data),
              snapshot.version == TrafficConstants.snapshotVersion else {
            return nil
        }
        return snapshot
    }

    static func save(_ data: Data) throws {
        guard let url = AppIdentity.snapshotURL else { throw SnapshotStoreError.noAppGroupContainer }
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    static func delete() {
        guard let url = AppIdentity.snapshotURL else { return }
        try? FileManager.default.removeItem(at: url)
    }

    static func modificationDate() -> Date? {
        guard let url = AppIdentity.snapshotURL,
              let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else {
            return nil
        }
        return attributes[.modificationDate] as? Date
    }
}
