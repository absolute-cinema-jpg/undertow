import AppKit
import OSLog
import SwiftUI

/// Opens web pages in the browser. Tests set the hook to see what would open.
enum BugReportLinks {
    static var testHook: ((URL) -> Void)?
    static func open(_ url: URL) {
        if let testHook { testHook(url) } else { NSWorkspace.shared.open(url) }
    }
}

// MARK: - Technical details

/// What goes in a report's "Technical details": the app and macOS versions, the processor,
/// the app's own lines (BugReportConfig.appDetails) and recent log events, with anything that
/// looks like a name, path or email address taken out.
enum BugReportDiagnostics {
    static func collect() -> String {
        let info = Bundle.main.infoDictionary ?? [:]
        let os = ProcessInfo.processInfo.operatingSystemVersion
        var lines = [
            "\(BugReportConfig.appName) \(info["CFBundleShortVersionString"] as? String ?? "?") (build \(info["CFBundleVersion"] as? String ?? "?"))",
            "macOS \(os.majorVersion).\(os.minorVersion).\(os.patchVersion) · \(processor)",
        ]
        lines += BugReportConfig.appDetails().map(BugReport.redact)
        let events = recentEvents()
        if !events.isEmpty {
            lines.append("")
            lines.append(BugReport.eventsHeading)
            lines += events
        }
        return lines.joined(separator: "\n")
    }

    static var processor: String {
        var arm = 0, translated = 0
        var size = MemoryLayout<Int>.size
        sysctlbyname("hw.optional.arm64", &arm, &size, nil, 0)
        size = MemoryLayout<Int>.size
        sysctlbyname("sysctl.proc_translated", &translated, &size, nil, 0)
        return arm == 1 ? (translated == 1 ? "Apple Silicon (running as Intel)" : "Apple Silicon") : "Intel"
    }

    /// The kind of storage a path is on, never its name: "SMB server", "Mac disk (apfs)"…
    /// Useful in appDetails for apps that work with files on servers.
    static func storageKind(_ path: String) -> String {
        var fs = statfs()
        guard statfs(path, &fs) == 0 else { return "not mounted" }
        let type = withUnsafeBytes(of: fs.f_fstypename) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        switch type {
        case "smbfs": return "SMB server"
        case "afpfs": return "AFP server"
        case "nfs": return "NFS server"
        case "webdav": return "WebDAV server"
        case "apfs", "hfs": return fs.f_flags & UInt32(MNT_LOCAL) != 0 ? "Mac disk (\(type))" : type
        default: return type.isEmpty ? "unknown storage" : type
        }
    }

    /// The app's own log messages from the chosen categories since it started (OSLogStore only
    /// sees the current process), redacted, newest last.
    static func recentEvents(limit: Int = 25) -> [String] {
        let categories = BugReportConfig.logCategories
        guard !categories.isEmpty, let store = try? OSLogStore(scope: .currentProcessIdentifier) else { return [] }
        let since = store.position(date: Date().addingTimeInterval(-24 * 3600))
        let predicate = NSPredicate(format: "subsystem == %@", BugReportConfig.logSubsystem)
        guard let entries = try? store.getEntries(at: since, matching: predicate) else { return [] }
        let time = DateFormatter()
        time.dateFormat = "HH:mm:ss"
        let lines = entries.compactMap { $0 as? OSLogEntryLog }
            .filter { categories.contains($0.category) }
            .map { "\(time.string(from: $0.date)) [\($0.category)] \(BugReport.redact($0.composedMessage))" }
        return Array(lines.suffix(limit))
    }
}

// MARK: - The sheet

/// Send Feedback: one form for bug reports and feature requests.
/// Present with `.sheet(isPresented:) { BugReportSheet() }`.
struct BugReportSheet: View {
    /// Which kind the form opens on. Tests and self-checks can set it to picture both kinds.
    static var startKind = BugReport.Kind.bug

    @Environment(\.dismiss) private var dismiss
    @State private var report = BugReport(kind: BugReportSheet.startKind)
    @State private var includeDetails = BugReportSheet.startKind == .bug
    @State private var details = ""
    @State private var showDetails = false
    @State private var copied = false

