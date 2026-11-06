import Foundation

// MARK: - Flow classification

public enum FlowClass: String, Equatable, Sendable {
    case internet  // a public address, or a UDP socket with no fixed destination
    case local  // your own network: NAS, printer, router, Bonjour
    case envelope  // a VPN's outer socket, which is the same bytes as the traffic inside the tunnel
    case ignored  // loopback: an app talking to itself
}

public enum FlowClassifier {
    /// Discovery protocols broadcast to the local network. They use unconnected sockets,
    /// so the port is the only way to tell them from traffic with an unknown destination.
    static let discoveryPorts: Set<Int> = [5353, 5355, 1900, 137, 138, 67, 68, 3702, 57621]

    /// Two kinds of traffic are left out of the internet total and of alerts, so both must be
    /// earned. An app can't get there by claiming to be a VPN or by picking a particular port.
    ///
    /// - `isVerifiedTunnel`: signed with Apple's restricted VPN entitlement. `tunnelActive`
    ///   adds that a tunnel is actually up, since there's no envelope without one.
    /// - `isVerifiedSystem`: a macOS service. A discovery port alone proves nothing, because
    ///   any app can bind one and send anywhere from it, and netstat can't see the destination.
    public static func classify(_ row: SocketRow, isVerifiedTunnel: Bool, tunnelActive: Bool, onTunnelInterface: Bool, isVerifiedSystem: Bool) -> FlowClass {
        if let local = row.localIP, IP.scope(of: local) == .loopback { return .ignored }
        let isEnvelope = isVerifiedTunnel && tunnelActive && !onTunnelInterface
        guard let remote = row.remoteIP else {
            if isVerifiedSystem, let port = row.localPort, discoveryPorts.contains(port) { return .local }
            return isEnvelope ? .envelope : .internet
        }
        switch IP.scope(of: remote) {
        case .loopback: return .ignored
        case .local: return .local
        case .publicNet: return isEnvelope ? .envelope : .internet
        }
    }
}

// MARK: - Watch events

public enum WatchKind: String, Codable, CaseIterable, Sendable, Identifiable {
    case largeUpload, idleUpload, unsignedSender, outsideVPN, newApp, newDestination
    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .largeUpload: return "Large uploads"
        case .idleUpload: return "Uploads while you're away"
        case .unsignedSender: return "Unsigned apps sending data"
        case .outsideVPN: return "Traffic bypassing the VPN"
        case .newApp: return "Apps using the network for the first time"
        case .newDestination: return "Apps sending data somewhere new"
        }
    }

    public var symbol: String {
        switch self {
        case .largeUpload: return "arrow.up.circle.fill"
        case .idleUpload: return "moon.circle.fill"
        case .unsignedSender: return "exclamationmark.shield.fill"
        case .outsideVPN: return "lock.open.fill"
        case .newApp: return "sparkles"
        case .newDestination: return "mappin.circle.fill"
        }
    }

    public var isHighSignal: Bool { self == .unsignedSender || self == .idleUpload || self == .outsideVPN }
}

public struct WatchEvent: Identifiable, Equatable, Sendable {
    public var id: Int64
    public var date: Date
    public var kind: WatchKind
    public var appID: String
    public var appName: String
    public var title: String
    public var detail: String
    public var read: Bool

    public init(id: Int64 = 0, date: Date, kind: WatchKind, appID: String, appName: String, title: String, detail: String, read: Bool = false) {
        self.id = id
        self.date = date
        self.kind = kind
        self.appID = appID
        self.appName = appName
        self.title = title
        self.detail = detail
        self.read = read
    }
}

public struct DetectorConfig: Equatable, Sendable {
    public var enabled: Set<WatchKind> = Set(WatchKind.allCases)
    public var largeUploadBytes: UInt64 = 100_000_000
    public var idleUploadBytes: UInt64 = 20_000_000
    public var idleAfterSeconds: Double = 300
    public var newDestinationMinUpload: UInt64 = 100_000
    public var outsideVPNMinBytes: UInt64 = 200_000
    /// A process that vanished before it could be named has very little benefit of the doubt.
    public var unidentifiedBytes: UInt64 = 1_000_000
    public var learningSeconds: Double = 86400
    public init() {}
}

/// One interval's traffic between one app and one destination, as seen by the detector.
public struct ObservedFlow: Sendable {
    public var app: AppIdentity
    public var signer: SignerInfo?
    public var cls: FlowClass
    public var destination: String
    public var rx: UInt64
    public var tx: UInt64
    public var outsideVPN: Bool
    public var interface: String?
    public init(app: AppIdentity, signer: SignerInfo?, cls: FlowClass, destination: String, rx: UInt64, tx: UInt64, outsideVPN: Bool, interface: String? = nil) {
        self.app = app
        self.signer = signer
        self.cls = cls
        self.destination = destination
        self.rx = rx
        self.tx = tx
        self.outsideVPN = outsideVPN
        self.interface = interface
    }
}

