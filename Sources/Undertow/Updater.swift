import AppKit
import os

let updateLog = Logger(subsystem: UpdateConfig.logSubsystem, category: "update")

/// Checks GitHub for a newer version and installs it when the person clicks Update.
/// Checking and downloading happen here, in the app (inside its sandbox, if it has one); the
/// swap itself is done by the updater helper embedded in the app (Updater/main.swift).
///
/// Call `Updater.shared.start()` once at launch. Show `UpdatesSection` in Settings and
/// `UpdateBanner` somewhere visible. Everything else is optional.
final class Updater: NSObject, ObservableObject {
    static let shared = Updater()

    enum Phase: Equatable {
        case idle, checking, upToDate, available
        case downloading(Double)
        case installing, restarting
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var update: AvailableUpdate?
    @Published private(set) var lastChecked: Date? { didSet { defaults.set(lastChecked, forKey: key("LastChecked")) } }
    /// True when the last failure was while installing (rather than checking), so the
    /// UI offers to try the install again or download it by hand.
    @Published private(set) var installFailed = false
    /// Set for the session after the app restarts into a new version.
    @Published var justUpdated: Bool
    /// The "Check for updates automatically" setting. On by default.
    @Published var automaticChecks: Bool { didSet { defaults.set(automaticChecks, forKey: key("Automatic")) } }

    let currentVersion: String
    private let current: AppVersion
    private let defaults = UserDefaults.standard
    private var timer: Timer?
    private var download: URLSessionDownloadTask?
    private var progressWatch: NSKeyValueObservation?
    private lazy var session = URLSession(configuration: {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 30
        let agent = UpdateConfig.appName.replacingOccurrences(of: " ", with: "")
        c.httpAdditionalHeaders = ["User-Agent": "\(agent)/\(currentVersion)", "Accept": "application/vnd.github+json"]
        return c
    }())

    // MARK: Hooks the app can set

    /// If restarting now would lose something (alerts on screen, an unsaved document…),
    /// return a sentence saying what, and the person is asked before updating.
    var restartWarning: (() -> String?)?
    /// The window to attach that question to. Without one it's shown as a separate alert.
    var presentingWindow: (() -> NSWindow?)?

    /// Tests replace the network with these.
    var fetchRelease: ((@escaping (Result<GitHubRelease, UpdateError>) -> Void) -> Void)?
    var installHook: ((AvailableUpdate) -> Void)?

    private func key(_ name: String) -> String { "Updater\(name)" }
    private var feed: URL { UpdateLogic.feedURL(override: defaults.string(forKey: "UpdateFeedURL")) }
    private var allowLocal: Bool { UpdateLogic.isLocalTestURL(feed) }

    override init() {
        currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
        current = AppVersion(currentVersion) ?? AppVersion("0")!
        // macOS doesn't pass launch arguments from a sandboxed app to the copy it opens, so
        // the old version leaves a note in the app's settings for the new one to find once.
        justUpdated = UserDefaults.standard.string(forKey: "UpdaterJustUpdatedTo") == currentVersion
        automaticChecks = UserDefaults.standard.object(forKey: "UpdaterAutomatic") as? Bool ?? true
        super.init()
        defaults.removeObject(forKey: key("JustUpdatedTo"))
        if justUpdated { updateLog.notice("now running \(self.currentVersion, privacy: .public) after updating") }
        lastChecked = defaults.object(forKey: key("LastChecked")) as? Date
    }

    var isBusy: Bool {
        switch phase {
        case .checking, .downloading, .installing, .restarting: return true
        default: return false
        }
    }

    /// Checks shortly after launch (unless it checked recently), then every `checkInterval`.
    func start() {
        let t = Timer(timeInterval: 3600, repeats: true) { [weak self] _ in self?.checkIfDue() }
        t.tolerance = 600
        RunLoop.main.add(t, forMode: .common)
        timer = t
        DispatchQueue.main.asyncAfter(deadline: .now() + UpdateConfig.firstCheckDelay) { [weak self] in self?.checkIfDue() }
        // Lets the end-to-end test drive a whole update from the command line, but only
        // against a test server on this Mac (see scripts/e2e-update-test.sh).
        if CommandLine.arguments.contains("--install-update"), allowLocal {
            check { [weak self] in if self?.update != nil { self?.install() } }
        }
    }

