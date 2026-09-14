import Foundation
import Network
import NetworkExtension

/// Captures all of the device's IP traffic by acting as an on-device VPN, relays it to the real
/// destinations, and records who the device talks to, how often and how much.
final class PacketTunnelProvider: NEPacketTunnelProvider {
    private var router: PacketRouter?

    override func startTunnel(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        Self.probeIPv6Support { [weak self] supportsIPv6 in
            guard let self else { return }
            let settings = Self.makeSettings(includeIPv6: supportsIPv6)
            self.setTunnelNetworkSettings(settings) { error in
                if let error {
                    completionHandler(error)
                    return
                }
                let router = self.makeRouter(supportsIPv6: supportsIPv6)
                self.router = router
                router.start()
                self.readPackets()
                completionHandler(nil)
            }
        }
    }

    private func makeRouter(supportsIPv6: Bool) -> PacketRouter {
        let queue = DispatchQueue(label: "networker.tunnel", qos: .userInitiated)
        let stats = StatsCollector(previous: SnapshotStore.load(),
                                   queue: queue,
                                   now: Date(),
                                   localIPv4: TunnelDefaults.localIPv4,
                                   localIPv6: supportsIPv6 ? TunnelDefaults.localIPv6 : nil,
                                   dnsServers: TunnelDefaults.dnsServers)
        return PacketRouter(queue: queue, stats: stats) { [weak self] packets, protocols in
            _ = self?.packetFlow.writePackets(packets, withProtocols: protocols)
        }
    }

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        guard let router else {
            completionHandler()
            return
        }
        router.queue.async {
            router.stop()
            completionHandler()
        }
    }

    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)?) {
        let command = String(decoding: messageData, as: UTF8.self)
        guard let router else {
            completionHandler?(nil)
            return
        }
        router.queue.async {
            switch command {
            case "clear":
                router.stats.reset(now: Date())
                router.stats.flushSync(now: Date(), isCapturing: true)
            case "flush":
                router.stats.flushSync(now: Date(), isCapturing: true)
            default:
                break
            }
            completionHandler?(Data("ok".utf8))
        }
    }

    override func sleep(completionHandler: @escaping () -> Void) {
        guard let router else {
            completionHandler()
            return
        }
        router.queue.async {
            router.stats.flushSync(now: Date(), isCapturing: true)
            completionHandler()
        }
    }

    override func wake() {
    }

    // MARK: - Packet loop

    private func readPackets() {
        packetFlow.readPackets { [weak self] packets, _ in
            guard let self, let router = self.router else { return }
            router.queue.async {
                router.handle(packets)
            }
            self.readPackets()
        }
    }

    // MARK: - Configuration

    private static func makeSettings(includeIPv6: Bool) -> NEPacketTunnelNetworkSettings {
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: TunnelDefaults.tunnelRemoteAddress)

        let ipv4 = NEIPv4Settings(addresses: [TunnelDefaults.localIPv4], subnetMasks: ["255.255.255.0"])
        ipv4.includedRoutes = [NEIPv4Route.default()]
        settings.ipv4Settings = ipv4

        if includeIPv6 {
            let ipv6 = NEIPv6Settings(addresses: [TunnelDefaults.localIPv6], networkPrefixLengths: [64])
            ipv6.includedRoutes = [NEIPv6Route.default()]
            settings.ipv6Settings = ipv6
        }

        let dns = NEDNSSettings(servers: TunnelDefaults.dnsServers)
        dns.matchDomains = [""]   // make these resolvers the default for every domain
        settings.dnsSettings = dns

        settings.mtu = NSNumber(value: TunnelDefaults.mtu)
        return settings
    }

    /// Only claim an IPv6 default route when the underlying network actually offers IPv6;
    /// otherwise apps would attempt IPv6 connections that can only fail.
    private static func probeIPv6Support(_ completion: @escaping (Bool) -> Void) {
        final class Once {
            var done = false
        }
        let monitor = NWPathMonitor()
        let queue = DispatchQueue(label: "networker.path-probe")
        let once = Once()   // only touched on `queue`
        monitor.pathUpdateHandler = { path in
            guard !once.done else { return }
            once.done = true
            monitor.cancel()
            completion(path.status == .satisfied && path.supportsIPv6)
        }
        monitor.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 2) {
            guard !once.done else { return }
            once.done = true
            monitor.cancel()
            completion(false)
        }
    }
}