/// Spots traffic worth a second look. These rules flag things to review, they don't
/// prove anything: a big iCloud upload will trigger the same rule as a real leak.
public final class Detector {
    public var config: DetectorConfig
    /// App ID to the signature it was trusted under. Trust only holds while they still match.
    public private(set) var trusted: [String: String]
    private var knownApps: Set<String>
    private var knownPairs: Set<String>
    private let installDate: Date
    private var cooldowns: [String: Date] = [:]

    private struct Bucket {
        var minute: Int
        var bytes: UInt64
        var idleBytes: UInt64
        var byDest: [String: UInt64]
    }
    private var uploads: [String: [Bucket]] = [:]
    private var outsideVPNBytes: [String: UInt64] = [:]

    /// New pairs waiting to reach the minimum upload size before they count as an alert.
    private var pendingPairBytes: [String: UInt64] = [:]

    public private(set) var newlyKnownApps: [(id: String, name: String, path: String?)] = []
    public private(set) var newlyKnownPairs: [(app: String, dest: String)] = []

    public init(config: DetectorConfig, installDate: Date, knownApps: Set<String>, knownPairs: Set<String>, trusted: [String: String]) {
        self.config = config
        self.installDate = installDate
        self.knownApps = knownApps
        self.knownPairs = knownPairs
        self.trusted = trusted
    }

    /// Pass the app's trust key to trust it, or nil to stop.
    public func setTrusted(_ id: String, key: String?) {
        trusted[id] = key
    }

    public func isTrusted(_ app: AppIdentity, signer: SignerInfo?) -> Bool {
        guard let stored = trusted[app.id], let current = app.trustKey(signer: signer) else { return false }
        return stored == current
    }

    /// Takes in what's still stored after retention has removed old records.
    public func replaceKnown(apps: Set<String>, pairs: Set<String>) {
        knownApps = apps
        knownPairs = pairs
    }

    public func learningRemaining(now: Date) -> TimeInterval {
        max(0, config.learningSeconds - now.timeIntervalSince(installDate))
    }

    public func drainBaselineUpdates() -> (apps: [(id: String, name: String, path: String?)], pairs: [(app: String, dest: String)]) {
        defer {
            newlyKnownApps.removeAll()
            newlyKnownPairs.removeAll()
        }
        return (newlyKnownApps, newlyKnownPairs)
    }

    private func onCooldown(_ key: String, now: Date, seconds: TimeInterval) -> Bool {
        if let until = cooldowns[key], until > now { return true }
        cooldowns[key] = now.addingTimeInterval(seconds)
        return false
    }

