import CShim
import Foundation
import Security

public enum AppKind: String, Codable, Sendable {
    case app, commandLine, system, kernel, exited
}

/// What a process appears to be. Everything from a bundle's Info.plist is the app's own
/// claim, and an app can claim anything. Decisions that exempt an app from scrutiny must go
/// through the `isVerified…` methods, which check those claims against its code signature.
public struct AppIdentity: Equatable, Sendable, Identifiable {
    /// Stable across restarts: bundle ID, or executable path for loose binaries.
    public var id: String
    public var name: String
    public var kind: AppKind
    /// Bundle if there is one, otherwise the executable. Used for icons and Reveal in Finder.
    public var path: String?
    public var executable: String?
    public var bundleID: String?
    /// Plain-English explanation for macOS daemons with cryptic names.
    public var explanation: String?
    /// The bundle ID looks like a browser's. Unverified on its own.
    public var claimsBrowser: Bool
    /// What launched it, for command-line tools. "curl, started by Terminal" is useful context.
    public var launchedBy: String?

    public init(id: String, name: String, kind: AppKind, path: String?, executable: String?, bundleID: String?,
                explanation: String?, claimsBrowser: Bool, launchedBy: String?) {
        self.id = id
        self.name = name
        self.kind = kind
        self.path = path
        self.executable = executable
        self.bundleID = bundleID
        self.explanation = explanation
        self.claimsBrowser = claimsBrowser
        self.launchedBy = launchedBy
    }

    /// `.system` and `.kernel` come from paths System Integrity Protection guards, so they can
    /// be taken at face value. An app has to prove it with Apple's signature. Command-line tools
    /// never qualify: curl, python3 and nc are signed by Apple but do whatever their caller asks,
    /// which makes them an obvious way to send data out.
    public func isVerifiedApple(signer: SignerInfo?) -> Bool {
        kind == .system || kind == .kernel || (kind == .app && signer?.status == .apple)
    }

    public func isVerifiedBrowser(signer: SignerInfo?) -> Bool {
        claimsBrowser && signer?.status.isVerified == true
    }

    /// Uses an Apple bundle ID without Apple's signature, which no legitimate app has reason to do.
    public func impersonatesApple(signer: SignerInfo?) -> Bool {
        guard kind == .app, let signer, bundleID?.hasPrefix("com.apple.") == true else { return false }
        return signer.status != .apple
    }

    /// What a trust decision is bound to. Nil means this can't be trusted, because there's
    /// nothing stable to tie the decision to.
    public func trustKey(signer: SignerInfo?) -> String? {
        switch kind {
        case .system, .kernel: return "system"
        case .exited: return nil
        case .app, .commandLine: return signer?.trustKey
        }
    }
}

