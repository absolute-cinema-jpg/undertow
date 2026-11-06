import Darwin
import Foundation
import SQLite3

public struct OwnerRecord: Equatable, Sendable {
    public var asn: Int
    public var countryCode: String?
    /// Raw description from the table, e.g. "AMAZON-02 - Amazon.com, Inc."
    public var rawName: String
    /// Cleaned for display, e.g. "Amazon"
    public var name: String
}

public enum OwnerNames {
    /// Networks register under many handles. Folding them into one brand means all of
    /// "CLOUDFLARENET-UK" and "CLOUDFLARENET-CORE" group together as Cloudflare.
    private static let brands: [(needle: String, name: String)] = [
        ("amazon", "Amazon"), ("google", "Google"), ("cloudflare", "Cloudflare"), ("akamai", "Akamai"),
        ("facebook", "Meta"), ("meta platforms", "Meta"), ("microsoft", "Microsoft"), ("fastly", "Fastly"),
        ("apple", "Apple"), ("proton", "Proton"), ("spotify", "Spotify"), ("netflix", "Netflix"),
        ("twitter", "X (Twitter)"), ("github", "GitHub"), ("digitalocean", "DigitalOcean"), ("oracle", "Oracle"),
        ("hetzner", "Hetzner"), ("ovh", "OVH"), ("linode", "Linode"), ("alibaba", "Alibaba"), ("tencent", "Tencent"),
        ("bytedance", "ByteDance"), ("anthropic", "Anthropic"), ("openai", "OpenAI"), ("dropbox", "Dropbox"),
        ("zoom", "Zoom"), ("slack", "Slack"), ("adobe", "Adobe"),
    ]
    private static let suffixes = [
        ", inc.", ", inc", " inc.", " inc", ", llc", " llc", " ltd.", " ltd", " limited", " b.v.", " bv", " gmbh",
        " corporation", " corp.", " corp", " s.a.", " sa", " ag", " plc", " pty", " co.", " company", " llp", ",",
    ]

    public static func clean(_ raw: String) -> String {
        let lower = raw.lowercased()
        if let brand = brands.first(where: { lower.contains($0.needle) }) { return brand.name }

        // "HANDLE - Real Name" or "HANDLE Real Name"
        var name = raw
        if let dash = raw.range(of: " - ") {
            name = String(raw[dash.upperBound...])
        } else if let space = raw.firstIndex(of: " ") {
            let head = raw[..<space]
            if head.allSatisfy({ $0.isUppercase || $0.isNumber || $0 == "-" || $0 == "_" }) {
                name = String(raw[raw.index(after: space)...])
            }
        }
        var changed = true
        while changed {
            changed = false
            for suffix in suffixes where name.lowercased().hasSuffix(suffix) {
                name = String(name.dropLast(suffix.count)).trimmingCharacters(in: .whitespaces)
                changed = true
            }
        }
        // Tone down names registered in ALL CAPS.
        if name == name.uppercased(), name.count > 4 { name = name.capitalized }
        return name.isEmpty ? raw : name
    }

    public static func flag(_ countryCode: String?) -> String {
        guard let cc = countryCode?.uppercased(), cc.count == 2, cc.allSatisfy({ $0.isLetter && $0.isASCII }) else { return "" }
        return String(String.UnicodeScalarView(cc.unicodeScalars.compactMap { UnicodeScalar(127397 + $0.value) }))
    }
}

/// Offline IP-to-owner table. Lookups never leave this Mac, so looking up where your
/// data is going doesn't itself tell anyone where your data is going.
public final class OwnerDatabase {
    public static let sourceURL = URL(string: "https://iptoasn.com/data/ip2asn-combined.tsv.gz")!
    private let path: String
    private var db: OpaquePointer?
    private var lookupStatement: OpaquePointer?
    private let lock = NSLock()

    public init(path: String) {
        self.path = path
        open()
    }

