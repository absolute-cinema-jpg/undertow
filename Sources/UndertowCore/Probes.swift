import CShim
import Darwin
import Foundation

// MARK: - IP helpers

public enum IPScope: Equatable, Sendable { case loopback, local, publicNet }

public enum IP {
    /// Canonical 16-byte form (IPv4 as ::ffff:a.b.c.d). Byte order sorts numerically,
    /// which is what lets the owner table use a plain range lookup.
    public static func canonical(_ text: String) -> [UInt8]? {
        var v6 = in6_addr()
        if inet_pton(AF_INET6, text, &v6) == 1 {
            return withUnsafeBytes(of: &v6) { Array($0) }
        }
        var v4 = in_addr()
        if inet_pton(AF_INET, text, &v4) == 1 {
            let bytes = withUnsafeBytes(of: &v4) { Array($0) }
            return [UInt8](repeating: 0, count: 10) + [0xff, 0xff] + bytes
        }
        return nil
    }

    public static func scope(of text: String) -> IPScope {
        guard let b = canonical(text) else { return .local }
        let isV4 = b[0..<10].allSatisfy { $0 == 0 } && b[10] == 0xff && b[11] == 0xff
        if isV4 {
            let (a, c) = (b[12], b[13])
            if a == 127 { return .loopback }
            if a == 0 || a == 10 { return .local }
            if a == 172, (16...31).contains(c) { return .local }
            if a == 192, c == 168 { return .local }
            if a == 169, c == 254 { return .local }
            if a == 100, (64...127).contains(c) { return .local }  // CGNAT, used by Tailscale etc.
            if a >= 224 { return .local }  // multicast + broadcast
            return .publicNet
        }
        if b[0..<15].allSatisfy({ $0 == 0 }) { return b[15] == 1 ? .loopback : .local }
        if b[0] == 0xfe, b[1] & 0xc0 == 0x80 { return .local }  // link-local
        if b[0] & 0xfe == 0xfc { return .local }  // unique-local
        if b[0] == 0xff { return .local }  // multicast
        return .publicNet
    }
}

// MARK: - netstat

public enum TransportProto: String, Codable, Sendable { case tcp = "TCP", udp = "UDP" }

/// Identifies one socket from one sample to the next.
public enum SocketKey: Hashable, Sendable {
    case generation(UInt64)
    case tuple(String)
}

public struct SocketRow: Equatable, Sendable {
    /// Kernel generation count, unique per socket. Connections made through Apple's Network
    /// framework (and so URLSession) report zero, so it can't be relied on alone: see `key`.
    public var gen: UInt64
    public var proto: TransportProto
    public var localIP: String?
    public var localPort: Int?
    public var remoteIP: String?
    public var remotePort: Int?
    public var state: String
    public var rx: UInt64
    public var tx: UInt64
    public var pid: Int32
    public var epid: Int32

    public init(gen: UInt64, proto: TransportProto, localIP: String?, localPort: Int?, remoteIP: String?, remotePort: Int?,
                state: String, rx: UInt64, tx: UInt64, pid: Int32, epid: Int32) {
        self.gen = gen
        self.proto = proto
        self.localIP = localIP
        self.localPort = localPort
        self.remoteIP = remoteIP
        self.remotePort = remotePort
        self.state = state
        self.rx = rx
        self.tx = tx
        self.pid = pid
        self.epid = epid
    }

    /// `epid` is the process a socket was opened on behalf of, when delegated.
    public var ownerPID: Int32 { epid > 0 ? epid : pid }

    /// The generation count when there is one, otherwise the connection's addresses and owner.
    public var key: SocketKey {
        if gen != 0 { return .generation(gen) }
        return .tuple("\(proto.rawValue)|\(localIP ?? "*"):\(localPort ?? 0)|\(remoteIP ?? "*"):\(remotePort ?? 0)|\(pid)|\(epid)")
    }
}

public enum NetstatParser {
    /// Splits "1.2.3.4.443", "fe80::1%en0.5353", "*.5353" or "*.*" at the final dot.
    static func endpoint(_ field: Substring) -> (ip: String?, port: Int?) {
        guard let dot = field.lastIndex(of: ".") else { return (nil, nil) }
        var host = field[..<dot]
        if let zone = host.firstIndex(of: "%") { host = host[..<zone] }
        var ip = host == "*" ? nil : String(host)
        if let mapped = ip, mapped.hasPrefix("::ffff:"), mapped.contains(".") {
            ip = String(mapped.dropFirst(7))
        }
        return (ip, Int(field[field.index(after: dot)...]))
    }