/// Plain-English names for the macOS services that most often show up in a network monitor.
public let systemServiceNames: [String: (name: String, why: String)] = [
    "kernel_task": ("macOS network drives", "The kernel itself. This is usually SMB or AFP traffic to a NAS or file server."),
    "mDNSResponder": ("DNS & Bonjour", "Looks up website addresses and finds devices on your local network."),
    "nsurlsessiond": ("Background transfers", "Downloads and uploads that macOS runs on behalf of other apps."),
    "cloudd": ("iCloud sync", "Syncs app data to iCloud."),
    "bird": ("iCloud Drive", "Syncs files in iCloud Drive."),
    "fileproviderd": ("Cloud file sync", "Syncs files for iCloud Drive and other cloud storage apps."),
    "photoanalysisd": ("Photos analysis", "Processes your photo library."),
    "cloudphotod": ("iCloud Photos", "Syncs your photo library to iCloud."),
    "softwareupdated": ("Software Update", "Checks for and downloads macOS updates."),
    "mobileassetd": ("macOS assets", "Downloads system components such as fonts, voices and language data."),
    "trustd": ("Certificate checks", "Verifies the security certificates of apps and websites."),
    "syspolicyd": ("Gatekeeper", "Checks that apps are safe to open."),
    "apsd": ("Apple Push", "Delivers notifications from Apple's push service."),
    "rapportd": ("Handoff & Continuity", "Talks to your other Apple devices nearby."),
    "sharingd": ("AirDrop & Sharing", "Handles AirDrop and shared clipboard."),
    "identityservicesd": ("Apple ID messaging", "Supports iMessage and FaceTime."),
    "imagent": ("Messages", "Sends and receives iMessage."),
    "akd": ("Apple ID", "Handles Apple ID sign-in."),
    "accountsd": ("Internet Accounts", "Connects to the accounts in System Settings."),
    "parsecd": ("Spotlight & Siri suggestions", "Fetches online suggestions."),
    "assistantd": ("Siri", "Handles Siri requests."),
    "netbiosd": ("Windows network discovery", "Finds Windows and SMB devices on your local network."),
    "timed": ("Network time", "Keeps your clock accurate."),
    "ntpd": ("Network time", "Keeps your clock accurate."),
    "configd": ("Network configuration", "Manages your network settings."),
    "locationd": ("Location Services", "Works out your location."),
    "AirPlayXPCHelper": ("AirPlay", "Streams to AirPlay devices."),
    "tailspind": ("Diagnostics", "Collects system performance data."),
    "analyticsd": ("Apple analytics", "Sends diagnostics to Apple, if you opted in."),
    "SubmitDiagInfo": ("Apple diagnostics", "Sends diagnostic reports to Apple, if you opted in."),
    "storedownloadd": ("App Store downloads", "Downloads apps from the App Store."),
    "commerce": ("App Store", "Handles App Store purchases and updates."),
    "backupd": ("Time Machine", "Backs up your Mac."),
    "ControlCenter": ("Control Center", "Part of the macOS menu bar."),
    "WiFiAgent": ("Wi-Fi", "Manages Wi-Fi connections."),
    "airportd": ("Wi-Fi", "Manages Wi-Fi connections."),
    "swcd": ("Shared web credentials", "Links apps with their websites, for passwords and Universal Links."),
    "networkserviceproxy": ("iCloud Private Relay", "Apple's privacy relay for web traffic, if you have it turned on."),
    "ocspd": ("Certificate checks", "Checks whether security certificates have been revoked."),
    "nsurlstoraged": ("Web cache", "Manages cached web data for apps."),
    "CalendarAgent": ("Calendar sync", "Syncs your calendars."),
    "remindd": ("Reminders sync", "Syncs your reminders."),
    "suggestd": ("Siri Suggestions", "Prepares suggestions from your apps."),
    "biomesyncd": ("Device activity sync", "Syncs on-device activity between your Apple devices."),
    "wifip2pd": ("Wi-Fi Direct", "Handles direct connections for AirDrop and AirPlay."),
    "mediaremoted": ("Media controls", "Handles Now Playing and remote media controls."),
    "searchpartyd": ("Find My", "Supports Find My."),
    "icloudmailagent": ("iCloud Mail", "Syncs iCloud Mail settings."),
]

private let browserBundlePrefixes = [
    "com.apple.Safari", "com.google.Chrome", "com.brave.Browser", "org.mozilla.firefox",
    "com.microsoft.edgemac", "company.thebrowser.Browser", "com.operasoftware.Opera",
    "com.vivaldi.Vivaldi", "org.chromium.Chromium", "app.zen-browser.zen", "org.torproject.torbrowser",
]

public enum IdentityRules {
    /// Finds the outermost .app in a path, which folds "Brave Browser Helper" and its
    /// siblings into one "Brave Browser" row.
    public static func outermostApp(in path: String) -> String? {
        guard let r = path.range(of: ".app/") else { return path.hasSuffix(".app") ? path : nil }
        return String(path[..<r.lowerBound]) + ".app"
    }

    public static func claimsBrowser(bundleID: String?) -> Bool {
        guard let id = bundleID else { return false }
        return browserBundlePrefixes.contains { id.hasPrefix($0) }
    }
}

/// Resolves a pid to the app a person would recognise.
public final class IdentityResolver {
    private var byPID: [Int32: (identity: AppIdentity, path: String)] = [:]
    /// Where each process runs from, recorded while it's alive. Sockets in TIME_WAIT outlive
    /// their process, so this is what lets a quick script be named after it has exited.
    private var knownPaths: [Int32: (path: String, goneSince: Date?)] = [:]
    public init() {}