    deinit { close() }

    public var isAvailable: Bool {
        lock.lock()
        defer { lock.unlock() }
        return lookupStatement != nil
    }

    public var lastUpdated: Date? {
        (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
    }

    private func open() {
        guard FileManager.default.fileExists(atPath: path),
            sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK
        else {
            close()
            return
        }
        let sql = "SELECT end, asn, cc, org FROM ranges WHERE start <= ? ORDER BY start DESC LIMIT 1"
        if sqlite3_prepare_v2(db, sql, -1, &lookupStatement, nil) != SQLITE_OK { close() }
    }

    private func close() {
        sqlite3_finalize(lookupStatement)
        lookupStatement = nil
        sqlite3_close(db)
        db = nil
    }

    public func lookup(_ ip: String) -> OwnerRecord? {
        guard let key = IP.canonical(ip) else { return nil }
        lock.lock()
        defer { lock.unlock() }
        guard let stmt = lookupStatement else { return nil }
        defer { sqlite3_reset(stmt) }
        let bound = key.withUnsafeBytes {
            sqlite3_bind_blob(stmt, 1, $0.baseAddress, 16, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        }
        guard bound == SQLITE_OK, sqlite3_step(stmt) == SQLITE_ROW,
            let endPtr = sqlite3_column_blob(stmt, 0), sqlite3_column_bytes(stmt, 0) == 16
        else { return nil }
        let end = Array(UnsafeBufferPointer(start: endPtr.assumingMemoryBound(to: UInt8.self), count: 16))
        guard !end.lexicographicallyPrecedes(key) else { return nil }  // in a gap between ranges
        let raw = Sanitize.displayText(sqlite3_column_text(stmt, 3).map { String(cString: $0) } ?? "")
        let cc = sqlite3_column_text(stmt, 2).map { String(cString: $0) }
        return OwnerRecord(
            asn: Int(sqlite3_column_int(stmt, 1)), countryCode: cc == "None" ? nil : cc,
            rawName: raw, name: OwnerNames.clean(raw))
    }

    // The real table is about 55 MB and 720,000 rows. These leave room to grow, and stop a
    // bad or hostile file from filling the disk.
    static let maxDecompressedBytes = 512 * 1024 * 1024
    static let maxRows = 5_000_000
    static let maxLineBytes = 64 * 1024

    /// Long-standing allocations a genuine table must get right. There's no published signature
    /// to check the download against, so this catches a corrupt or crudely poisoned file. It
    /// can't catch careful tampering with other addresses.
    static let knownAllocations: [(ip: String, asn: Int32)] = [("8.8.8.8", 15169), ("1.1.1.1", 13335), ("17.0.0.1", 714)]

    /// Builds the table from the downloaded TSV stream. Writes to a temp file and swaps it
    /// in on success, so a failed import can never damage the working copy.
    @discardableResult
    public func importTSV(gzipPath: String) throws -> Int {
        let tmp = path + ".importing"
        try? FileManager.default.removeItem(atPath: tmp)
        try FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)

        var out: OpaquePointer?
        guard sqlite3_open(tmp, &out) == SQLITE_OK else { throw OwnerImportError.database("could not create table") }
        defer { sqlite3_close(out) }
        sqlite3_exec(out, "PRAGMA journal_mode=OFF; PRAGMA synchronous=OFF;", nil, nil, nil)
        sqlite3_exec(out, "CREATE TABLE ranges(start BLOB PRIMARY KEY, end BLOB, asn INT, cc TEXT, org TEXT) WITHOUT ROWID;", nil, nil, nil)
        sqlite3_exec(out, "BEGIN;", nil, nil, nil)
        var insert: OpaquePointer?
        guard sqlite3_prepare_v2(out, "INSERT OR REPLACE INTO ranges VALUES(?,?,?,?,?)", -1, &insert, nil) == SQLITE_OK else {
            throw OwnerImportError.database("could not prepare insert")
        }
        defer { sqlite3_finalize(insert) }

        // gzip runs as its own process, so a malformed archive can only fail that process.
        let gunzip = Process()
        gunzip.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
        gunzip.arguments = ["-dc", gzipPath]
        let pipe = Pipe()
        gunzip.standardOutput = pipe
        gunzip.standardError = FileHandle.nullDevice
        try gunzip.run()

        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        var count = 0
        var pending = Data()
        let handle = pipe.fileHandleForReading
        func consume(_ line: Data) {
            let parts = line.split(separator: 0x09, maxSplits: 4, omittingEmptySubsequences: false)
            guard parts.count == 5, let asn = Int(String(decoding: parts[2], as: UTF8.self)), asn != 0,
                let start = IP.canonical(String(decoding: parts[0], as: UTF8.self)),
                let end = IP.canonical(String(decoding: parts[1], as: UTF8.self)),
                !end.lexicographicallyPrecedes(start)
            else { return }
            sqlite3_reset(insert)
            _ = start.withUnsafeBytes { sqlite3_bind_blob(insert, 1, $0.baseAddress, 16, transient) }
            _ = end.withUnsafeBytes { sqlite3_bind_blob(insert, 2, $0.baseAddress, 16, transient) }
            sqlite3_bind_int(insert, 3, Int32(truncatingIfNeeded: asn))
            sqlite3_bind_text(insert, 4, Sanitize.displayText(String(decoding: parts[3], as: UTF8.self), maxLength: 8), -1, transient)
            sqlite3_bind_text(insert, 5, Sanitize.displayText(String(decoding: parts[4], as: UTF8.self)), -1, transient)
            if sqlite3_step(insert) == SQLITE_DONE { count += 1 }
        }
        var totalBytes = 0
        var limitProblem: String?
        while limitProblem == nil {
            let chunk = handle.readData(ofLength: 1 << 20)
            if chunk.isEmpty { break }
            totalBytes += chunk.count
            pending.append(chunk)
            var lineStart = pending.startIndex
            while let newline = pending[lineStart...].firstIndex(of: 0x0A) {
                consume(pending[lineStart..<newline])
                lineStart = pending.index(after: newline)
            }
            pending = Data(pending[lineStart...])
            if totalBytes > Self.maxDecompressedBytes {
                limitProblem = "it unpacks to more than \(Self.maxDecompressedBytes / 1_000_000) MB"
            } else if pending.count > Self.maxLineBytes {
                limitProblem = "it contains an impossibly long line"
            } else if count > Self.maxRows {
                limitProblem = "it holds more than \(Self.maxRows) ranges"
            }
        }
        if let limitProblem {
            gunzip.terminate()
            gunzip.waitUntilExit()
            try? FileManager.default.removeItem(atPath: tmp)
            throw OwnerImportError.badFile(limitProblem)
        }
        if !pending.isEmpty { consume(pending) }
        gunzip.waitUntilExit()
        sqlite3_exec(out, "COMMIT;", nil, nil, nil)

        // A sanity floor: a truncated or wrong file must not replace a good table.
        guard gunzip.terminationStatus == 0, count > 100_000 else {
            try? FileManager.default.removeItem(atPath: tmp)
            throw OwnerImportError.badFile("the file held \(count) usable ranges")
        }
        var check: OpaquePointer?
        sqlite3_prepare_v2(out, "SELECT end, asn FROM ranges WHERE start <= ? ORDER BY start DESC LIMIT 1", -1, &check, nil)
        defer { sqlite3_finalize(check) }
        for known in Self.knownAllocations {
            guard let key = IP.canonical(known.ip) else { continue }
            sqlite3_reset(check)
            _ = key.withUnsafeBytes { sqlite3_bind_blob(check, 1, $0.baseAddress, 16, transient) }
            guard sqlite3_step(check) == SQLITE_ROW, sqlite3_column_int(check, 1) == known.asn else {
                try? FileManager.default.removeItem(atPath: tmp)
                throw OwnerImportError.badFile("it lists the wrong owner for \(known.ip)")
            }
        }

        lock.lock()
        defer { lock.unlock() }
        close()
        try? FileManager.default.removeItem(atPath: path)
        try FileManager.default.moveItem(atPath: tmp, toPath: path)
        chmod(path, 0o644)
        open()
        return count
    }
}

public enum OwnerImportError: LocalizedError {
    case database(String), badFile(String)
    public var errorDescription: String? {
        switch self {
        case .database(let m): return "Database error: \(m)"
        case .badFile(let m): return "That doesn't look like a valid owner table: \(m)"
        }
    }
}

// MARK: - Reverse DNS

/// Reverse DNS with a small concurrency cap. Results are cached, including failures,
/// so each address is only asked about once per run.
public final class ReverseDNS {
    private var cache: [String: String?] = [:]
    private var inFlight: Set<String> = []
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "undertow.rdns", attributes: .concurrent)
    private let gate = DispatchSemaphore(value: 4)
    public var enabled = true

