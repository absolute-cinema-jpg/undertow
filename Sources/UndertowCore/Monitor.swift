import CoreGraphics
import Foundation
import SystemConfiguration

// MARK: - Published values

public struct Throughput: Equatable, Sendable {
    public var down: Double = 0
    public var up: Double = 0
    public init(down: Double = 0, up: Double = 0) {
        self.down = down
        self.up = up
    }
}

/// The small value the menu bar needs every tick, cheap enough to produce constantly.
public struct Headline: Equatable, Sendable {
    public var date = Date()
    public var internet = Throughput()
    public var local = Throughput()
    public var envelope = Throughput()
    public var wire = Throughput()

    public init() {}

    public func value(for measure: Measure) -> Throughput {
        switch measure {
        case .internet: return internet
        case .allApps: return Throughput(down: internet.down + local.down, up: internet.up + local.up)
        case .wire: return wire
        }
    }
}

public struct LiveConnection: Identifiable, Equatable, Sendable {
    public var id: String
    public var remoteIP: String?
    public var remotePort: Int?
    public var proto: TransportProto
    public var interface: String?
    public var cls: FlowClass
    public var down: Double
    public var up: Double
    public var totalDown: UInt64
    public var totalUp: UInt64
    public var sockets: Int
    public var outsideVPN: Bool
    public var rttMs: Double?
    public var destination: Destination
}

public struct Destination: Equatable, Sendable {
    public var key: String
    public var label: String
    public var countryCode: String?
    public var hostname: String?
    public var rawOwner: String?
    public var asn: Int?
}

public struct LiveApp: Identifiable, Equatable, Sendable {
    public var id: String { identity.id }
    public var identity: AppIdentity
    public var signer: SignerInfo?
    public var down: Double
    public var up: Double
    /// The part of `down` and `up` going to the internet, so rows add up to the headline.
    public var internetDown: Double
    public var internetUp: Double
    public var totalDown: UInt64
    public var totalUp: UInt64
    public var isNew: Bool
    public var trusted: Bool
    /// Checked against the signature, not taken from what the app says about itself.
    public var verifiedApple: Bool
    public var verifiedTunnel: Bool
    /// Still having its signature checked.
    public var signerPending: Bool
    public var connections: [LiveConnection]
    /// True when everything this app did is on the local network, or is a VPN envelope.
    public var primaryClass: FlowClass
}

public struct LiveDestination: Identifiable, Equatable, Sendable {
    public var id: String { destination.key }
    public var destination: Destination
    public var cls: FlowClass
    public var down: Double
    public var up: Double
    public var totalDown: UInt64
    public var totalUp: UInt64
    public var ips: [String]
    public var hostnames: [String]
    public var appIDs: [String]
    public var appNames: [String]
}

public struct Health: Equatable, Sendable {
    public var router = LatencyStats()
    public var internet = LatencyStats()
    public var routerAddress: String?
    public var retransmitPercent: Double?
    public var verdict = Verdict(level: .measuring, title: "Measuring…", detail: "Checking the latency to your router and the internet.")
    public init() {}
}

public struct Detail: Equatable, Sendable {
    public var apps: [LiveApp] = []
    public var destinations: [LiveDestination] = []
    public var health = Health()
    public var route = RouteInfo()
    public var vpnName: String?
    public var interfaceName: String?
    public var learningRemaining: TimeInterval = 0
    public var ownerTableAvailable = false
    public init() {}
}

// MARK: - Monitor

/// Samples the network on a background queue and hands results to the main thread.
///
/// Cost is kept low because this runs all day: netstat takes about 2 ms, and the heavier
/// probes (nettop at about 180 ms, ping) only run while the panel is open.
public final class Monitor {
    public struct Paths {
        public var ledger: String
        public var owners: String
        public init(ledger: String, owners: String) {
            self.ledger = ledger
            self.owners = owners
        }
    }

    public var onHeadline: ((Headline) -> Void)?
    public var onDetail: ((Detail) -> Void)?
    public var onEvents: (([WatchEvent]) -> Void)?