    public func observe(_ flow: ObservedFlow, now: Date, idleSeconds: Double) -> [WatchEvent] {
        guard flow.cls == .internet else { return [] }
        let app = flow.app
        var events: [WatchEvent] = []
        let isTrustedNow = isTrusted(app, signer: flow.signer)
        let verifiedApple = app.isVerifiedApple(signer: flow.signer)
        func emit(_ kind: WatchKind, _ title: String, _ detail: String) {
            guard config.enabled.contains(kind), !isTrustedNow else { return }
            events.append(WatchEvent(date: now, kind: kind, appID: app.id, appName: app.name, title: title, detail: detail))
        }
        let learning = learningRemaining(now: now) > 0

        // First time this app has ever been seen on the internet.
        if !knownApps.contains(app.id), app.kind != .exited {
            knownApps.insert(app.id)
            newlyKnownApps.append((app.id, app.name, app.path))
            if !learning, !verifiedApple {
                emit(.newApp, "\(app.name) used the network for the first time", "It connected to \(flow.destination).")
            }
        }

        // An unsigned program sending data can't be tied to any accountable developer.
        if flow.tx > 0, let signer = flow.signer, !verifiedApple {
            let impersonating = app.impersonatesApple(signer: signer)
            if signer.status.isSuspicious || impersonating, !onCooldown("unsigned|\(app.id)", now: now, seconds: 21600) {
                if impersonating {
                    emit(.unsignedSender, "\(app.name) claims to be an Apple app, but isn't signed by Apple", "\(signer.status.label). Sending to \(flow.destination).")
                } else {
                    emit(.unsignedSender, "\(app.name) is sending data without a verified signature", "\(signer.status.label). Sending to \(flow.destination).")
                }
            }
        }

        // Outside the VPN, your ISP can see this traffic. Apple's own services do this by design.
        if flow.outsideVPN, !verifiedApple {
            let total = (outsideVPNBytes[app.id] ?? 0) + flow.rx + flow.tx
            outsideVPNBytes[app.id] = total
            if total >= config.outsideVPNMinBytes, !onCooldown("vpn|\(app.id)", now: now, seconds: 21600) {
                let via = flow.interface.map { " over \($0)" } ?? ""
                emit(.outsideVPN, "\(app.name) is bypassing your VPN", "Connected to \(flow.destination)\(via) instead of through the tunnel.")
            }
        }

        guard flow.tx > 0 else { return events }

        // First time this app has sent a meaningful amount to this destination. Browsers are
        // excluded, because every new website would count. Small requests don't count either.
        let pair = "\(app.id)|\(flow.destination)"
        if app.kind != .exited, !knownPairs.contains(pair) {
            if pendingPairBytes.count > 5000 { pendingPairBytes.removeAll() }
            let sent = (pendingPairBytes[pair] ?? 0) + flow.tx
            if sent >= config.newDestinationMinUpload {
                pendingPairBytes[pair] = nil
                knownPairs.insert(pair)
                newlyKnownPairs.append((app.id, flow.destination))
                if !learning, !app.isVerifiedBrowser(signer: flow.signer), !verifiedApple {
                    emit(.newDestination, "\(app.name) sent data somewhere new", "\(Format.bytes(sent)) to \(flow.destination).")
                }
            } else {
                pendingPairBytes[pair] = sent
            }
        }

        // Rolling 10-minute upload volume per app.
        let minute = Int(now.timeIntervalSince1970 / 60)
        var buckets = uploads[app.id, default: []].filter { $0.minute > minute - 10 }
        if buckets.last?.minute != minute { buckets.append(Bucket(minute: minute, bytes: 0, idleBytes: 0, byDest: [:])) }
        buckets[buckets.count - 1].bytes += flow.tx
        buckets[buckets.count - 1].byDest[flow.destination, default: 0] += flow.tx
        let isIdle = idleSeconds >= config.idleAfterSeconds
        if isIdle { buckets[buckets.count - 1].idleBytes += flow.tx }
        uploads[app.id] = buckets

        let windowTotal = buckets.reduce(UInt64(0)) { $0 + $1.bytes }
        var perDest: [String: UInt64] = [:]
        for b in buckets { perDest.merge(b.byDest, uniquingKeysWith: +) }
        let topDest = perDest.max { $0.value < $1.value }?.key ?? flow.destination

        if app.kind == .exited, windowTotal >= config.unidentifiedBytes, !onCooldown("exited", now: now, seconds: 3600) {
            emit(.unsignedSender, "A process that has already exited sent \(Format.bytes(windowTotal))", "It came and went too quickly to be named. Mostly to \(topDest).")
        }

        if windowTotal >= config.largeUploadBytes, !onCooldown("upload|\(app.id)", now: now, seconds: 3600) {
            emit(.largeUpload, "\(app.name) uploaded \(Format.bytes(windowTotal))", "In the last 10 minutes, mostly to \(topDest).")
        }

        let idleTotal = buckets.reduce(UInt64(0)) { $0 + $1.idleBytes }
        if isIdle, idleTotal >= config.idleUploadBytes, !onCooldown("idle|\(app.id)", now: now, seconds: 3600) {
            emit(.idleUpload, "\(app.name) uploaded \(Format.bytes(idleTotal)) while you were away", "Your Mac had no keyboard or mouse input. Mostly to \(topDest).")
        }
        return events
    }
}

// MARK: - "Why is my internet slow?"

public enum HealthLevel: Int, Sendable { case measuring, good, notice, bad }

public struct Verdict: Equatable, Sendable {
    public var level: HealthLevel
    public var title: String
    public var detail: String
    public init(level: HealthLevel, title: String, detail: String) {
        self.level = level
        self.title = title
        self.detail = detail
    }
}

public struct LatencyStats: Equatable, Sendable {
    public var samples: Int = 0
    public var averageMs: Double?
    public var bestMs: Double?
    public var lossPercent: Double = 0

    public init(samples: Int = 0, averageMs: Double? = nil, bestMs: Double? = nil, lossPercent: Double = 0) {
        self.samples = samples
        self.averageMs = averageMs
        self.bestMs = bestMs
        self.lossPercent = lossPercent
    }

