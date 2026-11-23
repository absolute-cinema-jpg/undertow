import Foundation

/// Swaps a downloaded copy of the app in for the installed one. Runs inside the updater
/// helper, which macOS restricts to writing only the app bundle, a staging folder beside it
/// and its own temp folder (see main.swift). Also compiled into the unit tests.
enum Installer {
    struct Failure: Error, LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }

    /// The app this helper is inside: …/My App.app/Contents/XPCServices/Updater.xpc
    static func containingApp(ofHelper helper: URL) -> URL? {
        let app = helper.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        guard app.pathExtension == "app", helper.deletingLastPathComponent().lastPathComponent == "XPCServices" else { return nil }
        return app
    }

    /// Unpacked here, beside the app, so the final swap is a single rename on the same disk.
    static func stagingFolder(for app: URL) -> URL {
        app.deletingLastPathComponent()
            .appendingPathComponent(".\(name(of: app)) update", isDirectory: true)
    }

    static func name(of app: URL) -> String { app.deletingPathExtension().lastPathComponent }

    /// Apps opened from Downloads without being moved run from a hidden, read-only copy.
    static func isTranslocated(_ app: URL) -> Bool {
        app.path.contains("/AppTranslocation/")
    }

    /// - Parameters:
    ///   - zip: the downloaded release zip (already checksummed by the app; checked again here).
    ///   - version: the CFBundleShortVersionString the new copy must have.
    ///   - app: the installed copy to replace.
    ///   - bundleID: the identifier the new copy must have.
    static func install(zip: URL, sha256: String, version: String, over app: URL, bundleID: String) throws {
        let appName = name(of: app)
        guard !isTranslocated(app) else {
            throw Failure("\(appName) is running from a temporary copy. Move it into your Applications folder, open it from there, then update.")
        }
        guard try UpdateShared.sha256(of: zip) == sha256.lowercased() else {
            throw Failure("The download was damaged (its checksum doesn't match). Nothing was changed. Try again.")
        }
        let fm = FileManager.default
        let staging = stagingFolder(for: app)
        try? fm.removeItem(at: staging)
        guard mkdir(staging.path, 0o755) == 0 else { throw permissionFailure(app, errno: errno) }
        defer { try? fm.removeItem(at: staging) }

        // --noqtn: don't copy the download's quarantine mark onto the app.
        try run("/usr/bin/ditto", ["-x", "-k", "--noqtn", zip.path, staging.path],
                otherwise: "The download couldn't be unpacked. Nothing was changed.")
        let found = ((try? fm.contentsOfDirectory(at: staging, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "app" }
        guard found.count == 1, let new = found.first else {
            throw Failure("The download doesn't contain \(appName). Nothing was changed.")
        }
        let info = NSDictionary(contentsOf: new.appendingPathComponent("Contents/Info.plist"))
        guard info?["CFBundleIdentifier"] as? String == bundleID else {
            throw Failure("The download isn't \(appName), so it wasn't installed.")
        }
        guard info?["CFBundleShortVersionString"] as? String == version else {
            throw Failure("The download is a different version from the one expected, so it wasn't installed.")
        }
        try run("/usr/bin/codesign", ["--verify", "--strict", "--deep", new.path],
                otherwise: "The download's code signature isn't valid, so it wasn't installed.")
        // An update may never quietly take away the App Sandbox.
        if isSandboxed(app) && !isSandboxed(new) {
            throw Failure("The download doesn't run in the App Sandbox, so it wasn't installed.")
        }
        removeQuarantine(under: new)

        // Swap the two in one step, so there's never a moment with no app installed.
        // Afterwards the old version sits in the staging folder, which is then removed.
        if renamex_np(new.path, app.path, UInt32(RENAME_SWAP)) != 0 {
            let failure = errno
            guard failure == ENOTSUP || failure == EINVAL else { throw permissionFailure(app, errno: failure) }
            let old = staging.appendingPathComponent("previous.app")
            guard rename(app.path, old.path) == 0 else { throw permissionFailure(app, errno: errno) }
            guard rename(new.path, app.path) == 0 else {
                let e = errno
                rename(old.path, app.path)
                throw permissionFailure(app, errno: e)
            }
        }
    }

    static func permissionFailure(_ app: URL, errno code: Int32) -> Failure {
        let appName = name(of: app)
        let folder = app.deletingLastPathComponent().lastPathComponent
        if code == EPERM || code == EACCES || code == EROFS {
            return Failure("macOS didn't let \(appName) replace itself in “\(folder)”. If you're not an administrator on this Mac, ask someone who is. If you are, allow \(appName) under System Settings → Privacy & Security → App Management, or download the new version from GitHub.")
        }
        return Failure("\(appName) couldn't replace itself in “\(folder)” (error \(code)). Nothing was changed.")
    }

    /// Reads the app's entitlements and checks the App Sandbox is on.
    static func isSandboxed(_ app: URL) -> Bool {
        guard let out = try? output("/usr/bin/codesign", ["-d", "--entitlements", "-", "--xml", app.path]),
              let start = out.range(of: Data("<?xml".utf8)),
              let plist = try? PropertyListSerialization.propertyList(from: out[start.lowerBound...], format: nil) as? [String: Any]
        else { return false }
        return plist["com.apple.security.app-sandbox"] as? Bool == true
    }

    static func removeQuarantine(under root: URL) {
        removexattr(root.path, "com.apple.quarantine", XATTR_NOFOLLOW)
        let items = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        while let item = items?.nextObject() as? URL {
            removexattr(item.path, "com.apple.quarantine", XATTR_NOFOLLOW)
        }
    }

    private static func run(_ tool: String, _ args: [String], otherwise message: String) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { throw Failure(message) }
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw Failure(message) }
    }

    private static func output(_ tool: String, _ args: [String]) throws -> Data {
        let p = Process()
        let pipe = Pipe()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        try p.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return data
    }
}