    public let ledger: Ledger?
    public let owners: OwnerDatabase

    private let queue = DispatchQueue(label: "undertow.monitor", qos: .utility)
    private let probeQueue = DispatchQueue(label: "undertow.probes", qos: .utility)
    private var timer: DispatchSourceTimer?

    private let tracker = FlowTracker()
    private let resolver = IdentityResolver()
    private let rdns = ReverseDNS()
    private var detector: Detector

    private var prefs: Prefs
    private var panelOpen = false
    /// By path, because a bundle ID is only a claim and another app could copy ours.
    private let ownExecutable = Bundle.main.executablePath

    private var lastTick: UInt64 = 0
    private var lastCounters: [String: (rx: UInt64, tx: UInt64)] = [:]
    private var addressMap: [String: String] = [:]
    private var route = RouteInfo()
    private var interfaceNames: [String: String] = [:]
    private var tickCount = 0

    private var signers: [String: (info: SignerInfo, stamp: Int)] = [:]
    private var signerInFlight: Set<String> = []
    private let signingQueue: OperationQueue = {
        let q = OperationQueue()
        q.maxConcurrentOperationCount = 2
        q.qualityOfService = .utility
        q.name = "undertow.signing"
        return q
    }()
    /// Traffic waiting for its app's signature check. Alerts can't be decided until then,
    /// or a real Apple app would look unsigned for its first few seconds.
    private var pendingFlows: [String: ObservedFlow] = [:]
    private var activePairs = Set<String>()
    private var lastPrune: Date?
    private var tunnelActive = false
    private var nextLocalEventID: Int64 = -1
    private var ownerCache: [String: OwnerRecord?] = [:]

    private struct ConnAgg {
        var ip: String?
        var port: Int?
        var proto: TransportProto
        var iface: String?
        var cls: FlowClass
        var down = 0.0
        var up = 0.0
        var totalDown: UInt64 = 0
        var totalUp: UInt64 = 0
        var outsideVPN = false
        var sockets = Set<SocketKey>()
        var lastActive: UInt64 = 0
    }
    private struct AppAgg {
        var identity: AppIdentity
        var down = 0.0
        var up = 0.0
        var totalDown: UInt64 = 0
        var totalUp: UInt64 = 0
        var conns: [String: ConnAgg] = [:]
        var isNewThisSession = false
    }
    private var apps: [String: AppAgg] = [:]

    private var peak = Throughput()
    private var routerWindow: [Double?] = []
    private var internetWindow: [Double?] = []
    private var quality: [String: TCPQuality] = [:]
    private var lastRetransmit: (retx: UInt64, sent: UInt64)?
    private var retransmitPercent: Double?
    private var lastProbe: UInt64 = 0
    private var probeRunning = false
    private var lastHeadline = Headline()

    public init(paths: Paths, prefs: Prefs, now: Date = Date()) {
        self.prefs = prefs
        ledger = Ledger(path: paths.ledger)
        owners = OwnerDatabase(path: paths.owners)
        let install = ledger?.installDate(now: now) ?? now
        detector = Detector(
            config: prefs.detectorConfig, installDate: install,
            knownApps: ledger?.knownApps() ?? [], knownPairs: ledger?.knownPairs() ?? [],
            trusted: ledger?.trustedApps() ?? [:])
        rdns.enabled = prefs.reverseDNS
    }

    public func start() {
        queue.async { [self] in
            refreshSlowState()
            tick()  // establishes the baseline
            schedule()
        }
    }

    private func schedule() {
        timer?.cancel()
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + prefs.interval, repeating: prefs.interval, leeway: .milliseconds(100))
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    public func update(prefs newPrefs: Prefs) {
        queue.async { [self] in
            let intervalChanged = prefs.interval != newPrefs.interval
            if prefs.retentionDays != newPrefs.retentionDays { lastPrune = nil }
            prefs = newPrefs
            detector.config = newPrefs.detectorConfig
            rdns.enabled = newPrefs.reverseDNS
            if intervalChanged { schedule() }
        }
    }

