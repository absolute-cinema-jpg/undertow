import Foundation

public enum RateUnit: String, Codable, CaseIterable, Sendable { case bytes, bits }

public enum Format {
    /// Formats a bytes-per-second rate. `compact` drops the "/s", for tight spaces.
    public static func rate(_ bytesPerSec: Double, unit: RateUnit = .bytes, decimals: Int = 1, compact: Bool = false) -> String {
        let value = unit == .bits ? bytesPerSec * 8 : bytesPerSec
        let (scaled, prefix) = scale(value)
        let suffix: String
        switch unit {
        case .bytes: suffix = compact ? "\(prefix)B" : "\(prefix)B/s"
        case .bits: suffix = compact ? "\(prefix)b" : "\(prefix)bps"
        }
        let digits = prefix.isEmpty || prefix == "K" && scaled >= 100 ? 0 : decimals
        return String(format: "%.\(digits)f %@", scaled, suffix)
    }

    /// A rate for tight spaces, at most three significant digits: 8.88, 88.8, 888. Precision
    /// past that is noise in a number changing every second, and costs menu bar width.
    /// `decimals` is the most it will show. `short` drops the "/s".
    public static func tightRate(_ bytesPerSec: Double, unit: RateUnit = .bytes, decimals: Int = 1, short: Bool = false) -> String {
        let value = unit == .bits ? bytesPerSec * 8 : bytesPerSec
        let (scaled, prefix) = scale(value)
        let limit = scaled >= 99.95 ? 0 : scaled >= 9.995 ? 1 : 2
        let digits = prefix.isEmpty ? 0 : min(decimals, limit)
        let suffix: String
        switch unit {
        case .bytes: suffix = short ? "\(prefix)B" : "\(prefix)B/s"
        case .bits: suffix = short ? "\(prefix)b" : "\(prefix)bps"
        }
        return String(format: "%.\(digits)f %@", scaled, suffix)
    }

    public static func bytes(_ count: UInt64) -> String {
        let (scaled, prefix) = scale(Double(count))
        return String(format: prefix.isEmpty ? "%.0f %@B" : "%.1f %@B", scaled, prefix)
    }

    /// Uses 1000-based units, matching how ISPs quote speeds and how macOS reports sizes.
    private static func scale(_ value: Double) -> (Double, String) {
        let v = max(0, value)
        if v >= 999_950_000_000 { return (v / 1_000_000_000_000, "T") }
        if v >= 999_950_000 { return (v / 1_000_000_000, "G") }
        if v >= 999_950 { return (v / 1_000_000, "M") }
        if v >= 1000 { return (v / 1000, "K") }
        return (v, "")
    }

    public static func relative(_ date: Date, now: Date = Date()) -> String {
        let s = Int(now.timeIntervalSince(date))
        if s < 60 { return "just now" }
        if s < 3600 { return "\(s / 60)m ago" }
        if s < 86400 { return "\(s / 3600)h ago" }
        return "\(s / 86400)d ago"
    }

    public static func serviceName(port: Int?, proto: TransportProto) -> String? {
        guard let port else { return nil }
        switch (port, proto) {
        case (443, .tcp): return "HTTPS"
        case (443, .udp): return "QUIC"
        case (80, _): return "HTTP (unencrypted)"
        case (53, _): return "DNS"
        case (853, _): return "DNS over TLS"
        case (22, _): return "SSH"
        case (25, _), (465, _), (587, _): return "Email (SMTP)"
        case (143, _), (993, _): return "Email (IMAP)"
        case (445, _): return "SMB"
        case (548, _): return "AFP"
        case (5223, _): return "Apple Push"
        case (5353, _): return "Bonjour"
        case (123, _): return "Time"
        case (21, _): return "FTP (unencrypted)"
        case (23, _): return "Telnet (unencrypted)"
        case (51820, _): return "WireGuard"
        case (1194, _): return "OpenVPN"
        default: return nil
        }
    }
}

/// Cleans text that came from outside the app before it's shown. App names and network
/// names are chosen by whoever controls them, and invisible characters can disguise them:
/// right-to-left overrides can make "gnp.exe" read "exe.png", for example.
public enum Sanitize {
    public static func displayText(_ text: String, maxLength: Int = 200) -> String {
        var view = String.UnicodeScalarView()
        for scalar in text.unicodeScalars.prefix(maxLength * 2) {
            switch scalar.properties.generalCategory {
            case .control, .format, .lineSeparator, .paragraphSeparator, .surrogate, .privateUse, .unassigned:
                continue
            default:
                view.append(scalar)
            }
        }
        return String(String(view).prefix(maxLength))
    }

    /// Letters, digits, hyphens and dots only, which is all a real hostname contains.
    public static func isPlausibleHostname(_ name: String) -> Bool {
        guard !name.isEmpty, name.utf8.count <= 253, name.contains("."), IP.canonical(name) == nil else { return false }
        return name.utf8.allSatisfy { c in
            (c >= 0x30 && c <= 0x39) || (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) || c == 0x2D || c == 0x2E || c == 0x5F
        }
    }
}

/// Fixed-capacity history buffer for graphs. No reallocation at runtime.
public struct RingBuffer<Element> {
    private var storage: [Element]
    private var head = 0
    public private(set) var count = 0
    public let capacity: Int

    public init(capacity: Int, filler: Element) {
        self.capacity = capacity
        storage = Array(repeating: filler, count: capacity)
    }

    public mutating func append(_ value: Element) {
        storage[head] = value
        head = (head + 1) % capacity
        count = Swift.min(count + 1, capacity)
    }

    /// Oldest first. `last` limits it to the newest N values.
    public func values(last n: Int? = nil) -> [Element] {
        let take = Swift.min(n ?? count, count)
        return (0..<take).map { storage[(head - take + $0 + capacity) % capacity] }
    }
}

/// Keeps a width steady so a live readout doesn't jostle its neighbours every second. It grows
/// at once, so text never clips, and only shrinks after staying smaller for `hold` seconds.
public struct StickyWidth: Equatable {
    public private(set) var current: Double = 0
    public let hold: TimeInterval
    private var lastNeededFull: Date = .distantPast

    public init(hold: TimeInterval = 20) { self.hold = hold }

    public mutating func update(needed: Double, now: Date) -> Double {
        if needed >= current {
            current = needed
            lastNeededFull = now
        } else if now.timeIntervalSince(lastNeededFull) >= hold {
            current = needed
            lastNeededFull = now
        }
        return current
    }
}

/// The arithmetic behind drag-to-reorder lists.
public enum DragReorder {
    /// Which slot a row dragged from `start` should occupy, swapping once it passes halfway.
    public static func targetIndex(start: Int, translation: Double, rowHeight: Double, count: Int) -> Int {
        guard rowHeight > 0, count > 0 else { return start }
        return Swift.min(Swift.max(0, start + Int((translation / rowHeight).rounded())), count - 1)
    }

    public static func moved<T>(_ items: [T], from: Int, to: Int) -> [T] {
        guard items.indices.contains(from), items.indices.contains(to), from != to else { return items }
        var result = items
        let item = result.remove(at: from)
        result.insert(item, at: to)
        return result
    }
}
