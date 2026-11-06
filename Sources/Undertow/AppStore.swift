import AppKit
import Combine
import SwiftUI
import UndertowCore
import UserNotifications

enum AppPaths {
    static let directory: String = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        var url = base.appendingPathComponent("Undertow")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        // History shows which services you use, so it shouldn't outlive "Clear History" in a
        // backup, or be readable by other accounts on this Mac.
        chmod(url.path, 0o700)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
        return url.path
    }()
    static var ledger: String { directory + "/history.sqlite" }
    static var owners: String { directory + "/owners.sqlite" }
}

struct GraphSample: Equatable {
    var date: Date
    var down: Double
    var up: Double
}

enum Route: Equatable {
    case home
    case app(String)
    case destination(String)
}

/// A row in a history view, a saved total rather than a live rate.
struct HistoryRow: Identifiable, Equatable {
    var id: String
    var name: String
    var path: String?
    var countryCode: String?
    var subtitle: String?
    var cls: FlowClass
    var rx: UInt64
    var tx: UInt64
}

struct OwnerDownload: Equatable {
    enum Phase: Equatable {
        case idle, downloading, importing, failed(String), done(Int)
    }
    var phase: Phase = .idle
}

/// Main-thread state shared by the status item, the panel and the settings window.
final class AppStore: ObservableObject {
    @Published var prefs: Prefs {
        didSet {
            guard prefs != oldValue else { return }
            savePrefs()
            monitor.update(prefs: prefs)
            onPrefsChanged?()
        }
    }
    @Published private(set) var detail = Detail()
    @Published private(set) var liveHeadline = Headline()
    @Published private(set) var events: [WatchEvent] = []
    @Published private(set) var graph: [GraphSample] = []
    @Published var route: Route = .home
    @Published var range: TimeRange = .live
    @Published private(set) var historyApps: [HistoryRow] = []
    @Published private(set) var historyDestinations: [HistoryRow] = []
    @Published private(set) var historyAppDestinations: [HistoryRow] = []
    @Published private(set) var historyDestinationApps: [HistoryRow] = []
    @Published var ownerDownload = OwnerDownload()
    @Published var isPanelOpen = false

    /// Rows keep their position while the pointer is over a list, so nothing jumps out from under a click.
    var listHovered = false
    private var appOrder: [String] = []
    private var destOrder: [String] = []
    private var lastReorder = Date.distantPast

    let monitor: Monitor
    var onHeadline: ((Headline) -> Void)?
    var onBadgeChanged: (() -> Void)?
    var onPrefsChanged: (() -> Void)?

    private var history = RingBuffer<GraphSample>(capacity: 3600, filler: GraphSample(date: .distantPast, down: 0, up: 0))
    private let historyQueue = DispatchQueue(label: "undertow.history", qos: .userInitiated)
    private var lastHistoryRefresh = Date.distantPast

    var unreadEvents: Int { events.filter { !$0.read }.count }

    init() {
        let saved = UserDefaults.standard.data(forKey: "prefs").map(Prefs.decode) ?? Prefs()
        prefs = saved
        range = saved.defaultRange
        monitor = Monitor(paths: .init(ledger: AppPaths.ledger, owners: AppPaths.owners), prefs: saved)
        events = monitor.ledger?.recentEvents() ?? []

        monitor.onHeadline = { [weak self] h in self?.receive(h) }
        monitor.onDetail = { [weak self] d in self?.receive(d) }
        monitor.onEvents = { [weak self] e in self?.receive(e) }
    }

    func start() { monitor.start() }

    private func savePrefs() {
        if let data = try? JSONEncoder().encode(prefs) { UserDefaults.standard.set(data, forKey: "prefs") }
    }

    // MARK: Receiving data

    private func receive(_ headline: Headline) {
        let value = headline.value(for: prefs.measure)
        history.append(GraphSample(date: headline.date, down: value.down, up: value.up))
        onHeadline?(headline)
        guard isPanelOpen else { return }
        liveHeadline = headline
        refreshGraph()
        if range != .live, Date().timeIntervalSince(lastHistoryRefresh) > 15 { refreshHistory() }
    }

    func refreshGraph() {
        let start = Date().addingTimeInterval(-Double(prefs.graphSpan))
        graph = history.values().filter { $0.date >= start }
    }

    private func receive(_ new: Detail) {
        var next = new
        // Re-rank at most every 3 seconds, and never under the pointer.
        let due = Date().timeIntervalSince(lastReorder) >= 3 && !listHovered
        if due {
            appOrder = new.apps.map(\.id)
            destOrder = new.destinations.map(\.id)
            lastReorder = Date()
        } else {
            next.apps = Self.stableSort(new.apps, order: appOrder, id: \.id)
            next.destinations = Self.stableSort(new.destinations, order: destOrder, id: \.id)
        }
        detail = next
    }

