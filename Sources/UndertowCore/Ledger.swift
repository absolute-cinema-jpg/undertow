import Darwin
import Foundation
import SQLite3

public struct UsageTotal: Identifiable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var path: String?
    public var rx: UInt64
    public var tx: UInt64
}

public struct DestinationTotal: Equatable, Sendable {
    public var ip: String
    public var rx: UInt64
    public var tx: UInt64
}

/// Local history of who talked to what. This is effectively a browsing record, so the
/// file is readable only by this user, never leaves the Mac, and can be turned off or wiped.
public final class Ledger {
    private var db: OpaquePointer?
    private let lock = NSLock()
    private var pending: [String: (hour: Int64, app: String, ip: String, rx: UInt64, tx: UInt64)] = [:]
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    public init?(path: String) {
        let dir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        guard sqlite3_open(path, &db) == SQLITE_OK else { return nil }
        chmod(path, 0o600)
        exec("PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL;")
        exec("""
            CREATE TABLE IF NOT EXISTS usage(hour INT, app TEXT, ip TEXT, rx INT, tx INT, PRIMARY KEY(hour, app, ip)) WITHOUT ROWID;
            CREATE TABLE IF NOT EXISTS apps(id TEXT PRIMARY KEY, name TEXT, path TEXT, first_seen REAL, last_seen REAL, trusted INT DEFAULT 0);
            CREATE TABLE IF NOT EXISTS app_dests(app TEXT, dest TEXT, first_seen REAL, PRIMARY KEY(app, dest)) WITHOUT ROWID;
            CREATE TABLE IF NOT EXISTS events(id INTEGER PRIMARY KEY AUTOINCREMENT, ts REAL, kind TEXT, app TEXT, app_name TEXT, title TEXT, detail TEXT, read INT DEFAULT 0);
            CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY, value TEXT);
            CREATE INDEX IF NOT EXISTS usage_app ON usage(app, hour);
            """)
        // Added after the first release. These fail harmlessly when the column already exists.
        // Trust saved without a signature is deliberately not honoured.
        exec("ALTER TABLE apps ADD COLUMN trusted_sig TEXT;")
        exec("ALTER TABLE app_dests ADD COLUMN last_seen REAL;")
    }

    deinit {
        flush()
        sqlite3_close(db)
    }

    private func exec(_ sql: String) { sqlite3_exec(db, sql, nil, nil, nil) }

