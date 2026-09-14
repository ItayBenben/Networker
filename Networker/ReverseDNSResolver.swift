import Foundation

/// Best-effort PTR lookups for addresses whose DNS query the capture did not see
/// (for example connections whose name resolution happened before capture started).
@MainActor
final class ReverseDNSResolver: ObservableObject {
    @Published private(set) var names: [String: String] = [:]

    private var pending: Set<String> = []
    private var failed: Set<String> = []
    private let queue = DispatchQueue(label: "networker.reverse-dns", qos: .utility, attributes: .concurrent)

    private static let maxConcurrent = 6

    /// Returns a cached name, or nil while starting a lookup in the background.
    func name(for address: String) -> String? {
        if let name = names[address] { return name }
        guard !pending.contains(address), !failed.contains(address), pending.count < Self.maxConcurrent else {
            return nil
        }
        pending.insert(address)
        queue.async {
            let result = Self.lookup(address)
            Task { @MainActor in
                self.pending.remove(address)
                if let result {
                    self.names[address] = result
                } else {
                    self.failed.insert(address)
                }
            }
        }
        return nil
    }

    nonisolated private static func lookup(_ address: String) -> String? {
        var hints = addrinfo()
        hints.ai_flags = AI_NUMERICHOST
        var info: UnsafeMutablePointer<addrinfo>? = nil
        guard getaddrinfo(address, nil, &hints, &info) == 0, let first = info else { return nil }
        defer { freeaddrinfo(info) }

        var host = [CChar](repeating: 0, count: 1025)
        let result = host.withUnsafeMutableBufferPointer { buffer -> Int32 in
            getnameinfo(first.pointee.ai_addr, first.pointee.ai_addrlen,
                        buffer.baseAddress, socklen_t(buffer.count),
                        nil, 0, NI_NAMEREQD)
        }
        guard result == 0 else { return nil }
        let name = host.withUnsafeBufferPointer { buffer -> String in
            guard let base = buffer.baseAddress else { return "" }
            return String(cString: base)
        }
        let trimmed = name.hasSuffix(".") ? String(name.dropLast()) : name
        return trimmed.isEmpty ? nil : trimmed
    }
}