    private var isBug: Bool { report.kind == .bug }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: isBug ? "ladybug.fill" : "lightbulb.fill")
                    .font(.system(size: 18, weight: .semibold)).foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background((isBug ? Color.red : Color.orange).gradient,
                                in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Send Feedback").font(.title3.weight(.semibold))
                    Text("Opens GitHub with it filled in, for you to check and post.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }

            Picker("", selection: $report.kind) {
                Text("Report a Bug").tag(BugReport.Kind.bug)
                Text("Suggest a Feature").tag(BugReport.Kind.feature)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            field("Summary") {
                TextField("", text: $report.title,
                          prompt: Text(isBug ? "A short description of the problem" : "A short description of your idea"))
                    .textFieldStyle(.roundedBorder)
            }
            if isBug {
                field("What happened?") { editor($report.whatHappened, height: 80) }
                field("Steps to make it happen (optional)") { editor($report.steps, height: 56) }
            } else {
                field("What would you like \(BugReportConfig.appName) to do?") { editor($report.wish, height: 80) }
                field("How would it help your work? (optional)") { editor($report.benefit, height: 56) }
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Toggle("Include technical details", isOn: $includeDetails)
                    Spacer()
                    Button(showDetails ? "Hide" : "Show What's Included") { showDetails.toggle() }
                        .buttonStyle(.link).disabled(!includeDetails)
                }
                if showDetails && includeDetails {
                    ScrollView {
                        Text(details).font(.system(size: 11, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                    }
                    .frame(height: 130)
                    .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
                }
                Text("Your version of \(BugReportConfig.appName) and macOS, its settings, counts of apps and alerts, and recent update events. No app names, addresses or websites.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Label {
                Text("Everything on GitHub is public, so please don't include private names or details. You'll need a free GitHub account to post.")
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "eye").foregroundStyle(.orange)
            }
            .font(.caption)

            HStack {
                Button(copied ? "Copied" : "Copy Text") { copy() }
                    .disabled(!report.isReady)
                    .help("Copies all of it, to paste into GitHub or an email")
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Continue on GitHub…") { send() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(!report.isReady)
            }
        }
        .padding(20)
        .frame(width: 540)
        .onAppear {
            details = BugReportDiagnostics.collect()
            report.details = details
        }
        .onChange(of: includeDetails) { report.details = $0 ? details : nil }
        // Details help with a bug; an idea rarely needs them (they can still be ticked).
        .onChange(of: report.kind) { kind in
            includeDetails = kind == .bug
            copied = false
        }
    }

    private func field<Content: View>(_ label: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label).font(.callout.weight(.medium))
            content()
        }
    }

    private func editor(_ text: Binding<String>, height: CGFloat) -> some View {
        TextEditor(text: text)
            .font(.body)
            .scrollContentBackground(.hidden)
            .padding(4)
            .frame(height: height)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.primary.opacity(0.15)))
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(report.plainText, forType: .string)
        copied = true
    }

    private func send() {
        BugReportLinks.open(report.issueLink)
        dismiss()
    }
}

// MARK: - Settings section and menu

/// Put inside a grouped `Form` in Settings. `report` should present BugReportSheet.
struct BugReportSection: View {
    var report: () -> Void

    var body: some View {
        Section("Feedback") {
            HStack(spacing: 10) {
                Image(systemName: "bubble.left.and.exclamationmark.bubble.right.fill")
                    .font(.title2).foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Found a bug, or have an idea?").font(.body.weight(.medium))
                    Text("Send it to \(BugReportConfig.appName)'s page on GitHub.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Open Requests") { BugReportLinks.open(BugReport.issuesPage) }
                    .help("Bugs and ideas people have already sent")
                Button("Send Feedback…", action: report)
            }
        }
    }
}

/// Replaces the Help menu:  .commands { BugReportCommands(report: { … }) }
struct BugReportCommands: Commands {
    var report: () -> Void

    var body: some Commands {
        CommandGroup(replacing: .help) {
            Button("Send Feedback…", action: report)
            Button("Open Requests") { BugReportLinks.open(BugReport.issuesPage) }
            Button("\(BugReportConfig.appName) on GitHub") {
                BugReportLinks.open(URL(string: "https://github.com/\(BugReportConfig.repo)")!)
            }
        }
    }
}