    public func identity(for pid: Int32) -> AppIdentity {
        if pid == 0 { return kernelIdentity }
        let path = Self.path(of: pid) ?? knownPaths[pid]?.path
        guard let path else { return exitedIdentity }
        if let cached = byPID[pid], cached.path == path { return cached.identity }
        let resolved = resolve(pid: pid, path: path)
        byPID[pid] = (resolved, path)
        return resolved
    }

    /// Call once per sample. Paths are only looked up for processes not seen before, so this
    /// stays cheap, and anything alive at one sample can still be named after it exits.
    public func observeRunningProcesses(now: Date = Date()) {
        var pids = [pid_t](repeating: 0, count: 8192)
        let count = Int(un_list_pids(&pids, Int32(pids.count)))
        var live = Set<Int32>(minimumCapacity: count)
        for pid in pids.prefix(count) where pid > 0 {
            live.insert(pid)
            if knownPaths[pid] == nil || knownPaths[pid]?.goneSince != nil, let path = Self.path(of: pid) {
                knownPaths[pid] = (path, nil)
            }
        }
        for (pid, entry) in knownPaths where !live.contains(pid) {
            if let gone = entry.goneSince {
                if now.timeIntervalSince(gone) > 120 { knownPaths[pid] = nil }
            } else {
                knownPaths[pid] = (entry.path, now)
            }
        }
    }

    /// Lets the identity cache shrink over time.
    public func prune(keeping live: Set<Int32>) {
        byPID = byPID.filter { live.contains($0.key) }
    }

    private var kernelIdentity: AppIdentity {
        let info = systemServiceNames["kernel_task"]!
        return AppIdentity(
            id: "system:kernel_task", name: info.name, kind: .kernel, path: nil, executable: nil, bundleID: nil,
            explanation: info.why, claimsBrowser: false, launchedBy: nil)
    }

    private var exitedIdentity: AppIdentity {
        AppIdentity(
            id: "exited", name: "Unidentified, already exited", kind: .exited, path: nil, executable: nil, bundleID: nil,
            explanation: "A process that started and exited between samples, so it could not be named. Worth a look if it sent much.",
            claimsBrowser: false, launchedBy: nil)
    }

    private func resolve(pid: Int32, path: String) -> AppIdentity {
        let execName = (path as NSString).lastPathComponent

        // Network and system extensions report as themselves, even when they live inside an app.
        for suffix in [".systemextension", ".appex"] {
            if let r = path.range(of: suffix + "/") {
                let bundlePath = String(path[..<r.lowerBound]) + suffix
                let info = Bundle(path: bundlePath)?.infoDictionary
                let id = info?["CFBundleIdentifier"] as? String ?? path
                return AppIdentity(
                    id: id, name: Self.displayName(info: info, fallback: bundlePath),
                    kind: .app, path: bundlePath, executable: path, bundleID: id, explanation: nil,
                    claimsBrowser: false, launchedBy: nil)
            }
        }

        // XPC services belong to whoever asked for them, e.g. Safari's WebKit networking process.
        if path.contains(".xpc/") {
            let responsible = un_responsible_pid(pid)
            if responsible != pid, let owner = Self.path(of: responsible), IdentityRules.outermostApp(in: owner) != nil {
                return resolve(pid: responsible, path: owner)
            }
        }

        if let appPath = IdentityRules.outermostApp(in: path) {
            let info = Bundle(path: appPath)?.infoDictionary
            let bundleID = info?["CFBundleIdentifier"] as? String
            return AppIdentity(
                id: bundleID ?? appPath, name: Self.displayName(info: info, fallback: appPath),
                kind: .app, path: appPath, executable: path, bundleID: bundleID, explanation: nil,
                claimsBrowser: IdentityRules.claimsBrowser(bundleID: bundleID), launchedBy: nil)
        }

        let isSystemPath = path.hasPrefix("/System/") || path.hasPrefix("/usr/libexec/") || path.hasPrefix("/usr/sbin/")
        if isSystemPath, let friendly = systemServiceNames[execName] {
            return AppIdentity(
                id: "system:\(execName)", name: friendly.name, kind: .system, path: path, executable: path, bundleID: nil,
                explanation: friendly.why, claimsBrowser: false, launchedBy: nil)
        }
        if isSystemPath {
            return AppIdentity(
                id: "system:\(execName)", name: execName, kind: .system, path: path, executable: path, bundleID: nil,
                explanation: "A macOS system service.", claimsBrowser: false, launchedBy: nil)
        }

        // A loose binary is the most interesting kind: curl, a script runtime, a daemon.
        return AppIdentity(
            id: path, name: Sanitize.displayText(execName), kind: .commandLine, path: path, executable: path, bundleID: nil,
            explanation: nil, claimsBrowser: false, launchedBy: launcherName(pid: pid))
    }

