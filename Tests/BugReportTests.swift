// Tests for building feedback links (bug reports and feature requests). Runs on its own, silently:
//   swiftc -parse-as-library <app>/BugReportConfig.swift <app>/BugReport.swift Tests/BugReportTests.swift \
//          -o /tmp/bug-report-tests && /tmp/bug-report-tests
// Uses the app's real BugReportConfig.
import Foundation

private var failures = 0
private func check(_ ok: Bool, _ message: String) {
    print(ok ? "  ✓ \(message)" : "  ✗ \(message)")
    if !ok { failures += 1 }
}

@main enum BugReportTests {
    static func main() {
        print("Bug reports")
        var report = BugReport()
        check(!report.isReady, "an empty report can't be sent")
        report.title = "Saving & syncing + more = broken #2 🐞"
        report.whatHappened = "Nothing saved.\nTried twice?"
        report.details = "\(BugReportConfig.appName) 1.0 (build 1)\nmacOS 13.7.2 · Apple Silicon"
        check(report.isReady, "a summary and what happened are enough")

        let link = report.issueLink
        let items = URLComponents(url: link, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let value = { (name: String) in items.first { $0.name == name }?.value }
        check(link.absoluteString.hasPrefix("https://github.com/\(BugReportConfig.repo)/issues/new?"),
              "it opens \(BugReportConfig.repo)'s new-issue page")
        check(value("title") == "Bug: " + report.title, "the title starts \"Bug: \" and survives &, +, =, # and emoji: \(value("title") ?? "nil")")
        check(BugReportConfig.bugLabels.isEmpty ? value("labels") == nil : value("labels") == BugReportConfig.bugLabels.joined(separator: ","),
              "the bug labels are asked for: \(value("labels") ?? "none")")
        check(value("body")?.contains("### What happened\n\nNothing saved.\nTried twice?") == true
              && value("body")?.contains("<summary>Technical details</summary>") == true
              && value("body")?.contains("Steps to reproduce") == false,
              "the body has the description and details, and skips empty parts")
        check(value("body")?.hasSuffix("<!-- feedback: bug -->\n") == true, "the body ends with the hidden bug marker")
        check(report.plainText.hasPrefix("# Bug: \(report.title)\n\n### What happened"), "Copy Text has everything as text")
        var typed = report
        typed.title = "bug: it crashed"
        check(typed.fullTitle == "bug: it crashed", "a title that already starts with \"Bug:\" isn't given it twice")

        print("Feature requests")
        var idea = BugReport(kind: .feature)
        idea.title = "Export to PDF"
        idea.whatHappened = "left over from a bug"
        check(!idea.isReady, "a feature request needs what you'd like, not what happened")
        idea.wish = "A PDF export of the clip list"
        check(idea.isReady, "a summary and what you'd like are enough")
        let ideaItems = URLComponents(url: idea.issueLink, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let ideaValue = { (name: String) in ideaItems.first { $0.name == name }?.value }
        check(ideaValue("title") == "Idea: Export to PDF", "the title starts \"Idea: \": \(ideaValue("title") ?? "nil")")
        check(BugReportConfig.featureLabels.isEmpty ? ideaValue("labels") == nil
              : ideaValue("labels") == BugReportConfig.featureLabels.joined(separator: ","),
              "the feature labels are asked for: \(ideaValue("labels") ?? "none")")
        let ideaBody = ideaValue("body") ?? ""
        check(ideaBody.hasPrefix("### What I'd like\n\nA PDF export of the clip list") && !ideaBody.contains("How it would help")
              && !ideaBody.contains("What happened") && !ideaBody.contains("Technical details")
              && ideaBody.hasSuffix("<!-- feedback: feature -->\n"),
              "the body has what you'd like, skips empty parts, has no bug fields and ends with the feature marker")
        idea.benefit = "Editors could send it to producers"
        check(idea.body.contains("### How it would help\n\nEditors could send it to producers"), "how it would help is included when given")
        idea.wish = String(repeating: "Please add more export options. ", count: 600)
        check(idea.issueLink.absoluteString.count <= BugReport.maxLinkLength, "a very long idea is shortened in the link too")

        report.details = "\(BugReportConfig.appName) 1.0\nmacOS 13\n\n" + BugReport.eventsHeading + "\n"
            + (1...400).map { "12:00:\($0) [net] connected, event number \($0)" }.joined(separator: "\n")
        let long = report.issueLink
        let longBody = URLComponents(url: long, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "body" }?.value ?? ""
        check(long.absoluteString.count <= BugReport.maxLinkLength && longBody.contains("macOS 13")
              && longBody.contains("event number 400") && !longBody.contains("event number 1\n"),
              "long technical details are trimmed (oldest events first) to fit in a link")
        report.details = nil
        report.whatHappened = String(repeating: "Something went wrong again. ", count: 600)
        check(report.issueLink.absoluteString.count <= BugReport.maxLinkLength && report.body.count > BugReport.maxLinkLength,
              "a very long description is shortened in the link (Copy Report keeps all of it)")

        let redacted = BugReport.redact("couldn't save “Wedding Speech.docx” for jo@example.com: /Users/jo/My Docs/Wedding Speech.docx")
        check(!redacted.contains("Wedding") && !redacted.contains("jo@") && !redacted.contains("My Docs"),
              "names, emails and paths are taken out of log lines: \(redacted)")
        check(BugReport.redact("sync status: connected (3 of 4)") == "sync status: connected (3 of 4)", "ordinary lines are left alone")

        print(failures == 0 ? "\nAll bug report tests passed." : "\n\(failures) bug report tests FAILED")
        exit(failures == 0 ? 0 : 1)
    }
}