    private func withStatement(_ sql: String, _ body: (OpaquePointer) -> Void) {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return }
        defer { sqlite3_finalize(stmt) }
        body(stmt)
    }

    private func bind(_ stmt: OpaquePointer, _ index: Int32, _ text: String?) {
        if let text {
            sqlite3_bind_text(stmt, index, text, -1, Self.transient)
        } else {
            sqlite3_bind_null(stmt, index)
        }
    }

    private func text(_ stmt: OpaquePointer, _ index: Int32) -> String? {
        sqlite3_column_text(stmt, index).map { String(cString: $0) }
    }

    // MARK: Usage

    /// Buffers in memory. Writing once a minute rather than every second avoids wearing
    /// the SSD and keeps the app quiet on disk.
    public func addUsage(now: Date, app: String, ip: String, rx: UInt64, tx: UInt64) {
        let hour = Int64(now.timeIntervalSince1970 / 3600)
        let key = "\(hour)|\(app)|\(ip)"
        lock.lock()
        defer { lock.unlock() }
        var entry = pending[key] ?? (hour, app, ip, 0, 0)
        entry.rx += rx
        entry.tx += tx
        pending[key] = entry
    }

    public func flush() {
        lock.lock()
        defer { lock.unlock() }
        guard !pending.isEmpty else { return }
        exec("BEGIN;")
        withStatement("INSERT INTO usage(hour,app,ip,rx,tx) VALUES(?,?,?,?,?) ON CONFLICT(hour,app,ip) DO UPDATE SET rx=rx+excluded.rx, tx=tx+excluded.tx") { stmt in
            for entry in pending.values {
                sqlite3_reset(stmt)
                sqlite3_bind_int64(stmt, 1, entry.hour)
                bind(stmt, 2, entry.app)
                bind(stmt, 3, entry.ip)
                sqlite3_bind_int64(stmt, 4, Int64(clamping: entry.rx))
                sqlite3_bind_int64(stmt, 5, Int64(clamping: entry.tx))
                sqlite3_step(stmt)
            }
        }
        exec("COMMIT;")
        pending.removeAll(keepingCapacity: true)
    }

    private static func hour(_ date: Date) -> Int64 { Int64(date.timeIntervalSince1970 / 3600) }

    public func topApps(since: Date) -> [UsageTotal] {
        flush()
        lock.lock()
        defer { lock.unlock() }
        var out: [UsageTotal] = []
        withStatement("""
            SELECT u.app, COALESCE(a.name, u.app), a.path, SUM(u.rx), SUM(u.tx) FROM usage u
            LEFT JOIN apps a ON a.id = u.app WHERE u.hour >= ? GROUP BY u.app ORDER BY SUM(u.rx)+SUM(u.tx) DESC
            """) { stmt in
            sqlite3_bind_int64(stmt, 1, Self.hour(since))
            while sqlite3_step(stmt) == SQLITE_ROW {
                out.append(UsageTotal(
                    id: text(stmt, 0) ?? "", name: text(stmt, 1) ?? "", path: text(stmt, 2),
                    rx: UInt64(max(0, sqlite3_column_int64(stmt, 3))), tx: UInt64(max(0, sqlite3_column_int64(stmt, 4)))))
            }
        }
        return out
    }

    /// Per-IP totals. Stored by IP, not owner, so older history gets real names as soon
    /// as an owner table is available.
    public func topDestinations(since: Date, app: String? = nil) -> [DestinationTotal] {
        flush()
        lock.lock()
        defer { lock.unlock() }
        var out: [DestinationTotal] = []
        let filter = app == nil ? "" : "AND app = ?"
        withStatement("SELECT ip, SUM(rx), SUM(tx) FROM usage WHERE hour >= ? \(filter) GROUP BY ip") { stmt in
            sqlite3_bind_int64(stmt, 1, Self.hour(since))
            if let app { bind(stmt, 2, app) }
            while sqlite3_step(stmt) == SQLITE_ROW {
                out.append(DestinationTotal(
                    ip: text(stmt, 0) ?? "",
                    rx: UInt64(max(0, sqlite3_column_int64(stmt, 1))), tx: UInt64(max(0, sqlite3_column_int64(stmt, 2)))))
            }
        }
        return out
    }

    /// Which apps talked to an IP since a date, used to answer "who sent data here?".
    public func apps(forIPs ips: [String], since: Date) -> [UsageTotal] {
        guard !ips.isEmpty else { return [] }
        flush()
        lock.lock()
        defer { lock.unlock() }
        var out: [UsageTotal] = []
        let marks = Array(repeating: "?", count: ips.count).joined(separator: ",")
        withStatement("""
            SELECT u.app, COALESCE(a.name, u.app), a.path, SUM(u.rx), SUM(u.tx) FROM usage u
            LEFT JOIN apps a ON a.id = u.app WHERE u.hour >= ? AND u.ip IN (\(marks)) GROUP BY u.app ORDER BY SUM(u.tx) DESC
            """) { stmt in
            sqlite3_bind_int64(stmt, 1, Self.hour(since))
            for (i, ip) in ips.enumerated() { bind(stmt, Int32(i + 2), ip) }
            while sqlite3_step(stmt) == SQLITE_ROW {
                out.append(UsageTotal(
                    id: text(stmt, 0) ?? "", name: text(stmt, 1) ?? "", path: text(stmt, 2),
                    rx: UInt64(max(0, sqlite3_column_int64(stmt, 3))), tx: UInt64(max(0, sqlite3_column_int64(stmt, 4)))))
            }
        }
        return out
    }

    // MARK: Known apps and destinations (the baseline for "this is new")

    public func recordApp(id: String, name: String, path: String?, now: Date) {
        lock.lock()
        defer { lock.unlock() }
        withStatement("INSERT INTO apps(id,name,path,first_seen,last_seen) VALUES(?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET name=excluded.name, path=excluded.path, last_seen=excluded.last_seen") { stmt in
            bind(stmt, 1, id)
            bind(stmt, 2, name)
            bind(stmt, 3, path)
            sqlite3_bind_double(stmt, 4, now.timeIntervalSince1970)
            sqlite3_bind_double(stmt, 5, now.timeIntervalSince1970)
            sqlite3_step(stmt)
        }
    }

    public func recordPair(app: String, dest: String, now: Date) {
        lock.lock()
        defer { lock.unlock() }
        withStatement("INSERT OR IGNORE INTO app_dests(app,dest,first_seen,last_seen) VALUES(?,?,?,?)") { stmt in
            bind(stmt, 1, app)
            bind(stmt, 2, dest)
            sqlite3_bind_double(stmt, 3, now.timeIntervalSince1970)
            sqlite3_bind_double(stmt, 4, now.timeIntervalSince1970)
            sqlite3_step(stmt)
        }
    }

    /// Marks destinations as still in use, so retention only forgets ones that have gone quiet.
    public func touchPairs(_ pairs: Set<String>, now: Date) {
        guard !pairs.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        exec("BEGIN;")
        withStatement("UPDATE app_dests SET last_seen = ? WHERE app || '|' || dest = ?") { stmt in
            for pair in pairs {
                sqlite3_reset(stmt)
                sqlite3_bind_double(stmt, 1, now.timeIntervalSince1970)
                bind(stmt, 2, pair)
                sqlite3_step(stmt)
            }
        }
        exec("COMMIT;")
    }

    public func knownApps() -> Set<String> { strings("SELECT id FROM apps") }

    /// App ID to the signature it was trusted under.
    public func trustedApps() -> [String: String] {
        lock.lock()
        defer { lock.unlock() }
        var out: [String: String] = [:]
        withStatement("SELECT id, trusted_sig FROM apps WHERE trusted = 1 AND trusted_sig IS NOT NULL") { stmt in
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let id = text(stmt, 0), let key = text(stmt, 1) { out[id] = key }
            }
        }
        return out
    }
    public func knownPairs() -> Set<String> { strings("SELECT app || '|' || dest FROM app_dests") }

    private func strings(_ sql: String) -> Set<String> {
        lock.lock()
        defer { lock.unlock() }
        var out = Set<String>()
        withStatement(sql) { stmt in
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let s = text(stmt, 0) { out.insert(s) }
            }
        }
        return out
    }

    /// Saves a trust decision, or clears one when `key` is nil. Creates the app's record if
    /// needed, since with history off there may not be one yet.
    public func setTrusted(app: String, name: String, path: String?, key: String?, now: Date) {
        lock.lock()
        defer { lock.unlock() }
        withStatement("""
            INSERT INTO apps(id,name,path,first_seen,last_seen,trusted,trusted_sig) VALUES(?,?,?,?,?,?,?)
            ON CONFLICT(id) DO UPDATE SET trusted=excluded.trusted, trusted_sig=excluded.trusted_sig
            """) { stmt in
            bind(stmt, 1, app)
            bind(stmt, 2, name)
            bind(stmt, 3, path)
            sqlite3_bind_double(stmt, 4, now.timeIntervalSince1970)
            sqlite3_bind_double(stmt, 5, now.timeIntervalSince1970)
            sqlite3_bind_int(stmt, 6, key == nil ? 0 : 1)
            bind(stmt, 7, key)
            sqlite3_step(stmt)
        }
    }

    public func path(app: String) -> (name: String, path: String?)? {
        lock.lock()
        defer { lock.unlock() }
        var result: (String, String?)?
        withStatement("SELECT name, path FROM apps WHERE id = ?") { stmt in
            bind(stmt, 1, app)
            if sqlite3_step(stmt) == SQLITE_ROW { result = (text(stmt, 0) ?? app, text(stmt, 1)) }
        }
        return result
    }

    public func firstSeen(app: String) -> Date? {
        lock.lock()
        defer { lock.unlock() }
        var result: Date?
        withStatement("SELECT first_seen FROM apps WHERE id = ?") { stmt in
            bind(stmt, 1, app)
            if sqlite3_step(stmt) == SQLITE_ROW { result = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 0)) }
        }
        return result
    }

    // MARK: Meta

    /// When monitoring first ran on this Mac. New-app alerts stay quiet for a day after
    /// this, otherwise every app you already use would be flagged as "new".
    public func installDate(now: Date) -> Date {
        lock.lock()
        defer { lock.unlock() }
        var found: Date?
        withStatement("SELECT value FROM meta WHERE key = 'installed'") { stmt in
            if sqlite3_step(stmt) == SQLITE_ROW, let s = text(stmt, 0), let t = Double(s) {
                found = Date(timeIntervalSince1970: t)
            }
        }
        if let found { return found }
        withStatement("INSERT INTO meta(key,value) VALUES('installed', ?)") { stmt in
            bind(stmt, 1, String(now.timeIntervalSince1970))
            sqlite3_step(stmt)
        }
        return now
    }

    // MARK: Events

    @discardableResult
    public func insert(event: WatchEvent) -> Int64 {
        lock.lock()
        defer { lock.unlock() }
        var id: Int64 = 0
        withStatement("INSERT INTO events(ts,kind,app,app_name,title,detail,read) VALUES(?,?,?,?,?,?,0)") { stmt in
            sqlite3_bind_double(stmt, 1, event.date.timeIntervalSince1970)
            bind(stmt, 2, event.kind.rawValue)
            bind(stmt, 3, event.appID)
            bind(stmt, 4, event.appName)
            bind(stmt, 5, event.title)
            bind(stmt, 6, event.detail)
            if sqlite3_step(stmt) == SQLITE_DONE { id = sqlite3_last_insert_rowid(db) }
        }
        return id
    }

    public func recentEvents(limit: Int = 200) -> [WatchEvent] {
        lock.lock()
        defer { lock.unlock() }
        var out: [WatchEvent] = []
        withStatement("SELECT id,ts,kind,app,app_name,title,detail,read FROM events ORDER BY ts DESC LIMIT ?") { stmt in
            sqlite3_bind_int(stmt, 1, Int32(limit))
            while sqlite3_step(stmt) == SQLITE_ROW {
                guard let kind = WatchKind(rawValue: text(stmt, 2) ?? "") else { continue }
                out.append(WatchEvent(
                    id: sqlite3_column_int64(stmt, 0),
                    date: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 1)),
                    kind: kind, appID: text(stmt, 3) ?? "", appName: text(stmt, 4) ?? "",
                    title: text(stmt, 5) ?? "", detail: text(stmt, 6) ?? "",
                    read: sqlite3_column_int(stmt, 7) != 0))
            }
        }
        return out
    }

    public func markAllEventsRead() {
        lock.lock()
        defer { lock.unlock() }
        exec("UPDATE events SET read = 1 WHERE read = 0;")
    }

    public func deleteEvent(id: Int64) {
        lock.lock()
        defer { lock.unlock() }
        withStatement("DELETE FROM events WHERE id = ?") { stmt in
            sqlite3_bind_int64(stmt, 1, id)
            sqlite3_step(stmt)
        }
    }

    // MARK: Retention

    /// Applies the retention setting to everything that records activity. Trusted apps stay,
    /// because they're a decision you made, not a record of what happened.
    public func prune(olderThanDays days: Int, now: Date) {
        let cutoff = now.addingTimeInterval(-Double(days) * 86400)
        lock.lock()
        defer { lock.unlock() }
        withStatement("DELETE FROM usage WHERE hour < ?") { stmt in
            sqlite3_bind_int64(stmt, 1, Self.hour(cutoff))
            sqlite3_step(stmt)
        }
        for sql in [
            "DELETE FROM events WHERE ts < ?",
            "DELETE FROM app_dests WHERE COALESCE(last_seen, first_seen) < ?",
            "DELETE FROM apps WHERE COALESCE(trusted, 0) = 0 AND last_seen < ?",
        ] {
            withStatement(sql) { stmt in
                sqlite3_bind_double(stmt, 1, cutoff.timeIntervalSince1970)
                sqlite3_step(stmt)
            }
        }
    }

    /// Erases everything that records activity. Your trust decisions stay unless told
    /// otherwise. The learning period restarts, or every app would then look new.
    public func wipe(includingBaseline: Bool) {
        lock.lock()
        defer { lock.unlock() }
        pending.removeAll()
        exec("DELETE FROM usage; DELETE FROM events; DELETE FROM app_dests; DELETE FROM meta;")
        exec(includingBaseline ? "DELETE FROM apps;" : "DELETE FROM apps WHERE COALESCE(trusted, 0) = 0;")
        exec("PRAGMA wal_checkpoint(TRUNCATE); VACUUM;")
    }
}
