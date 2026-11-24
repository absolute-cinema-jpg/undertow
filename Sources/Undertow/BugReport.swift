import Foundation

/// Feedback (a bug report or a feature request), turned into a link to GitHub's "New issue"
/// page with everything filled in. Nothing is sent from the app: the person checks it on
/// GitHub and posts it there.
struct BugReport {
    enum Kind: String, CaseIterable {
        case bug, feature
        /// Put before the title on GitHub, so the two kinds are easy to tell apart.
        var titlePrefix: String { self == .bug ? "Bug: " : "Idea: " }
        var labels: [String] { self == .bug ? BugReportConfig.bugLabels : BugReportConfig.featureLabels }
        /// A hidden line at the end of the body. The repo's label-feedback workflow reads it
        /// to label the issue (GitHub ignores `labels=` from people who can't label issues).
        var marker: String { "<!-- feedback: \(rawValue) -->" }
    }

    var kind = Kind.bug
    var title = ""
    // A bug
    var whatHappened = ""
    var steps = ""
    var expected = ""
    // A feature request
    var wish = ""
    var benefit = ""
    /// Technical details, or nil to leave them out.
    var details: String?

    static var newIssuePage: String { "https://github.com/\(BugReportConfig.repo)/issues/new" }
    static var issuesPage: URL { URL(string: "https://github.com/\(BugReportConfig.repo)/issues")! }
    /// Browsers and GitHub start refusing links much longer than this.
    static let maxLinkLength = 7500
    /// The heading above the log lines in the technical details. They're trimmed first
    /// (oldest first) when the link is too long.
    static let eventsHeading = "Recent events (this session):"

    var isReady: Bool {
        !title.trimmed.isEmpty && !(kind == .bug ? whatHappened : wish).trimmed.isEmpty
    }

    /// The title as posted: "Bug: …" or "Idea: …" (unless the person already wrote it).
    var fullTitle: String {
        let t = title.trimmed
        return t.lowercased().hasPrefix(kind.titlePrefix.lowercased()) ? t : kind.titlePrefix + t
    }

    var body: String { body(details: details) }

    private func body(details: String?) -> String {
        var parts: [String]
        switch kind {
        case .bug:
            parts = ["### What happened\n\n\(whatHappened.trimmed)"]
            if !steps.trimmed.isEmpty { parts.append("### Steps to reproduce\n\n\(steps.trimmed)") }
            if !expected.trimmed.isEmpty { parts.append("### What I expected\n\n\(expected.trimmed)") }
        case .feature:
            parts = ["### What I'd like\n\n\(wish.trimmed)"]
            if !benefit.trimmed.isEmpty { parts.append("### How it would help\n\n\(benefit.trimmed)") }
        }
        if let details, !details.trimmed.isEmpty {
            parts.append("<details>\n<summary>Technical details</summary>\n\n```\n\(details.trimmed)\n```\n</details>")
        }
        parts.append(kind.marker)
        return parts.joined(separator: "\n\n") + "\n"
    }

    /// Everything as text, for "Copy Report".
    var plainText: String { "# \(fullTitle)\n\n\(body)" }

    /// The link to open. If it would be too long, the technical details lose their oldest
    /// event lines first, then the longest description is shortened ("Copy Report" keeps it all).
    var issueLink: URL {
        var detailLines = details?.components(separatedBy: "\n") ?? []
        var report = self
        while true {
            let link = Self.link(title: report.fullTitle, labels: kind.labels,
                                 body: report.body(details: details == nil ? nil : detailLines.joined(separator: "\n")))
            if link.absoluteString.count <= Self.maxLinkLength { return link }
            if detailLines.count > 8 {
                // Keep the summary at the top; drop the oldest events below the heading.
                let firstEvent = (detailLines.firstIndex(of: Self.eventsHeading) ?? detailLines.count - 1) + 1
                if firstEvent < detailLines.count - 1 { detailLines.remove(at: firstEvent); continue }
                detailLines.removeLast()
                continue
            }
            let fields = kind == .bug ? [\BugReport.whatHappened, \BugReport.steps, \BugReport.expected]
                                      : [\BugReport.wish, \BugReport.benefit]
            let longest = fields
                .max { report[keyPath: $0].count < report[keyPath: $1].count }!
            let text = report[keyPath: longest]
            if text.count < 40 { return link }
            report[keyPath: longest] = String(text.prefix(text.count * 3 / 4)) + " … (shortened)"
        }
    }

    static func link(title: String, labels: [String] = [], body: String) -> URL {
        var items = [("title", title), ("body", body)]
        if !labels.isEmpty { items.append(("labels", labels.joined(separator: ","))) }
        let query = items.map { "\($0.0)=\(encode($0.1))" }.joined(separator: "&")
        return URL(string: newIssuePage + "?" + query)!
    }

    /// Percent-encodes everything except letters, digits and -._~, so &, =, + and # survive.
    /// (URLComponents leaves & and = alone inside values, and GitHub reads + as a space.)
    static func encode(_ s: String) -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
    }

    /// Takes out anything that could name a document, person or folder: quoted names, and
    /// everything from the start of a file path to the end of the line (paths can contain spaces).
    static func redact(_ line: String) -> String {
        var s = line
        for pattern in [#"“[^”]*”"#, #""[^"]*""#, #"'[^']*'"#, #"‘[^’]*’"#] {
            s = s.replacingOccurrences(of: pattern, with: "“…”", options: .regularExpression)
        }
        s = s.replacingOccurrences(of: #"(file://)?/(Volumes|Users|private|Applications|Library|System|var|tmp|Network|opt|home)\b.*"#,
                                   with: "‹path›", options: .regularExpression)
        s = s.replacingOccurrences(of: #"~/.*"#, with: "‹path›", options: .regularExpression)
        s = s.replacingOccurrences(of: #"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#, with: "‹email›", options: .regularExpression)
        return s
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
