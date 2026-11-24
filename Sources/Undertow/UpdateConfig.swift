import Foundation

/// The only file to edit when adding the updater to an app. Everything else is copied as is.
enum UpdateConfig {
    /// "owner/repo" on GitHub. The repo must be public: GitHub won't share a private repo's
    /// releases without a login, so the check would always say nothing is published.
    static let repo = "absolute-cinema-jpg/undertow"

    /// The app's name, as people see it ("Bin Watch").
    static let appName = "Undertow"

    /// A quiet credit after the version in Settings' Updates box, in the caption grey:
    /// "Undertow 1.1.0 – made by Alex Stuart". nil leaves just the name and version.
    static let credit: String? = "made by Alex Stuart"

    /// Release zips are named "\(assetPrefix)\(version).zip", e.g. "Bin-Watch-1.7.zip".
    static let assetPrefix = "Undertow-"

    /// Used for the log subsystem and the saved-settings keys. Usually the bundle identifier.
    static let logSubsystem = Bundle.main.bundleIdentifier ?? "app"

    /// How often to check automatically (when automatic checks are on).
    static let checkInterval: TimeInterval = 24 * 3600

    /// Wait this long after launch before the first automatic check, so it doesn't compete
    /// with the app starting up.
    static let firstCheckDelay: TimeInterval = 15
}
