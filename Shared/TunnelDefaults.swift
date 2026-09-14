import Foundation

/// Network parameters of the on-device tunnel. Shared so the app can display them.
enum TunnelDefaults {
    static let tunnelRemoteAddress = "10.255.0.1"
    static let localIPv4 = "10.255.0.2"
    static let localIPv6 = "fd4e:4574:574b::2"
    /// Public resolvers used while capturing; the tunnel must name resolvers explicitly.
    static let dnsServers = ["1.1.1.1", "8.8.8.8", "1.0.0.1", "8.8.4.4"]
    static let mtu = 1500
}
