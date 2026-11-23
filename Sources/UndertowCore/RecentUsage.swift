import Foundation

/// The last few minutes of traffic, kept in memory in 5-second buckets. The saved history
/// only has hourly totals, too coarse for "the last 5 minutes". Nothing here touches disk,
/// so it works with history turned off, and it's gone when Undertow quits.
///
/// Not thread-safe. The monitor only uses it on its own queue.
public final class RecentUsage {
    public let window: TimeInterval
    public let bucketSeconds: TimeInterval
    private var buckets: [Int: [String: [String: (rx: UInt64, tx: UInt64)]]] = [:]
    private var names: [String: (name: String, path: String?)] = [:]
    private var lastPrunedBucket = Int.min

    public init(window: TimeInterval = 360, bucketSeconds: TimeInterval = 5) {
        self.window = window
        self.bucketSeconds = bucketSeconds
    }

    private func bucket(_ date: Date) -> Int { Int((date.timeIntervalSince1970 / bucketSeconds).rounded(.down)) }

    public func add(now: Date, app: String, name: String, path: String?, ip: String, rx: UInt64, tx: UInt64) {
        let b = bucket(now)
        var perApp = buckets[b] ?? [:]
        var perIP = perApp[app] ?? [:]
        let previous = perIP[ip] ?? (0, 0)
        perIP[ip] = (previous.rx + rx, previous.tx + tx)
        perApp[app] = perIP
        buckets[b] = perApp
        names[app] = (name, path)
        if b != lastPrunedBucket { prune(now: now) }
    }

    /// Drops buckets that have aged out of the window, and names no longer needed.
    public func prune(now: Date) {
        let oldest = bucket(now.addingTimeInterval(-window))
        buckets = buckets.filter { $0.key >= oldest }
        let live = Set(buckets.values.flatMap(\.keys))
        names = names.filter { live.contains($0.key) }
        lastPrunedBucket = bucket(now)
    }

    /// A bucket counts if it started at or after `since`, so a total can include up to one
    /// bucket (5 seconds) less than the full span, but never anything older.
    private func entries(since: Date) -> [(app: String, ip: String, rx: UInt64, tx: UInt64)] {
        let first = Int((since.timeIntervalSince1970 / bucketSeconds).rounded(.up))
        var out: [(String, String, UInt64, UInt64)] = []
        for (b, perApp) in buckets where b >= first {
            for (app, perIP) in perApp {
                for (ip, t) in perIP { out.append((app, ip, t.rx, t.tx)) }
            }
        }
        return out
    }

    private func usageTotals(_ items: [(app: String, ip: String, rx: UInt64, tx: UInt64)]) -> [UsageTotal] {
        var totals: [String: UsageTotal] = [:]
        for e in items {
            var t = totals[e.app] ?? UsageTotal(id: e.app, name: names[e.app]?.name ?? e.app, path: names[e.app]?.path, rx: 0, tx: 0)
            t.rx += e.rx
            t.tx += e.tx
            totals[e.app] = t
        }
        return totals.values.sorted { ($0.rx + $0.tx, $0.id) > ($1.rx + $1.tx, $1.id) }
    }

    public func topApps(since: Date) -> [UsageTotal] {
        usageTotals(entries(since: since))
    }

    public func topDestinations(since: Date, app: String? = nil) -> [DestinationTotal] {
        var totals: [String: DestinationTotal] = [:]
        for e in entries(since: since) where app == nil || e.app == app {
            var t = totals[e.ip] ?? DestinationTotal(ip: e.ip, rx: 0, tx: 0)
            t.rx += e.rx
            t.tx += e.tx
            totals[e.ip] = t
        }
        return Array(totals.values)
    }

    /// Which apps talked to these addresses, for "who's talking to it" in a destination's detail.
    public func apps(forIPs ips: [String], since: Date) -> [UsageTotal] {
        let wanted = Set(ips)
        return usageTotals(entries(since: since).filter { wanted.contains($0.ip) })
    }
}