    private func checkIfDue() {
        guard automaticChecks, !isBusy else { return }
        if let lastChecked, Date().timeIntervalSince(lastChecked) < UpdateConfig.checkInterval { return }
        check()
    }

    func check(then done: (() -> Void)? = nil) {
        guard !isBusy else { return }
        phase = .checking
        installFailed = false
        let finish: (Result<GitHubRelease, UpdateError>) -> Void = { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                self.lastChecked = Date()
                switch result {
                case .success(let release):
                    do {
                        self.update = try UpdateLogic.update(from: release, current: self.current)
                        self.phase = self.update == nil ? .upToDate : .available
                        updateLog.notice("checked: latest \(release.tagName, privacy: .public), running \(self.currentVersion, privacy: .public)")
                    } catch {
                        self.update = nil
                        self.phase = .failed(error.localizedDescription)
                    }
                case .failure(let error):
                    updateLog.notice("check failed: \(error.localizedDescription, privacy: .public)")
                    self.phase = .failed(error.localizedDescription)
                }
                done?()
            }
        }
        if let fetchRelease { fetchRelease(finish) } else { fetchLatest(finish) }
    }

    private func fetchLatest(_ done: @escaping (Result<GitHubRelease, UpdateError>) -> Void) {
        session.dataTask(with: feed) { data, response, error in
            if let error { return done(.failure(.network(error.localizedDescription))) }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            switch status {
            case 200:
                guard let data, let release = try? JSONDecoder().decode(GitHubRelease.self, from: data)
                else { return done(.failure(.unreadable)) }
                done(.success(release))
            case 404: done(.failure(.notPublished))
            case 403, 429: done(.failure(.rateLimited))
            default: done(.failure(.server(status)))
            }
        }.resume()
    }

    /// What the Update buttons call: asks first if `restartWarning` says something would be lost.
    func installAsking() {
        guard let warning = restartWarning?() else { return install() }
        let alert = NSAlert()
        alert.messageText = "Update and restart \(UpdateConfig.appName)?"
        alert.informativeText = warning
        alert.addButton(withTitle: "Update")
        alert.addButton(withTitle: "Cancel")
        let respond: (NSApplication.ModalResponse) -> Void = { [weak self] in
            if $0 == .alertFirstButtonReturn { self?.install() }
        }
        if let window = presentingWindow?(), window.isVisible {
            alert.beginSheetModal(for: window, completionHandler: respond)
        } else {
            respond(alert.runModal())
        }
    }

    /// Download, check and install, then restart into the new version.
    func install() {
        guard let update, !isBusy else { return }
        installFailed = false
        if let installHook { installHook(update); return }
        guard UpdateLogic.isTrustedDownload(update.zipURL, allowLocal: allowLocal) else {
            return fail(UpdateError.untrustedDownload.localizedDescription)
        }
        phase = .downloading(0)
        updateLog.notice("downloading \(update.version, privacy: .public)")
        let task = session.downloadTask(with: update.zipURL) { [weak self] file, response, error in
            guard let self else { return }
            let result: Result<URL, UpdateError>
            if let error {
                result = .failure(.network(error.localizedDescription))
            } else if let file, let http = response as? HTTPURLResponse, http.statusCode == 200,
                      let final = http.url, UpdateLogic.isTrustedDownload(final, allowLocal: self.allowLocal) {
                // The temporary file goes away when this returns, so keep it.
                let kept = FileManager.default.temporaryDirectory.appendingPathComponent("\(UpdateConfig.assetPrefix)\(update.version).zip")
                try? FileManager.default.removeItem(at: kept)
                do { try FileManager.default.moveItem(at: file, to: kept); result = .success(kept) }
                catch { result = .failure(.network(error.localizedDescription)) }
            } else if response?.url.map({ UpdateLogic.isTrustedDownload($0, allowLocal: self.allowLocal) }) == false {
                result = .failure(.untrustedDownload)
            } else {
                result = .failure(.server((response as? HTTPURLResponse)?.statusCode ?? 0))
            }
            switch result {
            case .success(let zip): self.verifyAndInstall(zip, update)
            case .failure(let error): self.fail(error.localizedDescription)
            }
        }
        progressWatch = task.progress.observe(\.fractionCompleted) { [weak self] progress, _ in
            DispatchQueue.main.async {
                if case .downloading = self?.phase { self?.phase = .downloading(progress.fractionCompleted) }
            }
        }
        download = task
        task.resume()
    }

