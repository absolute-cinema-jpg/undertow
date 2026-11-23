import Foundation

/// A version like "1.6" or "v1.10.2", compared number by number (so 1.10 is newer than 1.9,
/// and 1.6 is the same as 1.6.0).
struct AppVersion: Comparable, CustomStringConvertible {
    let parts: [Int]

    init?(_ text: String) {
        var t = text.trimmingCharacters(in: .whitespaces)
        if t.first == "v" || t.first == "V" { t.removeFirst() }
        let numbers = t.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard !numbers.isEmpty, numbers.count <= 4, numbers.allSatisfy({ ($0 ?? -1) >= 0 }) else { return nil }
        parts = numbers.map { $0! }
    }

    private func part(_ i: Int) -> Int { i < parts.count ? parts[i] : 0 }

    static func < (a: AppVersion, b: AppVersion) -> Bool {
        for i in 0..<max(a.parts.count, b.parts.count) where a.part(i) != b.part(i) { return a.part(i) < b.part(i) }
        return false
    }

    static func == (a: AppVersion, b: AppVersion) -> Bool { !(a < b) && !(b < a) }

    var description: String { parts.map(String.init).joined(separator: ".") }
}

/// The parts of GitHub's "latest release" answer that the updater uses.
struct GitHubRelease: Decodable, Equatable {
    struct Asset: Decodable, Equatable {
        let name: String
        let downloadURL: URL
        let size: Int
        /// e.g. "sha256:5b7a…" (GitHub adds this to newer uploads).
        let digest: String?

        enum CodingKeys: String, CodingKey {
            case name, size, digest
            case downloadURL = "browser_download_url"
        }
    }

    let tagName: String
    let name: String?
    let body: String?
    let pageURL: URL
    let draft: Bool
    let prerelease: Bool
    let assets: [Asset]

    enum CodingKeys: String, CodingKey {
        case name, body, draft, prerelease, assets
        case tagName = "tag_name"
        case pageURL = "html_url"
    }
}

/// A newer version that can be installed.
struct AvailableUpdate: Equatable {
    let version: String
    let notes: String
    let pageURL: URL
    let zipURL: URL
    let zipSize: Int
    /// From GitHub's digest, when it has one…
    let sha256: String?
    /// …otherwise from the release's "<zip>.sha256" file.
    let checksumURL: URL?
}

enum UpdateError: Error, Equatable, LocalizedError {
    case notPublished
    case rateLimited
    case server(Int)
    case network(String)
    case unreadable
    case noDownload
    case untrustedDownload
    case checksumMissing
    case checksumMismatch
    case helper(String)

    var errorDescription: String? {
        switch self {
        case .notPublished: return "No published version was found on GitHub."
        case .rateLimited: return "GitHub is limiting update checks from your network right now. Try again in an hour."
        case .server(let code): return "GitHub didn't answer properly (error \(code)). Try again later."
        case .network(let message): return "Couldn't reach GitHub: \(message)"
        case .unreadable: return "GitHub's answer couldn't be read. Try again later."
        case .noDownload: return "The new version has no download for \(UpdateConfig.appName) yet."
        case .untrustedDownload: return "The download didn't come from GitHub, so it wasn't used."
        case .checksumMissing: return "The new version has no checksum, so it can't be checked. Download it from GitHub instead."
        case .checksumMismatch: return "The download was damaged (its checksum doesn't match). Nothing was changed. Try again."
        case .helper(let message): return message
        }
    }
}

enum UpdateLogic {
    static var repo: String { UpdateConfig.repo }
    static var latestReleaseAPI: URL { URL(string: "https://api.github.com/repos/\(repo)/releases/latest")! }
    static var releasesPage: URL { URL(string: "https://github.com/\(repo)/releases/latest")! }
    
    static func releasePage(for version: String) -> URL {
        URL(string: "https://github.com/\(repo)/releases/tag/v\(version)")!
    }

    /// Where to ask for the latest release. Tests can point this at a server on this Mac
    /// (`-UpdateFeedURL http://127.0.0.1:…`); anything else is ignored.
    static func feedURL(override: String?) -> URL {
        if let override, let url = URL(string: override), isLocalTestURL(url) { return url }
        return latestReleaseAPI
    }

    static func isLocalTestURL(_ url: URL) -> Bool {
        url.scheme == "http" && url.host == "127.0.0.1"
    }

    /// Downloads must come from GitHub over HTTPS (or the local test server, in tests).
    static func isTrustedDownload(_ url: URL, allowLocal: Bool) -> Bool {
        if allowLocal && isLocalTestURL(url) { return true }
        guard url.scheme == "https", let host = url.host?.lowercased() else { return false }
        return host == "github.com" || host.hasSuffix(".githubusercontent.com")
    }

    /// nil if `release` isn't newer than `current`; throws if it's newer but has nothing to install.
    static func update(from release: GitHubRelease, current: AppVersion) throws -> AvailableUpdate? {
        guard !release.draft, !release.prerelease,
              let version = AppVersion(release.tagName), version > current else { return nil }
        let prefix = UpdateConfig.assetPrefix
        let zips = release.assets.filter { $0.name.hasPrefix(prefix) && $0.name.hasSuffix(".zip") }
        guard let zip = zips.first(where: { $0.name == "\(prefix)\(version).zip" }) ?? zips.first
        else { throw UpdateError.noDownload }
        let digest = zip.digest.flatMap { d -> String? in
            guard d.lowercased().hasPrefix("sha256:") else { return nil }
            let hex = String(d.dropFirst(7)).lowercased()
            return UpdateShared.isSHA256(hex) ? hex : nil
        }
        let checksumFile = release.assets.first { $0.name == zip.name + ".sha256" }?.downloadURL
        guard digest != nil || checksumFile != nil else { throw UpdateError.checksumMissing }
        return AvailableUpdate(version: version.description, notes: whatsNew(release.body ?? ""),
                               pageURL: release.pageURL, zipURL: zip.downloadURL, zipSize: zip.size,
                               sha256: digest, checksumURL: checksumFile)
    }

    /// Reads a "<hash>  <file>" checksum file.
    static func parseChecksum(_ text: String) -> String? {
        guard let first = text.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }).first else { return nil }
        let hex = first.lowercased()
        return UpdateShared.isSHA256(hex) ? hex : nil
    }

    /// The "What's new" part of the release notes: everything under the first heading, up
    /// to the next one (the install steps that follow aren't needed inside the app).
    static func whatsNew(_ body: String) -> String {
        let lines = body.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        guard let start = lines.firstIndex(where: { $0.hasPrefix("## ") }) else {
            return body.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let rest = lines[(start + 1)...]
        let end = rest.firstIndex(where: { $0.hasPrefix("## ") }) ?? lines.endIndex
        return lines[(start + 1)..<end].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
