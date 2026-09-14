import Foundation

/// Identifiers shared between the app and the packet tunnel extension.
///
/// Everything is derived from the app's bundle identifier so that a single value
/// (`BUNDLE_ID_BASE` in `Config/Networker.xcconfig`) drives the app, the extension
/// and the shared App Group. `Scripts/configure.py` keeps the entitlements in sync.
enum AppIdentity {
    static let tunnelSuffix = ".tunnel"

    /// Bundle identifier of the containing app. Works when called from the extension too.
    static var appBundleID: String {
        let identifier = Bundle.main.bundleIdentifier ?? "com.example.networker"
        if identifier.hasSuffix(tunnelSuffix) {
            return String(identifier.dropLast(tunnelSuffix.count))
        }
        return identifier
    }

    static var tunnelBundleID: String { appBundleID + tunnelSuffix }

    static var appGroupID: String { "group." + appBundleID }

    static var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID)
    }

    static var snapshotURL: URL? {
        containerURL?.appendingPathComponent("traffic-snapshot.json", isDirectory: false)
    }
}