    private func launcherName(pid: Int32) -> String? {
        let responsible = un_responsible_pid(pid)
        if responsible != pid, let p = Self.path(of: responsible), let app = IdentityRules.outermostApp(in: p) {
            return Self.displayName(info: Bundle(path: app)?.infoDictionary, fallback: app)
        }
        let parent = un_parent_pid(pid)
        guard parent > 1, let p = Self.path(of: parent) else { return nil }
        return (p as NSString).lastPathComponent
    }

    private static func displayName(info: [String: Any]?, fallback: String) -> String {
        if let n = info?["CFBundleDisplayName"] as? String, !n.isEmpty { return Sanitize.displayText(n) }
        if let n = info?["CFBundleName"] as? String, !n.isEmpty { return Sanitize.displayText(n) }
        return Sanitize.displayText(((fallback as NSString).lastPathComponent as NSString).deletingPathExtension)
    }

    private static func path(of pid: Int32) -> String? {
        var buf = [CChar](repeating: 0, count: 4096)
        guard un_proc_path(pid, &buf, UInt32(buf.count)) > 0 else { return nil }
        return String(cString: buf)
    }
}

// MARK: - Code signing

public enum SignerStatus: String, Codable, Sendable {
    case apple, developerID, appStore, development, untrustedCertificate, adHoc, unsigned, invalid, unknown

    /// The certificate chains to Apple and is one Apple issues for distributing software, so
    /// a real, accountable developer is behind it.
    public var isVerified: Bool { self == .apple || self == .developerID || self == .appStore }

    public var isSuspicious: Bool { !isVerified }

    public var label: String {
        switch self {
        case .apple: return "Apple"
        case .developerID: return "Verified developer"
        case .appStore: return "App Store"
        case .development: return "Development certificate, not for distribution"
        case .untrustedCertificate: return "Certificate not issued by Apple"
        case .adHoc: return "Self-signed, no verified developer"
        case .unsigned: return "Unsigned"
        case .invalid: return "Code has been changed since it was signed"
        case .unknown: return "Couldn't be checked, the file may be gone"
        }
    }
}

public struct SignerInfo: Equatable, Sendable {
    public var status: SignerStatus
    /// e.g. "Spotify" from "Developer ID Application: Spotify (2FNC3A47ZF)". Only set when
    /// Apple's chain vouches for the certificate, so it can't be a homemade one's made-up name.
    public var organisation: String?
    public var teamID: String?
    /// Hash of this exact build of the code.
    public var codeHash: String?
    /// A verified signature carrying Apple's restricted VPN entitlement. Only Apple can grant
    /// that, so unlike an Info.plist entry an app can't simply declare it.
    public var isPacketTunnel: Bool

    public init(status: SignerStatus, organisation: String? = nil, teamID: String? = nil, codeHash: String? = nil, isPacketTunnel: Bool = false) {
        self.status = status
        self.organisation = organisation
        self.teamID = teamID
        self.codeHash = codeHash
        self.isPacketTunnel = isPacketTunnel
    }

    /// What a trust decision is tied to: the developer when Apple vouches for them, so updates
    /// stay trusted, and otherwise this exact build, so any change ends the trust.
    public var trustKey: String? {
        if status == .apple { return "apple" }
        if status.isVerified, let teamID { return "team:\(teamID)" }
        guard status != .invalid, let codeHash else { return nil }
        return "code:\(codeHash)"
    }
}

