import Foundation

enum Format {
    static func bytes(_ value: UInt64) -> String {
        bytes(Double(value))
    }

    static func bytes(_ value: Double) -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var amount = max(value, 0)
        var index = 0
        while amount >= 1000 && index < units.count - 1 {
            amount /= 1000
            index += 1
        }
        let digits = index == 0 ? 0 : (amount < 10 ? 2 : (amount < 100 ? 1 : 0))
        return String(format: "%.\(digits)f %@", amount, units[index])
    }

    static func rate(_ bytesPerSecond: Double) -> String {
        bytes(bytesPerSecond) + "/s"
    }

    static func count(_ value: UInt64) -> String {
        value.formatted()
    }

    static func relative(_ date: Date) -> String {
        let elapsed = Date().timeIntervalSince(date)
        if elapsed < 5 { return "just now" }
        return date.formatted(.relative(presentation: .named))
    }

    static func dateTime(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let total = Int(max(seconds, 0))
        if total < 60 { return "\(total) s" }
        if total < 3600 { return "\(total / 60) min" }
        if total < 86400 { return String(format: "%.1f h", Double(total) / 3600) }
        return String(format: "%.1f d", Double(total) / 86400)
    }

    /// Connections per hour, rendered for humans.
    static func frequency(connections: UInt64, over interval: TimeInterval) -> String {
        guard connections > 0 else { return "—" }
        let hours = max(interval, 60) / 3600
        let perHour = Double(connections) / hours
        if perHour >= 100 { return "\(Int(perHour.rounded()))/h" }
        if perHour >= 10 { return String(format: "%.0f/h", perHour) }
        if perHour >= 1 { return String(format: "%.1f/h", perHour) }
        return String(format: "%.1f/day", perHour * 24)
    }
}