    public func setPanelOpen(_ open: Bool) {
        queue.async { [self] in
            panelOpen = open
            if open {
                routerWindow.removeAll()
                internetWindow.removeAll()
                lastProbe = 0
                lastRetransmit = nil
                publishDetail()
            }
        }
    }

    public func setTrusted(appID: String, trusted: Bool) {
        queue.async { [self] in
            let live = apps[appID]?.identity
            let stored = ledger?.path(app: appID)
            let name = live?.name ?? stored?.name ?? appID
            let path = live?.path ?? stored?.path
            let isSystem = live?.kind == .system || live?.kind == .kernel || appID.hasPrefix("system:")

            func apply(_ key: String?) {
                detector.setTrusted(appID, key: key)
                ledger?.setTrusted(app: appID, name: name, path: path, key: key, now: Date())
                if panelOpen { publishDetail() }
            }
            guard trusted else { return apply(nil) }
            if isSystem { return apply("system") }
            guard let path else { return }
            // Always a fresh check: this is the moment the signature gets written down.
            signingQueue.addOperation { [weak self] in
                let key = CodeSigning.inspect(path: path).trustKey
                self?.queue.async { if let key { apply(key) } }
            }
        }
    }

    public func flush() {
        queue.sync { ledger?.flush() }
    }

    /// Drops cached owner lookups after a new table is installed.
    public func ownerTableChanged() {
        queue.async { [self] in
            ownerCache.removeAll()
            if panelOpen { publishDetail() }
        }
    }

    /// Rebuilds the detector from what's now stored, so a reset takes effect without a relaunch.
    public func reloadBaseline(now: Date = Date()) {
        queue.async { [self] in
            detector = Detector(
                config: prefs.detectorConfig, installDate: ledger?.installDate(now: now) ?? now,
                knownApps: ledger?.knownApps() ?? [], knownPairs: ledger?.knownPairs() ?? [],
                trusted: ledger?.trustedApps() ?? [:])
            for key in apps.keys { apps[key]?.isNewThisSession = false }
            if panelOpen { publishDetail() }
        }
    }

    public func clearSession() {
        queue.async { [self] in
            for key in apps.keys {
                apps[key]?.totalDown = 0
                apps[key]?.totalUp = 0
                apps[key]?.conns.removeAll()
            }
            if panelOpen { publishDetail() }
        }
    }

    // MARK: Sampling

    private func refreshSlowState() {
        addressMap = Interfaces.addressMap()
        route = Shell.readRoutes()
        // Every Mac has idle utun interfaces with link-local addresses. A real address means
        // a tunnel is really up, including VPNs that don't take the default route.
        tunnelActive = route.vpnActive || addressMap.contains { Self.isTunnel($0.value) && !$0.key.hasPrefix("fe80") }
    }

    private func tick() {
        let nowNS = DispatchTime.now().uptimeNanoseconds
        let dt = lastTick == 0 ? prefs.interval : Double(nowNS - lastTick) / 1e9
        lastTick = nowNS
        tickCount += 1
        if tickCount % 10 == 0 { refreshSlowState() }

        let now = Date()
        resolver.observeRunningProcesses(now: now)
        let rows = Shell.readSockets()
        let deltas = tracker.ingest(rows)
        // Check signatures up front, so the VPN is recognised before its traffic is counted.
        if tickCount == 1 {
            for pid in Set(rows.map(\.ownerPID)) { _ = signer(for: resolver.identity(for: pid)) }
        }
        let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)

        var headline = Headline()
        headline.date = now
        headline.wire = readWire(dt: dt)

        var tickRates: [String: [String: (rx: UInt64, tx: UInt64)]] = [:]
        var newEvents: [WatchEvent] = replayPendingFlows(now: now, idle: idle)