    public init() {}

    /// A name already looked up, with no network activity. Used by anything running in the
    /// background, so lookups only happen when you open the panel to see them.
    public func cachedName(for ip: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return cache[ip] ?? nil
    }

    /// True if a forward lookup of the name led back to the address. Anyone who controls an IP
    /// can make its reverse DNS say "apple.com", but they can't make apple.com point back to it.
    public static func confirms(ip: String, name: String, forwardAddresses: [String]) -> Bool {
        guard Sanitize.isPlausibleHostname(name), let target = IP.canonical(ip) else { return false }
        return forwardAddresses.contains { IP.canonical($0) == target }
    }

    /// Returns a cached name now, and queues a lookup if this address is new.
    public func name(for ip: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        if let hit = cache[ip] { return hit }
        if cache.count > 20000 { cache.removeAll() }
        guard enabled, !inFlight.contains(ip) else { return nil }
        inFlight.insert(ip)
        queue.async { [self] in
            gate.wait()
            let result = Self.resolve(ip)
            gate.signal()
            lock.lock()
            cache[ip] = .some(result)
            inFlight.remove(ip)
            lock.unlock()
        }
        return nil
    }

    private static func resolve(_ ip: String) -> String? {
        var hints = addrinfo(
            ai_flags: AI_NUMERICHOST, ai_family: AF_UNSPEC, ai_socktype: SOCK_STREAM, ai_protocol: 0,
            ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
        var res: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(ip, nil, &hints, &res) == 0, let info = res else { return nil }
        defer { freeaddrinfo(res) }
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        guard getnameinfo(info.pointee.ai_addr, info.pointee.ai_addrlen, &host, socklen_t(host.count), nil, 0, NI_NAMEREQD) == 0
        else { return nil }
        var name = String(cString: host)
        if name.hasSuffix(".") { name = String(name.dropLast()) }
        guard Sanitize.isPlausibleHostname(name) else { return nil }
        return confirms(ip: ip, name: name, forwardAddresses: forwardLookup(name)) ? name : nil
    }

    private static func forwardLookup(_ name: String) -> [String] {
        var hints = addrinfo(
            ai_flags: 0, ai_family: AF_UNSPEC, ai_socktype: SOCK_STREAM, ai_protocol: 0,
            ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
        var res: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(name, nil, &hints, &res) == 0 else { return [] }
        defer { freeaddrinfo(res) }
        var out: [String] = []
        var cursor = res
        while let entry = cursor {
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(entry.pointee.ai_addr, entry.pointee.ai_addrlen, &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                var text = String(cString: host)
                if let zone = text.firstIndex(of: "%") { text = String(text[..<zone]) }
                out.append(text)
            }
            cursor = entry.pointee.ai_next
        }
        return out
    }
}