    /// Parses `netstat -anvbW`. TCP rows carry a state column and UDP rows leave it
    /// blank, so every column after the addresses is offset by one for TCP.
    ///
    /// This runs every second over about 140 KB of text, so it scans bytes. Swift's
    /// Character-based `split` walks grapheme clusters, which cost about 20 ms per call here.
    /// Sockets with no traffic are skipped: they can't contribute a delta, and if one later
    /// gets traffic, the tracker correctly treats it as new.
    public static func parse(_ text: String) -> [SocketRow] {
        var copy = text
        return copy.withUTF8 { parse(bytes: $0) }
    }

    private static func parse(bytes: UnsafeBufferPointer<UInt8>) -> [SocketRow] {
        var rows: [SocketRow] = []
        rows.reserveCapacity(256)
        guard let base = bytes.baseAddress else { return rows }
        let count = bytes.count
        var starts = [Int](repeating: 0, count: 16)
        var ends = [Int](repeating: 0, count: 16)
        var lineStart = 0

        while lineStart < count {
            let remaining = count - lineStart
            let lineEnd: Int
            if let nl = memchr(base + lineStart, 0x0A, remaining) {
                lineEnd = base.distance(to: nl.assumingMemoryBound(to: UInt8.self))
            } else {
                lineEnd = count
            }
            defer { lineStart = lineEnd + 1 }

            // Quick rejection covers the Unix socket lines and headers.
            guard lineEnd - lineStart > 3 else { continue }
            let (b0, b1, b2) = (base[lineStart], base[lineStart + 1], base[lineStart + 2])
            let isTCP = b0 == 0x74 && b1 == 0x63 && b2 == 0x70  // "tcp"
            let isUDP = b0 == 0x75 && b1 == 0x64 && b2 == 0x70  // "udp"
            guard isTCP || isUDP else { continue }

            // Column positions, up to and including gencnt.
            let needed = (isTCP ? 6 : 5) + 9
            var field = 0
            var i = lineStart
            while i < lineEnd, field < needed {
                while i < lineEnd, base[i] == 0x20 { i += 1 }
                guard i < lineEnd else { break }
                starts[field] = i
                while i < lineEnd, base[i] != 0x20 { i += 1 }
                ends[field] = i
                field += 1
            }
            guard field == needed else { continue }

            let o = isTCP ? 6 : 5
            func number(_ f: Int, radix: UInt64 = 10) -> UInt64? {
                guard starts[f] < ends[f] else { return nil }
                var value: UInt64 = 0
                for j in starts[f]..<ends[f] {
                    let c = base[j]
                    let digit: UInt64
                    switch c {
                    case 0x30...0x39: digit = UInt64(c - 0x30)
                    case 0x61...0x66 where radix == 16: digit = UInt64(c - 0x61 + 10)
                    default: return nil
                    }
                    value = value &* radix &+ digit
                }
                return value
            }
            guard let rx = number(o), let tx = number(o + 1),
                let pid = number(o + 4), let epid = number(o + 5),
                let gen = number(o + 8, radix: 16)
            else { continue }
            if rx == 0, tx == 0 { continue }

            func text(_ f: Int) -> String {
                String(decoding: UnsafeBufferPointer(start: base + starts[f], count: ends[f] - starts[f]), as: UTF8.self)
            }
            let local = endpoint(Substring(text(3)))
            let remote = endpoint(Substring(text(4)))
            rows.append(
                SocketRow(
                    gen: gen, proto: isTCP ? .tcp : .udp,
                    localIP: local.ip, localPort: local.port,
                    remoteIP: remote.ip, remotePort: remote.port,
                    state: isTCP ? text(5) : "",
                    rx: rx, tx: tx, pid: Int32(truncatingIfNeeded: pid), epid: Int32(truncatingIfNeeded: epid)))
        }
        return rows
    }
}

// MARK: - Delta tracking

public struct FlowDelta: Equatable, Sendable {
    public var row: SocketRow
    public var rx: UInt64
    public var tx: UInt64
}

/// Turns cumulative per-socket counters into per-interval deltas.
public final class FlowTracker {
    private var last: [SocketKey: (rx: UInt64, tx: UInt64)] = [:]
    private var hasBaseline = false
    public init() {}