        for delta in deltas {
            let row = delta.row
            let identity = resolver.identity(for: row.ownerPID)
            let iface = row.localIP.flatMap { addressMap[$0] }
            let onTunnel = iface.map(Self.isTunnel) ?? false
            let currentSigner = signer(for: identity)
            let cls = FlowClassifier.classify(
                row, isVerifiedTunnel: currentSigner?.isPacketTunnel ?? false, tunnelActive: tunnelActive,
                onTunnelInterface: onTunnel, isVerifiedSystem: identity.isVerifiedApple(signer: currentSigner))
            guard cls != .ignored else { continue }

            let down = Double(delta.rx) / dt
            let up = Double(delta.tx) / dt
            switch cls {
            case .internet:
                headline.internet.down += down
                headline.internet.up += up
            case .local:
                headline.local.down += down
                headline.local.up += up
            case .envelope:
                headline.envelope.down += down
                headline.envelope.up += up
            case .ignored:
                break
            }

            // Public traffic that left through real hardware while a VPN holds the default route.
            let outsideVPN = route.vpnActive && cls == .internet && row.remoteIP != nil && iface != nil && !onTunnel

            let connKey = "\(row.remoteIP ?? "*")|\(row.remotePort.map(String.init) ?? "*")|\(row.proto.rawValue)|\(cls.rawValue)"
            var app = apps[identity.id] ?? AppAgg(identity: identity)
            app.identity = identity
            app.totalDown += delta.rx
            app.totalUp += delta.tx
            var conn = app.conns[connKey] ?? ConnAgg(ip: row.remoteIP, port: row.remotePort, proto: row.proto, iface: iface, cls: cls)
            conn.totalDown += delta.rx
            conn.totalUp += delta.tx
            conn.sockets.insert(row.key)
            conn.lastActive = nowNS
            conn.outsideVPN = conn.outsideVPN || outsideVPN
            conn.iface = iface ?? conn.iface
            app.conns[connKey] = conn
            apps[identity.id] = app

            var bucket = tickRates[identity.id] ?? [:]
            let previous = bucket[connKey] ?? (0, 0)
            bucket[connKey] = (previous.rx + delta.rx, previous.tx + delta.tx)
            tickRates[identity.id] = bucket

            if prefs.recordHistory, cls == .internet || cls == .local {
                ledger?.addUsage(now: now, app: identity.id, ip: row.remoteIP ?? "*", rx: delta.rx, tx: delta.tx)
            }

            // Undertow still lists its own traffic, but it has nothing to gain from alerting about itself.
            if cls == .internet, identity.executable == nil || identity.executable != ownExecutable {
                let destination = alertDestination(ip: row.remoteIP)
                let flow = ObservedFlow(
                    app: identity, signer: currentSigner, cls: cls, destination: destination,
                    rx: delta.rx, tx: delta.tx, outsideVPN: outsideVPN, interface: iface.map(interfaceLabel))
                if identity.kind != .exited, delta.tx > 0 { activePairs.insert("\(identity.id)|\(destination)") }
                if identity.path != nil, currentSigner == nil {
                    deferFlow(flow)
                } else {
                    newEvents += detector.observe(flow, now: now, idleSeconds: idle)
                }
            }
        }

        smoothRates(tickRates: tickRates, dt: dt, nowNS: nowNS)
        persistBaseline(now: now)
        dispatchEvents(newEvents)

        let measured = headline.value(for: prefs.measure)
        peak.down = max(peak.down * 0.9995, measured.down)
        peak.up = max(peak.up * 0.9995, measured.up)

        if tickCount % 60 == 0 {
            ledger?.flush()
            if prefs.recordHistory { ledger?.touchPairs(activePairs, now: now) }
            activePairs.removeAll(keepingCapacity: true)
        }
        // By the clock, and straight after launch. A count of samples would never be
        // reached by a Mac that restarts often, and old data would simply stay.
        if lastPrune.map({ now.timeIntervalSince($0) >= 3600 }) ?? true {
            lastPrune = now
            ledger?.prune(olderThanDays: prefs.retentionDays, now: now)
            detector.replaceKnown(apps: ledger?.knownApps() ?? [], pairs: ledger?.knownPairs() ?? [])
        }
        if tickCount % 600 == 0 {
            resolver.prune(keeping: Set(rows.map(\.ownerPID)))
            if ownerCache.count > 20000 { ownerCache.removeAll() }
        }

