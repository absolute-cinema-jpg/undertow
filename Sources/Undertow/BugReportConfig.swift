import Foundation

/// The only file to edit when adding feedback (bug reports and feature requests) to an app.
/// Everything else is copied as is.
enum BugReportConfig {
    /// "owner/repo" on GitHub. People can only open issues on a public repo (or one they have
    /// access to), and they need a free GitHub account to post.
    static let repo = "absolute-cinema-jpg/undertow"

    /// The app's name, as people see it.
    static let appName = "Undertow"

    /// Labels for each kind. The link asks for them, but GitHub only applies them for people
    /// allowed to label issues and quietly ignores them otherwise; the label-feedback workflow
    /// in the repo (.github/workflows) labels everyone else's. Use labels the repo has.
    static let bugLabels = ["bug"]
    static let featureLabels = ["enhancement"]

    /// The app's log subsystem (os.Logger), for the "recent events" part of the technical
    /// details. Usually the bundle identifier.
    static let logSubsystem = Bundle.main.bundleIdentifier ?? "app"

    /// Which log categories to include. Pick ones whose messages are about the app's own
    /// state (connections, updates, errors), never ones that log file names or user content.
    /// Empty = leave recent events out.
    static let logCategories: [String] = ["update"]

    /// App-specific lines for the technical details: how it's set up and how it's doing.
    /// Counts, on/off states and kinds of things only. Never names of documents, files,
    /// folders, people, computers, accounts or anything the person typed. Set it at launch:
    ///     BugReportConfig.appDetails = { ["Documents open: \(docs.count)", "Sync: on"] }
    static var appDetails: () -> [String] = { [] }
}