    /// The first call only records a baseline: sockets already open hold their whole
    /// lifetime's bytes, and reporting those would show a false multi-GB spike at launch.
    /// After that, a socket we haven't seen is new, so all of its bytes are fresh. That
    /// includes connections that opened and closed between polls and now sit in TIME_WAIT.
    public func ingest(_ rows: [SocketRow]) -> [FlowDelta] {
        var next: [SocketKey: (rx: UInt64, tx: UInt64)] = [:]
        next.reserveCapacity(rows.count)
        var out: [FlowDelta] = []
        for row in rows {
            let key = row.key
            guard next[key] == nil else { continue }
            let prev = last[key] ?? (0, 0)
            // Remembers the highest value seen, so a counter that ever dips can't be counted twice.
            next[key] = (max(prev.rx, row.rx), max(prev.tx, row.tx))
            guard hasBaseline else { continue }
            let dRx = row.rx >= prev.rx ? row.rx - prev.rx : 0
            let dTx = row.tx >= prev.tx ? row.tx - prev.tx : 0
            if dRx > 0 || dTx > 0 { out.append(FlowDelta(row: row, rx: dRx, tx: dTx)) }
        }
        last = next
        hasBaseline = true
        return out
    }
}

// MARK: - Interface counters

public struct InterfaceCounter: Sendable {
    public var name: String
    public var rx: UInt64
    public var tx: UInt64
    public var isUp: Bool

    /// Real hardware. Tunnels are excluded because their traffic is also counted on the
    /// interface that carries the tunnel, so summing both would double-count VPN traffic.
    public var isPhysical: Bool { name.hasPrefix("en") }
    public var isTunnel: Bool {
        name.hasPrefix("utun") || name.hasPrefix("ipsec") || name.hasPrefix("ppp") || name.hasPrefix("tun")
    }
}

public enum Interfaces {
    public static func readCounters() -> [InterfaceCounter] {
        var buf = [un_if_counter](repeating: un_if_counter(), count: 64)
        let n = Int(un_read_if_counters(&buf, 64))
        return buf.prefix(n).map { c in
            let name = withUnsafeBytes(of: c.name) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
            return InterfaceCounter(name: name, rx: c.rx, tx: c.tx, isUp: c.flags & UInt32(IFF_UP) != 0)
        }
    }

    /// Maps each local IP to the interface that owns it, used to tell which interface a socket is on.
    public static func addressMap() -> [String: String] {
        var map: [String: String] = [:]
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return map }
        defer { freeifaddrs(head) }
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            guard let sa = entry.pointee.ifa_addr else { continue }
            let family = Int32(sa.pointee.sa_family)
            guard family == AF_INET || family == AF_INET6 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let len = socklen_t(sa.pointee.sa_len)
            guard getnameinfo(sa, len, &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            var ip = String(cString: host)
            if let zone = ip.firstIndex(of: "%") { ip = String(ip[..<zone]) }
            map[ip] = String(cString: entry.pointee.ifa_name)
        }
        return map
    }
}

// MARK: - Routes

public struct RouteInfo: Equatable, Sendable {
    public var defaultInterface: String?
    /// The real router, even while a VPN holds the default route.
    public var physicalGateway: String?
    public var physicalInterface: String?
    public var vpnActive: Bool {
        guard let d = defaultInterface else { return false }
        return d.hasPrefix("utun") || d.hasPrefix("ipsec") || d.hasPrefix("ppp") || d.hasPrefix("tun")
    }
    public init(defaultInterface: String? = nil, physicalGateway: String? = nil, physicalInterface: String? = nil) {
        self.defaultInterface = defaultInterface
        self.physicalGateway = physicalGateway
        self.physicalInterface = physicalInterface
    }
}

public enum RouteParser {
    /// Parses `netstat -rn -f inet`. Default routes are listed highest priority first.
    public static func parse(_ text: String) -> RouteInfo {
        var info = RouteInfo()
        for line in text.split(separator: "\n") where line.hasPrefix("default") {
            let f = line.split(separator: " ", omittingEmptySubsequences: true)
            guard f.count >= 4 else { continue }
            let gateway = String(f[1])
            let iface = String(f[3])
            if info.defaultInterface == nil { info.defaultInterface = iface }
            if info.physicalGateway == nil, iface.hasPrefix("en"), IP.canonical(gateway) != nil {
                info.physicalGateway = gateway
                info.physicalInterface = iface
            }
        }
        return info
    }
}

// MARK: - nettop (TCP quality, only sampled while the panel is open)

public struct TCPQuality: Sendable {
    public var rttMs: Double?
    public var retransmitted: UInt64
    public var sent: UInt64
}