        lastHeadline = headline
        let publish = onHeadline
        DispatchQueue.main.async { publish?(headline) }

        if panelOpen {
            maybeProbe(nowNS: nowNS)
            publishDetail()
        }
    }

    private func readWire(dt: Double) -> Throughput {
        var wire = Throughput()
        var next: [String: (rx: UInt64, tx: UInt64)] = [:]
        for c in Interfaces.readCounters() {
            next[c.name] = (c.rx, c.tx)
            guard c.isPhysical, let prev = lastCounters[c.name] else { continue }
            wire.down += Double(c.rx >= prev.rx ? c.rx - prev.rx : 0) / dt
            wire.up += Double(c.tx >= prev.tx ? c.tx - prev.tx : 0) / dt
        }
        lastCounters = next
        return wire
    }

    /// Row rates are smoothed so lists stay readable. The headline stays raw, so it's honest.
    private func smoothRates(tickRates: [String: [String: (rx: UInt64, tx: UInt64)]], dt: Double, nowNS: UInt64) {
        let alpha = min(1, dt / 1.5)
        let keepConnectionsFor: UInt64 = 600_000_000_000  // 10 minutes
        for id in Array(apps.keys) {
            guard var app = apps[id] else { continue }
            var appDown = 0.0
            var appUp = 0.0
            for key in Array(app.conns.keys) {
                guard var conn = app.conns[key] else { continue }
                let fresh = tickRates[id]?[key]
                conn.down += alpha * (Double(fresh?.rx ?? 0) / dt - conn.down)
                conn.up += alpha * (Double(fresh?.tx ?? 0) / dt - conn.up)
                if conn.down < 1 { conn.down = 0 }
                if conn.up < 1 { conn.up = 0 }
                if conn.down == 0, conn.up == 0, nowNS - conn.lastActive > keepConnectionsFor {
                    app.conns[key] = nil
                    continue
                }
                appDown += conn.down
                appUp += conn.up
                app.conns[key] = conn
            }
            app.down = appDown
            app.up = appUp
            apps[id] = app
        }
    }

    private func persistBaseline(now: Date) {
        let updates = detector.drainBaselineUpdates()
        for a in updates.apps { apps[a.id]?.isNewThisSession = detector.learningRemaining(now: now) == 0 }
        // With history off, nothing about what talked to what gets written down.
        guard prefs.recordHistory else { return }
        for a in updates.apps { ledger?.recordApp(id: a.id, name: a.name, path: a.path, now: now) }
        for p in updates.pairs { ledger?.recordPair(app: p.app, dest: p.dest, now: now) }
        // Keep names and paths current for apps that were already known, so history can show them.
        if tickCount % 60 == 1 {
            for app in apps.values where app.identity.kind != .exited {
                ledger?.recordApp(id: app.identity.id, name: app.identity.name, path: app.identity.path, now: now)
            }
        }
    }

    private func dispatchEvents(_ events: [WatchEvent]) {
        guard !events.isEmpty else { return }
        var saved: [WatchEvent] = []
        for var e in events {
            if prefs.recordHistory, let id = ledger?.insert(event: e) {
                e.id = id
            } else {
                // Shown until the app quits, but never written to disk.
                e.id = nextLocalEventID
                nextLocalEventID -= 1
            }
            saved.append(e)
        }
        let publish = onEvents
        DispatchQueue.main.async { publish?(saved) }
    }

    private static func isTunnel(_ name: String) -> Bool {
        name.hasPrefix("utun") || name.hasPrefix("ipsec") || name.hasPrefix("ppp") || name.hasPrefix("tun")
    }

    // MARK: Enrichment

    /// Merges waiting traffic per app and destination, so memory stays bounded however long a check takes.
    private func deferFlow(_ flow: ObservedFlow) {
        let key = "\(flow.app.id)|\(flow.destination)|\(flow.outsideVPN)"
        if var existing = pendingFlows[key] {
            existing.rx += flow.rx
            existing.tx += flow.tx
            pendingFlows[key] = existing
        } else if pendingFlows.count < 5000 {
            pendingFlows[key] = flow
        }
    }

    private func replayPendingFlows(now: Date, idle: Double) -> [WatchEvent] {
        guard !pendingFlows.isEmpty else { return [] }
        var events: [WatchEvent] = []
        for (key, var flow) in pendingFlows {
            guard let known = signer(for: flow.app) else { continue }
            flow.signer = known
            pendingFlows[key] = nil
            events += detector.observe(flow, now: now, idleSeconds: idle)
        }
        return events
    }

    /// Changes whenever a file is replaced or edited. Unlike the modification time,
    /// it can't be set back to hide a change.
    private static func changeStamp(_ path: String) -> Int {
        var info = stat()
        guard stat(path, &info) == 0 else { return 0 }
        return info.st_ctimespec.tv_sec
    }

    /// The verified signer, or nil while a check is running. Results are kept until the file
    /// changes, so an app that gets modified or updated while running is checked again.
    private func signer(for identity: AppIdentity) -> SignerInfo? {
        guard let path = identity.path else { return nil }
        let stamp = Self.changeStamp(identity.executable ?? path)
        if let known = signers[path], known.stamp == stamp { return known.info }
        if !signerInFlight.contains(path) {
            signerInFlight.insert(path)
            let operation = BlockOperation { [weak self] in
                let result = CodeSigning.inspect(path: path)
                self?.queue.async {
                    self?.signers[path] = (result, stamp)
                    self?.signerInFlight.remove(path)
                }
            }
            // Extensions are small and decide whether VPN traffic gets counted twice, so they go first.
            if path.hasSuffix(".systemextension") || path.hasSuffix(".appex") { operation.queuePriority = .high }
            signingQueue.addOperation(operation)
        }
        return nil
    }

    private func owner(for ip: String) -> OwnerRecord? {
        if let cached = ownerCache[ip] { return cached }
        let found = owners.lookup(ip)
        ownerCache[ip] = .some(found)
        return found
    }

    /// Picks the best available name for an address. Grouping by owner means 40 Amazon
    /// IPs read as one destination, "Amazon", rather than 40 rows of numbers.
    ///
    /// `lookup` allows a network lookup for the hostname. It's only set while the panel is
    /// open, so Undertow isn't reporting every address you touch to your DNS provider all day.
    private func describe(ip: String?, cls: FlowClass, proto: TransportProto, lookup: Bool = false) -> Destination {
        if cls == .envelope {
            // Kept apart from real destinations: this is the VPN server, not where your data ends up.
            let record = ip.flatMap(owner(for:))
            return Destination(
                key: "vpn:\(ip ?? "*")", label: record.map { "VPN server (\($0.name))" } ?? "VPN server",
                countryCode: record?.countryCode, rawOwner: record?.rawName, asn: record?.asn)
        }
        guard let ip else {
            if cls == .local {
                return Destination(key: "discovery", label: "Local network discovery")
            }
            return Destination(key: "unconnected", label: "Unknown (no fixed destination)")
        }
        let host = lookup ? rdns.name(for: ip) : rdns.cachedName(for: ip)
        if cls == .local {
            return Destination(key: "local:\(ip)", label: host ?? ip, hostname: host)
        }
        if let rec = owner(for: ip) {
            return Destination(
                key: "owner:\(rec.name)", label: rec.name, countryCode: rec.countryCode,
                hostname: host, rawOwner: rec.rawName, asn: rec.asn)
        }
        if let host {
            let parts = host.split(separator: ".")
            let domain = parts.suffix(2).joined(separator: ".")
            return Destination(key: "domain:\(domain)", label: domain, hostname: host)
        }
        return Destination(key: "ip:\(ip)", label: ip)
    }

    /// The name used in alerts and in the record of known destinations. Deliberately ignores
    /// hostnames: their owner chooses them, so they shouldn't decide what counts as "new".
    private func alertDestination(ip: String?) -> String {
        guard let ip else { return "Unknown (no fixed destination)" }
        return owner(for: ip)?.name ?? ip
    }

    private func interfaceLabel(_ bsd: String) -> String {
        if let cached = interfaceNames[bsd] { return cached }
        var label = bsd
        if Self.isTunnel(bsd) {
            label = "VPN tunnel"
        } else if let all = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface],
            let match = all.first(where: { SCNetworkInterfaceGetBSDName($0) as String? == bsd }),
            let name = SCNetworkInterfaceGetLocalizedDisplayName(match) as String? {
            label = name
        }
        interfaceNames[bsd] = label
        return label
    }

    // MARK: Probes (panel open only)

    private func maybeProbe(nowNS: UInt64) {
        guard prefs.healthProbes, !probeRunning, nowNS - lastProbe > 3_000_000_000 else { return }
        probeRunning = true
        lastProbe = nowNS
        let gateway = route.physicalGateway
        let target = prefs.pingTarget
        let wantQuality = tickCount % 2 == 0 || quality.isEmpty
        probeQueue.async { [weak self] in
            let router = gateway.flatMap { Shell.ping($0) }
            let internet = Shell.ping(target)
            let tcp = wantQuality ? Shell.readTCPQuality() : nil
            self?.queue.async { self?.finishProbe(gateway: gateway, router: router, internet: internet, tcp: tcp) }
        }
    }

    private func finishProbe(gateway: String?, router: Double?, internet: Double?, tcp: [String: TCPQuality]?) {
        probeRunning = false
        if gateway != nil {
            routerWindow.append(router)
            if routerWindow.count > 10 { routerWindow.removeFirst() }
        }
        internetWindow.append(internet)
        if internetWindow.count > 10 { internetWindow.removeFirst() }
        if let tcp {
            quality = tcp
            var retx: UInt64 = 0
            var sent: UInt64 = 0
            for (key, q) in tcp {
                guard let host = key.split(separator: "|").first, IP.scope(of: String(host)) == .publicNet else { continue }
                retx += q.retransmitted
                sent += q.sent
            }
            if let last = lastRetransmit, sent >= last.sent, retx >= last.retx, sent - last.sent > 500_000 {
                retransmitPercent = 100 * Double(retx - last.retx) / Double(sent - last.sent)
            } else if lastRetransmit == nil {
                retransmitPercent = nil
            }
            lastRetransmit = (retx, sent)
        }
    }

    // MARK: Publishing

    private func publishDetail() {
        var detail = Detail()
        detail.route = route
        detail.learningRemaining = detector.learningRemaining(now: Date())
        detail.ownerTableAvailable = owners.isAvailable
        detail.interfaceName = route.physicalInterface.map(interfaceLabel)

        var destinations: [String: LiveDestination] = [:]
        var vpnName: String?
        var appList: [LiveApp] = []

        for app in apps.values {
            if app.conns.values.contains(where: { $0.cls == .envelope }) { vpnName = vpnName ?? app.identity.name }
            guard !app.conns.isEmpty || app.down > 0 || app.up > 0 else { continue }
            var connections: [LiveConnection] = []
            var seenClasses = Set<String>()
            for (key, conn) in app.conns {
                let dest = describe(ip: conn.ip, cls: conn.cls, proto: conn.proto, lookup: true)
                let rtt = conn.ip.flatMap { ip in conn.port.flatMap { quality["\(ip)|\($0)"]?.rttMs } }
                seenClasses.insert(conn.cls.rawValue)
                connections.append(LiveConnection(
                    id: key, remoteIP: conn.ip, remotePort: conn.port, proto: conn.proto,
                    interface: conn.iface.map(interfaceLabel), cls: conn.cls,
                    down: conn.down, up: conn.up, totalDown: conn.totalDown, totalUp: conn.totalUp,
                    sockets: conn.sockets.count, outsideVPN: conn.outsideVPN, rttMs: rtt, destination: dest))

                var d = destinations[dest.key] ?? LiveDestination(
                    destination: dest, cls: conn.cls, down: 0, up: 0, totalDown: 0, totalUp: 0,
                    ips: [], hostnames: [], appIDs: [], appNames: [])
                d.down += conn.down
                d.up += conn.up
                d.totalDown += conn.totalDown
                d.totalUp += conn.totalUp
                if let ip = conn.ip, !d.ips.contains(ip) { d.ips.append(ip) }
                if let h = dest.hostname, !d.hostnames.contains(h) { d.hostnames.append(h) }
                if !d.appIDs.contains(app.identity.id) {
                    d.appIDs.append(app.identity.id)
                    d.appNames.append(app.identity.name)
                }
                destinations[dest.key] = d
            }
            connections.sort { ($0.down + $0.up, $0.totalDown + $0.totalUp) > ($1.down + $1.up, $1.totalDown + $1.totalUp) }
            let primary: FlowClass =
                seenClasses.contains(FlowClass.internet.rawValue) ? .internet
                : seenClasses.contains(FlowClass.local.rawValue) ? .local : .envelope
            let appSigner = signer(for: app.identity)
            appList.append(LiveApp(
                identity: app.identity, signer: appSigner,
                down: app.down, up: app.up,
                internetDown: connections.filter { $0.cls == .internet }.reduce(0) { $0 + $1.down },
                internetUp: connections.filter { $0.cls == .internet }.reduce(0) { $0 + $1.up },
                totalDown: app.totalDown, totalUp: app.totalUp,
                isNew: app.isNewThisSession, trusted: detector.isTrusted(app.identity, signer: appSigner),
                verifiedApple: app.identity.isVerifiedApple(signer: appSigner),
                verifiedTunnel: appSigner?.isPacketTunnel ?? false,
                signerPending: app.identity.path != nil && appSigner == nil,
                connections: connections, primaryClass: primary))
        }
        appList.sort { ($0.down + $0.up, $0.totalDown + $0.totalUp) > ($1.down + $1.up, $1.totalDown + $1.totalUp) }
        detail.apps = appList
        detail.destinations = destinations.values.sorted {
            ($0.down + $0.up, $0.totalDown + $0.totalUp) > ($1.down + $1.up, $1.totalDown + $1.totalUp)
        }
        detail.vpnName = route.vpnActive ? (vpnName ?? "VPN") : nil
        detail.health = evaluateHealth(apps: appList, vpnName: detail.vpnName)

        let publish = onDetail
        DispatchQueue.main.async { publish?(detail) }
    }

    private func evaluateHealth(apps: [LiveApp], vpnName: String?) -> Health {
        var health = Health()
        health.routerAddress = route.physicalGateway
        health.router = LatencyStats(routerWindow)
        health.internet = LatencyStats(internetWindow)
        health.retransmitPercent = retransmitPercent
        let measured = lastHeadline.internet
        let internetApps = apps.filter { $0.primaryClass == .internet }
        let topDown = internetApps.max { $0.internetDown < $1.internetDown }
        let topUp = internetApps.max { $0.internetUp < $1.internetUp }
        health.verdict = Diagnosis.evaluate(HealthInput(
            router: health.router, internet: health.internet, hasRouter: route.physicalGateway != nil,
            down: measured.down, up: measured.up, peakDown: peak.down, peakUp: peak.up,
            topDown: topDown.map { ($0.identity.name, $0.internetDown) }, topUp: topUp.map { ($0.identity.name, $0.internetUp) },
            retransmitPercent: retransmitPercent, vpnName: vpnName))
        return health
    }

    // MARK: History queries

    public func lookupDestination(ip: String) -> Destination {
        queue.sync {
            let cls: FlowClass = ip == "*" ? .internet : (IP.scope(of: ip) == .publicNet ? .internet : .local)
            return describe(ip: ip == "*" ? nil : ip, cls: cls, proto: .tcp)
        }
    }
}
