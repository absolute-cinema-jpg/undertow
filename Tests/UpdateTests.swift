// Tests for the updater's logic and installer. Runs on its own, silently:
//   swiftc -parse-as-library <app>/UpdateConfig.swift UpdateShared.swift UpdateLogic.swift \
//          Updater/Installer.swift Tests/UpdateTests.swift -o /tmp/update-tests && /tmp/update-tests
// (scripts/run-update-tests.sh does this.) Uses the app's real UpdateConfig.
import Foundation

private var failures = 0
private func check(_ ok: Bool, _ message: String) {
    print(ok ? "  ✓ \(message)" : "  ✗ \(message)")
    if !ok { failures += 1 }
}

@main enum UpdateTests {
    static func main() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("update-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        logicTests()
        try installerTests(dir)
        print(failures == 0 ? "\nAll update tests passed." : "\n\(failures) update tests FAILED")
        exit(failures == 0 ? 0 : 1)
    }

    static func logicTests() {
        print("Versions")
        let v = { (s: String) in AppVersion(s)! }
        check(v("1.10") > v("1.9") && v("1.6.1") > v("1.6") && v("2.0") > v("1.99"), "versions compare number by number")
        check(v("v1.6") == v("1.6.0") && !(v("1.6") < v("1.6")), "“v1.6” is the same as 1.6.0")
        check(AppVersion("1.x") == nil && AppVersion("") == nil && AppVersion("beta") == nil, "anything that isn't a version is rejected")

        print("GitHub's answer")
        let prefix = UpdateConfig.assetPrefix, repo = UpdateConfig.repo
        let sha = String(repeating: "ab", count: 32)
        func release(tag: String = "v99.1", draft: Bool = false, assets: String? = nil) -> GitHubRelease {
            let defaultAssets = """
              {"name": "\(prefix)99.1.zip", "size": 2351604, "digest": "sha256:\(sha)",
               "browser_download_url": "https://github.com/\(repo)/releases/download/v99.1/\(prefix)99.1.zip"},
              {"name": "\(prefix)99.1.zip.sha256", "size": 84, "digest": null,
               "browser_download_url": "https://github.com/\(repo)/releases/download/v99.1/\(prefix)99.1.zip.sha256"}
            """
            let json = """
            {"tag_name": "\(tag)", "name": "Release", "draft": \(draft), "prerelease": false,
             "html_url": "https://github.com/\(repo)/releases/tag/\(tag)",
             "body": "## What's new\\n\\n**Updates.** One click.\\n- Bug reports\\n\\n## Install or update\\n1. Download",
             "assets": [\(assets ?? defaultAssets)], "author": {"login": "someone"}, "id": 1}
            """
            return try! JSONDecoder().decode(GitHubRelease.self, from: Data(json.utf8))
        }
        let found = try? UpdateLogic.update(from: release(), current: v("1.0"))
        check(found?.version == "99.1" && found?.sha256 == sha && found?.zipURL.lastPathComponent == "\(prefix)99.1.zip",
              "a newer release is found, with its download and checksum")
        check(found?.notes == "**Updates.** One click.\n- Bug reports", "only the first section of the notes is kept")
        check((try? UpdateLogic.update(from: release(), current: v("99.1"))) == nil
              && (try? UpdateLogic.update(from: release(), current: v("100"))) == nil, "the same or an older version isn't offered")
        check((try? UpdateLogic.update(from: release(draft: true), current: v("1.0"))) == nil, "drafts aren't offered")
        let noDigest = """
          {"name": "\(prefix)99.1.zip", "size": 1, "browser_download_url": "https://github.com/x/y/releases/download/v99.1/\(prefix)99.1.zip"},
          {"name": "\(prefix)99.1.zip.sha256", "size": 84, "browser_download_url": "https://github.com/x/y/releases/download/v99.1/\(prefix)99.1.zip.sha256"}
        """
        let viaFile = try? UpdateLogic.update(from: release(assets: noDigest), current: v("1.0"))
        check(viaFile?.sha256 == nil && viaFile?.checksumURL?.lastPathComponent == "\(prefix)99.1.zip.sha256",
              "without GitHub's digest, the .sha256 file is used")
        func throwsError(_ expected: UpdateError, _ assets: String) -> Bool {
            do { _ = try UpdateLogic.update(from: release(assets: assets), current: v("1.0")); return false }
            catch { return error as? UpdateError == expected }
        }
        check(throwsError(.noDownload, ""), "a release with no zip can't be installed")
        check(throwsError(.checksumMissing, #"{"name": "\#(prefix)99.1.zip", "size": 1, "browser_download_url": "https://github.com/a.zip"}"#),
              "a release with no checksum can't be installed")
        check(UpdateLogic.parseChecksum("\(sha)  \(prefix)99.1.zip\n") == sha && UpdateLogic.parseChecksum("not a checksum") == nil,
              "checksum files are read")

        print("Where downloads may come from")
        check(UpdateLogic.isTrustedDownload(URL(string: "https://github.com/a/b/releases/download/v1/x.zip")!, allowLocal: false)
              && UpdateLogic.isTrustedDownload(URL(string: "https://objects.githubusercontent.com/x")!, allowLocal: false)
              && UpdateLogic.isTrustedDownload(URL(string: "https://release-assets.githubusercontent.com/x")!, allowLocal: false),
              "GitHub over HTTPS is trusted")
        check(!UpdateLogic.isTrustedDownload(URL(string: "http://github.com/x.zip")!, allowLocal: false)
              && !UpdateLogic.isTrustedDownload(URL(string: "https://evilgithub.com/x.zip")!, allowLocal: false)
              && !UpdateLogic.isTrustedDownload(URL(string: "https://githubusercontent.com.evil.net/x.zip")!, allowLocal: false)
              && !UpdateLogic.isTrustedDownload(URL(string: "http://127.0.0.1:8000/x.zip")!, allowLocal: false),
              "plain HTTP, look-alike hosts and this Mac aren't")
        check(UpdateLogic.feedURL(override: "http://127.0.0.1:8765/latest") == URL(string: "http://127.0.0.1:8765/latest")!
              && UpdateLogic.feedURL(override: "https://evil.example/latest") == UpdateLogic.latestReleaseAPI
              && UpdateLogic.feedURL(override: nil) == UpdateLogic.latestReleaseAPI,
              "only a test server on this Mac can replace GitHub as the update source")
        check(UpdateLogic.latestReleaseAPI.absoluteString == "https://api.github.com/repos/\(repo)/releases/latest",
              "it asks GitHub about \(repo)")
    }

    static func installerTests(_ dir: URL) throws {
        print("Installing")
        let fm = FileManager.default
        let sandboxed = dir.appendingPathComponent("sandboxed.entitlements")
        try Data("""
        <?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict><key>com.apple.security.app-sandbox</key><true/></dict></plist>
        """.utf8).write(to: sandboxed)

        /// A tiny signed app bundle that says which version it is.
        func makeApp(at url: URL, id: String = "local.updatetests.app", version: String, sandbox: Bool = true) throws {
            try? fm.removeItem(at: url)
            try fm.createDirectory(at: url.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
            try fm.copyItem(atPath: "/usr/bin/true", toPath: url.appendingPathComponent("Contents/MacOS/Test").path)
            let info: [String: Any] = ["CFBundleIdentifier": id, "CFBundleShortVersionString": version,
                                       "CFBundleExecutable": "Test", "CFBundlePackageType": "APPL"]
            try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
                .write(to: url.appendingPathComponent("Contents/Info.plist"))
            try fm.createDirectory(at: url.appendingPathComponent("Contents/Resources"), withIntermediateDirectories: true)
            try Data(version.utf8).write(to: url.appendingPathComponent("Contents/Resources/version.txt"))
            try shell("/usr/bin/codesign", ["--force", "--sign", "-"] + (sandbox ? ["--entitlements", sandboxed.path] : []) + [url.path])
        }
        func zip(_ app: URL) throws -> URL {
            let out = dir.appendingPathComponent("\(UUID().uuidString).zip")
            try shell("/usr/bin/ditto", ["-c", "-k", "--keepParent", app.path, out.path])
            // As if it had come from the internet.
            try shell("/usr/bin/xattr", ["-w", "com.apple.quarantine", "0083;6700a000;Safari;", out.path])
            return out
        }
        func versionInstalled(_ app: URL) -> String? {
            try? String(contentsOf: app.appendingPathComponent("Contents/Resources/version.txt"))
        }
        func refused(_ zip: URL, version: String = "1.7", id: String = "local.updatetests.app", sha: String? = nil, over app: URL) -> String? {
            do {
                try Installer.install(zip: zip, sha256: sha ?? UpdateShared.sha256(of: zip), version: version, over: app, bundleID: id)
                return nil
            } catch { return error.localizedDescription }
        }

        let apps = dir.appendingPathComponent("Applications")
        try fm.createDirectory(at: apps, withIntermediateDirectories: true)
        let installed = apps.appendingPathComponent("Test App.app")
        let builds = dir.appendingPathComponent("builds")
        try makeApp(at: installed, version: "1.6")

        check(Installer.containingApp(ofHelper: installed.appendingPathComponent("Contents/XPCServices/Updater.xpc"))?.path == installed.path
              && Installer.containingApp(ofHelper: URL(fileURLWithPath: "/tmp/Updater.xpc")) == nil,
              "the helper finds the app it's inside")
        check(Installer.stagingFolder(for: installed).lastPathComponent == ".Test App update"
              && Installer.stagingFolder(for: installed).deletingLastPathComponent().path == apps.path,
              "it unpacks beside the app, so the swap is one rename")

        let good = builds.appendingPathComponent("Test App.app")
        try makeApp(at: good, version: "1.7")
        let goodZip = try zip(good)
        check(refused(goodZip, sha: String(repeating: "0", count: 64), over: installed)?.contains("checksum") == true
              && versionInstalled(installed) == "1.6", "a damaged download is refused and nothing changes")
        check(refused(goodZip, version: "1.8", over: installed)?.contains("different version") == true
              && versionInstalled(installed) == "1.6", "a download that isn't the expected version is refused")
        check(refused(goodZip, id: "com.someone.else", over: installed)?.contains("isn't Test App") == true,
              "a download of some other app is refused")

        let unsandboxed = builds.appendingPathComponent("Unsandboxed/Test App.app")
        try makeApp(at: unsandboxed, version: "1.7", sandbox: false)
        let unsandboxedZip = try zip(unsandboxed)
        check(refused(unsandboxedZip, over: installed)?.contains("App Sandbox") == true && versionInstalled(installed) == "1.6",
              "a sandboxed app won't update to a build without the App Sandbox")

        let tampered = builds.appendingPathComponent("Tampered/Test App.app")
        try makeApp(at: tampered, version: "1.7")
        try Data("evil".utf8).write(to: tampered.appendingPathComponent("Contents/Resources/version.txt"))
        check(refused(try zip(tampered), over: installed)?.contains("signature") == true && versionInstalled(installed) == "1.6",
              "a build changed after signing is refused")

        let empty = builds.appendingPathComponent("Empty")
        try fm.createDirectory(at: empty, withIntermediateDirectories: true)
        try Data().write(to: empty.appendingPathComponent("readme.txt"))
        check(refused(try zip(empty), over: installed)?.contains("doesn't contain") == true, "a zip without the app is refused")

        check(refused(goodZip, over: installed) == nil, "a good download installs")
        check(versionInstalled(installed) == "1.7", "…and the new version is in place")
        check(!fm.fileExists(atPath: Installer.stagingFolder(for: installed).path), "…the old version and staging folder are gone")
        let names = (try? fm.contentsOfDirectory(atPath: apps.path)) ?? []
        check(names == ["Test App.app"], "…nothing else is left beside it: \(names)")
        check(getxattr(installed.path, "com.apple.quarantine", nil, 0, 0, XATTR_NOFOLLOW) < 0,
              "…and it isn't marked as downloaded, so macOS opens it without asking")
        check((try? shell("/usr/bin/codesign", ["--verify", "--strict", installed.path])) != nil, "…with its signature intact")

        let plain = apps.appendingPathComponent("Plain App.app")
        try makeApp(at: plain, id: "local.updatetests.plain", version: "1.6", sandbox: false)
        let plainNew = builds.appendingPathComponent("Plain/Plain App.app")
        try makeApp(at: plainNew, id: "local.updatetests.plain", version: "1.7", sandbox: false)
        check(refused(try zip(plainNew), id: "local.updatetests.plain", over: plain) == nil && versionInstalled(plain) == "1.7",
              "an app without the App Sandbox can update too")

        check(refused(goodZip, over: apps.appendingPathComponent("../AppTranslocation/x/Test App.app"))?.contains("temporary copy") == true,
              "running from a temporary copy (not moved out of Downloads) is caught")
    }

    @discardableResult
    static func shell(_ tool: String, _ args: [String]) throws -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        if p.terminationStatus != 0 { throw NSError(domain: tool, code: Int(p.terminationStatus)) }
        return p.terminationStatus
    }
}