    private func verifyAndInstall(_ zip: URL, _ update: AvailableUpdate) {
        expectedChecksum(for: update) { [weak self] expected in
            guard let self else { return }
            guard let expected else { return self.fail(UpdateError.checksumMissing.localizedDescription) }
            guard (try? UpdateShared.sha256(of: zip)) == expected else {
                try? FileManager.default.removeItem(at: zip)
                return self.fail(UpdateError.checksumMismatch.localizedDescription)
            }
            DispatchQueue.main.async { self.phase = .installing }
            self.handToHelper(zip, sha256: expected, version: update.version)
        }
    }

    private func expectedChecksum(for update: AvailableUpdate, _ done: @escaping (String?) -> Void) {
        if let sha = update.sha256 { return done(sha) }
        guard let url = update.checksumURL, UpdateLogic.isTrustedDownload(url, allowLocal: allowLocal) else { return done(nil) }
        session.dataTask(with: url) { data, response, _ in
            guard (response as? HTTPURLResponse)?.statusCode == 200, let data else { return done(nil) }
            done(UpdateLogic.parseChecksum(String(decoding: data, as: UTF8.self)))
        }.resume()
    }

    private func handToHelper(_ zip: URL, sha256: String, version: String) {
        guard let bundleID = Bundle.main.bundleIdentifier, let handle = try? FileHandle(forReadingFrom: zip) else {
            return fail("The download couldn't be opened. Try again.")
        }
        let connection = NSXPCConnection(serviceName: UpdateShared.serviceName(forApp: bundleID))
        connection.remoteObjectInterface = NSXPCInterface(with: UpdateInstalling.self)
        connection.resume()
        var answered = false
        let finish: (String?) -> Void = { [weak self] problem in
            DispatchQueue.main.async {
                guard !answered else { return }
                answered = true
                try? handle.close()
                try? FileManager.default.removeItem(at: zip)
                connection.invalidate()
                if let problem { self?.fail(problem) } else { self?.restart(into: version) }
            }
        }
        let unavailable = "\(UpdateConfig.appName)'s updater couldn't start, so nothing was changed. Download the new version from GitHub instead."
        let helper = connection.remoteObjectProxyWithErrorHandler { error in
            updateLog.error("updater helper: \(error.localizedDescription, privacy: .public)")
            finish(unavailable)
        } as? UpdateInstalling
        guard let helper else { return finish(unavailable) }
        helper.install(zip: handle, sha256: sha256, version: version, reply: finish)
    }

    private func restart(into version: String) {
        phase = .restarting
        updateLog.notice("installed \(version, privacy: .public); restarting")
        defaults.set(version, forKey: key("JustUpdatedTo"))
        defaults.synchronize()
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: config) { [weak self] app, error in
            DispatchQueue.main.async {
                // Only quit once the new copy is running, so there's always a copy running.
                if app != nil, error == nil { NSApp.terminate(nil); return }
                self?.defaults.removeObject(forKey: self?.key("JustUpdatedTo") ?? "")
                self?.fail("\(UpdateConfig.appName) \(version) is installed. Quit \(UpdateConfig.appName) and open it again to start using it.")
            }
        }
    }

    private func fail(_ message: String) {
        DispatchQueue.main.async {
            updateLog.error("update failed: \(message, privacy: .public)")
            self.installFailed = true
            self.phase = .failed(message)
        }
    }

    // MARK: Words for the UI

    var statusText: String {
        switch phase {
        case .idle:
            if let lastChecked { return "Last checked \(lastChecked.formatted(.relative(presentation: .named)))" }
            return "Not checked yet"
        case .checking: return "Checking for updates…"
        case .upToDate: return "Up to date"
        case .available: return "Version \(update?.version ?? "") is available"
        case .downloading(let f): return f > 0 ? "Downloading… \(Int(f * 100))%" : "Downloading…"
        case .installing: return "Installing…"
        case .restarting: return "Restarting…"
        case .failed(let message): return message
        }
    }
}