public enum NettopParser {
    /// Parses `nettop -m tcp -L 1 -n -x -J bytes_out,re-tx,rtt_avg`, keyed "remoteIP|remotePort".
    /// nettop may reorder columns, so positions are read from its header row.
    public static func parse(_ text: String) -> [String: TCPQuality] {
        var out: [String: TCPQuality] = [:]
        var col: [String: Int] = [:]
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let f = line.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            if col.isEmpty {
                if f.contains("rtt_avg") { for (i, n) in f.enumerated() { col[n] = i } }
                continue
            }
            guard let first = f.first, first.hasPrefix("tcp"), let arrow = first.range(of: "<->") else { continue }
            let remote = first[arrow.upperBound...]
            let isV4 = first.hasPrefix("tcp4")
            guard let sep = isV4 ? remote.lastIndex(of: ":") : remote.lastIndex(of: "."),
                let port = Int(remote[remote.index(after: sep)...])
            else { continue }
            var host = String(remote[..<sep])
            if let zone = host.firstIndex(of: "%") { host = String(host[..<zone]) }
            func field(_ name: String) -> String? {
                guard let i = col[name], i < f.count else { return nil }
                return f[i]
            }
            let rtt = field("rtt_avg").flatMap { Double($0.replacingOccurrences(of: " ms", with: "")) }
            let retx = field("re-tx").flatMap { UInt64($0) } ?? 0
            let sent = field("bytes_out").flatMap { UInt64($0) } ?? 0
            let key = "\(host)|\(port)"
            var merged = out[key] ?? TCPQuality(rttMs: nil, retransmitted: 0, sent: 0)
            merged.rttMs = rtt ?? merged.rttMs
            merged.retransmitted += retx
            merged.sent += sent
            out[key] = merged
        }
        return out
    }
}

// MARK: - Ping

public enum PingParser {
    /// Reads the average from "round-trip min/avg/max/stddev = 1.0/2.0/3.0/0.1 ms". nil = no reply.
    public static func parse(_ text: String) -> Double? {
        guard let line = text.split(separator: "\n").first(where: { $0.contains("min/avg") }),
            let eq = line.firstIndex(of: "=")
        else { return nil }
        let parts = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces).split(separator: "/")
        return parts.count >= 2 ? Double(parts[1]) : nil
    }
}

// MARK: - Running tools

public enum Shell {
    /// Runs a tool by absolute path with no shell involved, so nothing can be injected
    /// through arguments. Returns stdout, or nil if the tool failed to start.
    ///
    /// Uses posix_spawn rather than Foundation's Process, which costs noticeably more CPU
    /// at once a second. CLOEXEC_DEFAULT keeps our open files, including the history
    /// database, from being inherited by the child.
    public static func run(_ path: String, _ args: [String]) -> String? {
        var fds: [Int32] = [0, 0]
        guard pipe(&fds) == 0 else { return nil }
        let (readEnd, writeEnd) = (fds[0], fds[1])
        defer { close(readEnd) }

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, writeEnd, 1)
        posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0)

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT))

        var argv: [UnsafeMutablePointer<CChar>?] = ([path] + args).map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }
        var envp: [UnsafeMutablePointer<CChar>?] = [nil]

        var pid: pid_t = 0
        let spawned = posix_spawn(&pid, path, &actions, &attributes, &argv, &envp)
        close(writeEnd)
        guard spawned == 0 else { return nil }

        var output = [UInt8]()
        output.reserveCapacity(1 << 17)
        var chunk = [UInt8](repeating: 0, count: 1 << 16)
        while true {
            let n = read(readEnd, &chunk, chunk.count)
            if n > 0 {
                output.append(contentsOf: chunk[0..<n])
            } else if n == 0 || errno != EINTR {
                break
            }
        }
        var status: Int32 = 0
        while waitpid(pid, &status, 0) == -1, errno == EINTR {}
        return String(decoding: output, as: UTF8.self)
    }

    /// One call covers both IPv4 and IPv6. It also lists Unix sockets, which the parser skips.
    public static func readSockets() -> [SocketRow] {
        NetstatParser.parse(run("/usr/sbin/netstat", ["-anvbW"]) ?? "")
    }

    public static func readRoutes() -> RouteInfo {
        RouteParser.parse(run("/usr/sbin/netstat", ["-rn", "-f", "inet"]) ?? "")
    }

    public static func readTCPQuality() -> [String: TCPQuality] {
        NettopParser.parse(run("/usr/bin/nettop", ["-m", "tcp", "-L", "1", "-n", "-x", "-J", "bytes_out,re-tx,rtt_avg"]) ?? "")
    }

    /// One ping with a 2 second limit. Only used while the panel is open.
    public static func ping(_ host: String) -> Double? {
        guard IP.canonical(host) != nil else { return nil }
        return PingParser.parse(run("/sbin/ping", ["-n", "-q", "-c", "1", "-t", "2", host]) ?? "")
    }
}
