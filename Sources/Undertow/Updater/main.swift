// The updater helper, embedded in the app as Contents/XPCServices/Updater.xpc.
// Compile it on its own with UpdateShared.swift and Installer.swift (it's a separate program,
// and this file has top-level code, so it must be called main.swift).
//
// Why it exists: macOS's App Sandbox marks everything a sandboxed app writes as "downloaded"
// and won't let it remove that mark, so a sandboxed app can't install its own update (macOS
// would block the new version from opening, or ask for "Open Anyway" after every update).
//
// It starts outside the App Sandbox, but before it accepts any request it puts itself in a
// sandbox of its own: macOS then refuses every write except to this copy of the app, the
// staging folder beside it and the helper's temp folder, and refuses all network access.
// Tools it runs (ditto, codesign) inherit the same limits.
import Foundation
import os

@_silgen_name("sandbox_init")
private func sandbox_init(_ profile: UnsafePointer<CChar>, _ flags: UInt64,
                          _ error: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> Int32

/// The real path. macOS's sandbox checks real paths (/private/var, not /var), and
/// URL.resolvingSymlinksInPath strips /private, so use realpath(3).
private func realPath(_ path: String) -> String? {
    guard let resolved = realpath(path, nil) else { return nil }
    defer { free(resolved) }
    return String(cString: resolved)
}

private func quoted(_ path: String) -> String {
    "\"" + path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
}

private func restrict(writingTo paths: [String], log: Logger) -> Bool {
    let profile = """
    (version 1)
    (allow default)
    (deny network*)
    (deny file-write*)
    (allow file-write* \(paths.map { "(subpath \(quoted($0)))" }.joined(separator: " ")) (literal "/dev/null"))
    """
    var error: UnsafeMutablePointer<CChar>?
    let ok = sandbox_init(profile, 0, &error) == 0
    if let error { log.error("sandbox_init: \(String(cString: error), privacy: .public)"); free(error) }
    return ok
}

private final class Service: NSObject, UpdateInstalling {
    let app: URL, bundleID: String, temp: URL, log: Logger

    init(app: URL, bundleID: String, temp: URL, log: Logger) {
        self.app = app; self.bundleID = bundleID; self.temp = temp; self.log = log
    }

    func install(zip: FileHandle, sha256: String, version: String, reply: @escaping (String?) -> Void) {
        let copy = temp.appendingPathComponent("update.zip")
        defer { try? FileManager.default.removeItem(at: copy) }
        do {
            // The download sits in the app's sandbox folder, so it's handed over as an open file.
            FileManager.default.createFile(atPath: copy.path, contents: nil)
            let out = try FileHandle(forWritingTo: copy)
            while let chunk = try zip.read(upToCount: 1 << 20), !chunk.isEmpty { try out.write(contentsOf: chunk) }
            try out.close()
            try Installer.install(zip: copy, sha256: sha256, version: version, over: app, bundleID: bundleID)
            log.notice("installed version \(version, privacy: .public)")
            reply(nil)
        } catch {
            log.error("install failed: \(error.localizedDescription, privacy: .public)")
            reply(error.localizedDescription)
        }
    }
}

private final class Delegate: NSObject, NSXPCListenerDelegate {
    let service: Service
    init(_ service: Service) { self.service = service }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = NSXPCInterface(with: UpdateInstalling.self)
        connection.exportedObject = service
        connection.resume()
        return true
    }
}

private let fallbackLog = Logger(subsystem: Bundle.main.bundleIdentifier ?? "updater", category: "update")

guard let app = Installer.containingApp(ofHelper: Bundle.main.bundleURL),
      let appParent = realPath(app.deletingLastPathComponent().path),
      let bundleID = Bundle(url: app)?.bundleIdentifier,
      Bundle.main.bundleIdentifier == UpdateShared.serviceName(forApp: bundleID)
else {
    fallbackLog.error("the updater isn't inside its app; refusing to run")
    exit(1)
}
private let log = Logger(subsystem: bundleID, category: "update")
let realApp = URL(fileURLWithPath: appParent).appendingPathComponent(app.lastPathComponent)
var tempBuffer = [CChar](repeating: 0, count: Int(PATH_MAX))
confstr(_CS_DARWIN_USER_TEMP_DIR, &tempBuffer, tempBuffer.count)
guard let temp = realPath(String(cString: tempBuffer)),
      restrict(writingTo: [realApp.path, Installer.stagingFolder(for: realApp).path, temp], log: log)
else {
    log.error("couldn't restrict the updater; refusing to run")
    exit(1)
}

private let delegate = Delegate(Service(app: realApp, bundleID: bundleID, temp: URL(fileURLWithPath: temp), log: log))
let listener = NSXPCListener.service()
listener.delegate = delegate
listener.resume()