public enum CodeSigning {
    // Apple's own requirement language, evaluated by the Security framework. These read the
    // certificate chain itself, so a homemade certificate can't pass by having a convincing name.
    private static let appleRequirement = "anchor apple"
    private static let developerIDRequirement =
        "anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists"
    private static let appStoreRequirement =
        "anchor apple generic and certificate leaf[field.1.2.840.113635.100.6.1.9] exists"
    private static let appleIssuedRequirement = "anchor apple generic"

    /// Checks who signed a bundle or binary, and that its code still matches the signature.
    /// That means hashing the whole bundle, so call this off the main thread. Network access is
    /// disabled because a revocation check would make macOS contact Apple on our behalf,
    /// revealing which apps this Mac runs.
    public static func inspect(path: String) -> SignerInfo {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &code) == errSecSuccess, let code else {
            return SignerInfo(status: .unknown)
        }
        var cfInfo: CFDictionary?
        let infoFlags = SecCSFlags(rawValue: kSecCSSigningInformation | kSecCSRequirementInformation)
        guard SecCodeCopySigningInformation(code, infoFlags, &cfInfo) == errSecSuccess, let info = cfInfo as? [String: Any] else {
            return SignerInfo(status: .unknown)
        }
        guard info[kSecCodeInfoIdentifier as String] != nil else { return SignerInfo(status: .unsigned) }

        let noNetwork: UInt32 = 1 << 29  // kSecCSNoNetworkAccess
        let checkNested: UInt32 = 1 << 3  // kSecCSCheckNestedCode, so helper apps are covered too
        let basicOnly: UInt32 = 1 << 1  // kSecCSBasicValidateOnly, the hashing was already done
        let hash = (info[kSecCodeInfoUnique as String] as? Data)?.map { String(format: "%02x", $0) }.joined()

        if SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: checkNested | noNetwork), nil) != errSecSuccess {
            return SignerInfo(status: .invalid, codeHash: hash)
        }

        func meets(_ text: String) -> Bool {
            var requirement: SecRequirement?
            guard SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess else { return false }
            return SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: basicOnly | noNetwork), requirement) == errSecSuccess
        }

        let certs = info[kSecCodeInfoCertificates as String] as? [SecCertificate] ?? []
        let status: SignerStatus
        if certs.isEmpty {
            status = .adHoc
        } else if meets(appleRequirement) {
            status = .apple
        } else if meets(developerIDRequirement) {
            status = .developerID
        } else if meets(appStoreRequirement) {
            status = .appStore
        } else if meets(appleIssuedRequirement) {
            status = .development
        } else {
            status = .untrustedCertificate
        }

        var organisation: String?
        if status == .apple {
            organisation = "Apple"
        } else if status.isVerified || status == .development, let leaf = certs.first {
            organisation = organisationName(fromCertificateSummary: SecCertificateCopySubjectSummary(leaf) as String? ?? "")
        }
        let entitlements = info[kSecCodeInfoEntitlementsDict as String] as? [String: Any]
        return SignerInfo(
            status: status, organisation: organisation, teamID: info[kSecCodeInfoTeamIdentifier as String] as? String,
            codeHash: hash, isPacketTunnel: status.isVerified && grantsPacketTunnel(entitlements))
    }

    public static func grantsPacketTunnel(_ entitlements: [String: Any]?) -> Bool {
        guard let granted = entitlements?["com.apple.developer.networking.networkextension"] as? [String] else { return false }
        return granted.contains { $0.hasPrefix("packet-tunnel-provider") }
    }

    /// "Developer ID Application: Spotify (2FNC3A47ZF)" becomes "Spotify".
    public static func organisationName(fromCertificateSummary s: String) -> String {
        var org = s
        if let colon = s.firstIndex(of: ":") { org = String(s[s.index(after: colon)...]).trimmingCharacters(in: .whitespaces) }
        if let paren = org.range(of: " (", options: .backwards) { org = String(org[..<paren.lowerBound]) }
        return Sanitize.displayText(org)
    }
}