    public init(_ window: [Double?]) {
        samples = window.count
        let replies = window.compactMap { $0 }
        averageMs = replies.isEmpty ? nil : replies.reduce(0, +) / Double(replies.count)
        bestMs = replies.min()
        lossPercent = window.isEmpty ? 0 : 100 * Double(window.count - replies.count) / Double(window.count)
    }
}

public struct HealthInput: Sendable {
    public var router: LatencyStats
    public var internet: LatencyStats
    public var hasRouter: Bool
    public var down: Double
    public var up: Double
    public var peakDown: Double
    public var peakUp: Double
    public var topDown: (name: String, rate: Double)?
    public var topUp: (name: String, rate: Double)?
    public var retransmitPercent: Double?
    public var vpnName: String?

    public init(router: LatencyStats, internet: LatencyStats, hasRouter: Bool, down: Double, up: Double, peakDown: Double, peakUp: Double,
                topDown: (name: String, rate: Double)?, topUp: (name: String, rate: Double)?, retransmitPercent: Double?, vpnName: String?) {
        self.router = router
        self.internet = internet
        self.hasRouter = hasRouter
        self.down = down
        self.up = up
        self.peakDown = peakDown
        self.peakUp = peakUp
        self.topDown = topDown
        self.topUp = topUp
        self.retransmitPercent = retransmitPercent
        self.vpnName = vpnName
    }
}

public enum Diagnosis {
    /// Works outward from your Mac: router, then internet, then what's using the line.
    /// The order matters, because a bad hop makes everything after it look bad too.
    public static func evaluate(_ i: HealthInput) -> Verdict {
        guard i.internet.samples >= 2 else {
            return Verdict(level: .measuring, title: "Measuring…", detail: "Checking the latency to your router and the internet.")
        }
        let beyond = i.vpnName.map { "your VPN (\($0)) or your internet provider" } ?? "your internet provider"

        if i.hasRouter, i.router.samples >= 2 {
            if i.router.lossPercent >= 30 {
                return Verdict(level: .bad, title: "Your connection to the router is dropping",
                               detail: "\(Int(i.router.lossPercent))% of checks to your router got no reply. The problem is between this Mac and your router, often weak Wi-Fi.")
            }
            if let r = i.router.averageMs, r >= 50 {
                return Verdict(level: .bad, title: "Your local network is slow",
                               detail: "Your router is taking \(Int(r)) ms to reply, when under 10 ms is normal. Look at Wi-Fi signal or other devices on your network.")
            }
        }

        if i.internet.lossPercent >= 30 {
            return Verdict(level: .bad, title: "Packets are getting lost past your router",
                           detail: "\(Int(i.internet.lossPercent))% of internet checks failed. Your router is fine, which points to \(beyond).")
        }

        // Latency that climbs under load is the classic sign of a full connection.
        let avg = i.internet.averageMs ?? 0
        let best = i.internet.bestMs ?? avg
        let elevated = avg >= 200 || (avg >= best * 1.8 && avg - best >= 40)
        let upFull = i.up >= 200_000 && i.peakUp > 0 && i.up >= i.peakUp * 0.7
        let downFull = i.down >= 1_000_000 && i.peakDown > 0 && i.down >= i.peakDown * 0.7

        // A full upload hurts more than a full download, because it delays the acks for everything else.
        func culprit() -> String? {
            if upFull, let t = i.topUp { return "\(t.name) is uploading at \(Format.rate(t.rate))" }
            if downFull, let t = i.topDown { return "\(t.name) is downloading at \(Format.rate(t.rate))" }
            return nil
        }

        if elevated {
            if let c = culprit() {
                return Verdict(level: .bad, title: "This Mac is filling your connection",
                               detail: "\(c), and latency has climbed to \(Int(avg)) ms. Pausing it should help.")
            }
            return Verdict(level: .bad, title: "Slow past your router, and it's not this Mac",
                           detail: "Latency is \(Int(avg)) ms but no app here is using much. This points to \(beyond), or another device on your network.")
        }

        if let retx = i.retransmitPercent, retx >= 5 {
            return Verdict(level: .notice, title: "Some data is being resent",
                           detail: "\(String(format: "%.1f", retx))% of data sent had to be sent again. This usually means a congested or unreliable link.")
        }

        if let c = culprit() {
            return Verdict(level: .notice, title: "Busy, but responding well", detail: "\(c). Latency is still a healthy \(Int(avg)) ms.")
        }

        return Verdict(level: .good, title: "Your connection looks healthy",
                       detail: "Nothing here is using much bandwidth and latency is \(Int(avg)) ms. If things still feel slow, the website or service itself may be the cause.")
    }
}