    private static func stableSort<T>(_ items: [T], order: [String], id: (T) -> String) -> [T] {
        var rank: [String: Int] = [:]
        for (i, key) in order.enumerated() { rank[key] = i }
        let sorted = items.enumerated().sorted { a, b in
            let ra = rank[id(a.element)] ?? Int.max
            let rb = rank[id(b.element)] ?? Int.max
            return ra == rb ? a.offset < b.offset : ra < rb
        }
        return sorted.map(\.element)
    }

    private func receive(_ new: [WatchEvent]) {
        events = (new.sorted { $0.date > $1.date } + events).prefix(200).map { $0 }
        onBadgeChanged?()
        for event in new where prefs.notifyKinds.contains(event.kind) {
            Notifier.post(event)
        }
    }

    // MARK: Panel lifecycle

    func panelOpened() {
        isPanelOpen = true
        range = prefs.defaultRange
        route = .home
        refreshGraph()
        monitor.setPanelOpen(true)
        refreshHistory()
    }

    func panelClosed() {
        isPanelOpen = false
        monitor.setPanelOpen(false)
        markEventsRead()
    }

    func markEventsRead() {
        guard unreadEvents > 0 else { return }
        monitor.ledger?.markAllEventsRead()
        events = events.map { var e = $0; e.read = true; return e }
        onBadgeChanged?()
    }

    func dismiss(_ event: WatchEvent) {
        monitor.ledger?.deleteEvent(id: event.id)
        events.removeAll { $0.id == event.id }
    }

    func setTrusted(appID: String, _ trusted: Bool) {
        monitor.setTrusted(appID: appID, trusted: trusted)
        if trusted { events.removeAll { $0.appID == appID && !$0.read } }
    }

    // MARK: History

    func setRange(_ new: TimeRange) {
        range = new
        refreshHistory()
    }

    func refreshHistory() {
        guard range != .live || route != .home else { return }
        lastHistoryRefresh = Date()
        let window = range == .live ? TimeRange.hour : range
        let since = window.start(now: Date())
        let currentRoute = route
        let monitor = monitor
        historyQueue.async { [weak self] in
            guard let ledger = monitor.ledger else { return }
            let apps = ledger.topApps(since: since).map {
                HistoryRow(id: $0.id, name: $0.name, path: $0.path, subtitle: nil, cls: .internet, rx: $0.rx, tx: $0.tx)
            }
            let dests = Self.groupDestinations(ledger.topDestinations(since: since), monitor: monitor)
            var appDests: [HistoryRow] = []
            if case .app(let id) = currentRoute {
                appDests = Self.groupDestinations(ledger.topDestinations(since: since, app: id), monitor: monitor)
            }
            var destApps: [HistoryRow] = []
            if case .destination(let key) = currentRoute {
                let ips = ledger.topDestinations(since: since)
                    .filter { monitor.lookupDestination(ip: $0.ip).key == key }.map(\.ip)
                destApps = ledger.apps(forIPs: ips, since: since).map {
                    HistoryRow(id: $0.id, name: $0.name, path: $0.path, subtitle: nil, cls: .internet, rx: $0.rx, tx: $0.tx)
                }
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.historyApps = apps
                self.historyDestinations = dests
                self.historyAppDestinations = appDests
                self.historyDestinationApps = destApps
            }
        }
    }

    private static func groupDestinations(_ totals: [DestinationTotal], monitor: Monitor) -> [HistoryRow] {
        var grouped: [String: HistoryRow] = [:]
        for total in totals {
            let d = monitor.lookupDestination(ip: total.ip)
            var row = grouped[d.key] ?? HistoryRow(
                id: d.key, name: d.label, path: nil, countryCode: d.countryCode, subtitle: d.hostname,
                cls: total.ip == "*" || IP.scope(of: total.ip) == .publicNet ? .internet : .local, rx: 0, tx: 0)
            row.rx += total.rx
            row.tx += total.tx
            grouped[d.key] = row
        }
        return grouped.values.sorted { $0.rx + $0.tx > $1.rx + $1.tx }
    }

    func clearHistory(includingBaseline: Bool) {
        let monitor = monitor
        historyQueue.async {
            monitor.ledger?.wipe(includingBaseline: includingBaseline)
            monitor.clearSession()
            monitor.reloadBaseline()
            DispatchQueue.main.async { [weak self] in
                self?.events = []
                self?.historyApps = []
                self?.historyDestinations = []
                self?.onBadgeChanged?()
            }
        }
    }

    // MARK: Owner table

    func downloadOwnerTable() {
        guard ownerDownload.phase != .downloading, ownerDownload.phase != .importing else { return }
        ownerDownload.phase = .downloading
        let monitor = monitor
        OwnerDownloader.start(url: OwnerDatabase.sourceURL) { [weak self] result in
            func finish(_ phase: OwnerDownload.Phase) {
                DispatchQueue.main.async { self?.ownerDownload.phase = phase }
            }
            switch result {
            case .failure(let error):
                finish(.failed(error.localizedDescription))
            case .success(let path):
                defer { try? FileManager.default.removeItem(atPath: path) }
                finish(.importing)
                do {
                    let count = try monitor.owners.importTSV(gzipPath: path)
                    monitor.ownerTableChanged()
                    finish(.done(count))
                } catch {
                    finish(.failed(error.localizedDescription))
                }
            }
        }
    }
}

/// Downloads the owner table with limits, since the file comes from outside. It stays on
/// HTTPS and on the same host, stops at a sensible size, and keeps no cookies or cache.
final class OwnerDownloader: NSObject, URLSessionDownloadDelegate {
    private struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    /// The real file is about 11 MB.
    static let maxBytes: Int64 = 64_000_000

    private let host: String?
    private let completion: (Result<String, Error>) -> Void
    private var keptPath: String?
    private var failure: Error?

    private init(host: String?, completion: @escaping (Result<String, Error>) -> Void) {
        self.host = host
        self.completion = completion
    }

    static func start(url: URL, completion: @escaping (Result<String, Error>) -> Void) {
        let delegate = OwnerDownloader(host: url.host, completion: completion)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.timeoutIntervalForResource = 300
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        session.downloadTask(with: url).resume()
        session.finishTasksAndInvalidate()
    }

    static func allowsRedirect(to url: URL?, fromHost host: String?) -> Bool {
        url?.scheme == "https" && url?.host == host
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(Self.allowsRedirect(to: request.url, fromHost: host) ? request : nil)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if totalBytesWritten > Self.maxBytes || totalBytesExpectedToWrite > Self.maxBytes {
            failure = Failure("The file is much larger than expected, so the download was stopped.")
            downloadTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard (downloadTask.response as? HTTPURLResponse)?.statusCode == 200 else {
            failure = Failure("The server didn't send the file.")
            return
        }
        let kept = NSTemporaryDirectory() + "undertow-owners-\(UUID().uuidString).gz"
        do {
            try FileManager.default.moveItem(atPath: location.path, toPath: kept)
            keptPath = kept
        } catch {
            failure = error
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let keptPath, failure == nil, error == nil {
            completion(.success(keptPath))
        } else {
            completion(.failure(failure ?? error ?? Failure("The download didn't finish.")))
        }
    }
}

enum Notifier {
    static func requestPermission(completion: @escaping (Bool) -> Void) {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            DispatchQueue.main.async { completion(granted) }
        }
    }

    static func post(_ event: WatchEvent) {
        let content = UNMutableNotificationContent()
        content.title = event.title
        content.body = event.detail
        let request = UNNotificationRequest(identifier: "undertow.\(event.id)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}

// MARK: - Theme

struct Theme {
    let prefs: Prefs

    var download: Color { Color(nsColor: Self.nsDownload(prefs.palette)) }
    var upload: Color { Color(nsColor: Self.nsUpload(prefs.palette)) }

    static func nsDownload(_ palette: Palette) -> NSColor {
        switch palette {
        case .classic: return .systemBlue
        case .ocean: return .systemTeal
        case .grape: return .systemPurple
        case .graphite: return .secondaryLabelColor
        }
    }

    static func nsUpload(_ palette: Palette) -> NSColor {
        switch palette {
        case .classic: return .systemOrange
        case .ocean: return .systemPink
        case .grape: return .systemYellow
        case .graphite: return .labelColor
        }
    }

    var rowPadding: CGFloat { prefs.density == .compact ? 3 : 6 }
    var iconSize: CGFloat { prefs.density == .compact ? 16 : 20 }

    func rate(_ value: Double) -> String { Format.rate(value, unit: prefs.units) }
}

/// Icons load once per path. NSWorkspace lookups are too slow to repeat on every render.
enum IconCache {
    private static var cache: [String: NSImage] = [:]
    static func icon(for path: String?) -> NSImage? {
        guard let path, FileManager.default.fileExists(atPath: path) else { return nil }
        if let hit = cache[path] { return hit }
        let image = NSWorkspace.shared.icon(forFile: path)
        cache[path] = image
        return image
    }
}
