import AppKit
import SwiftUI

/// Opens web pages in the browser. Tests set the hook to see what would open.
enum UpdateLinks {
    static var testHook: ((URL) -> Void)?
    static func open(_ url: URL) {
        if let testHook { testHook(url) } else { NSWorkspace.shared.open(url) }
    }
}

// MARK: - Settings section

/// Put inside a grouped `Form` in Settings: version, status, the Update button, what's new,
/// and the "Check for updates automatically" switch.
struct UpdatesSection: View {
    @ObservedObject private var updater = Updater.shared

    var body: some View {
        Section("Updates") {
            HStack(spacing: 12) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable().frame(width: 36, height: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(UpdateConfig.appName) \(updater.currentVersion)").font(.body.weight(.medium))
                    UpdateStatusLine()
                }
                Spacer()
                UpdateButtons()
            }
            if case .downloading(let fraction) = updater.phase {
                ProgressView(value: fraction).progressViewStyle(.linear)
            }
            if let update = updater.update, updater.phase != .upToDate, !update.notes.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("What's new in \(update.version)").font(.headline)
                    ReleaseNotes(markdown: update.notes)
                    Button("Full release notes on GitHub") { UpdateLinks.open(update.pageURL) }
                        .buttonStyle(.link)
                }
                .padding(.vertical, 4)
            }
            VStack(alignment: .leading, spacing: 3) {
                Toggle("Check for updates automatically", isOn: $updater.automaticChecks)
                Text("\(UpdateConfig.appName) asks GitHub whether there's a newer version. Nothing is installed until you click Update.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct UpdateStatusLine: View {
    @ObservedObject private var updater = Updater.shared

    var body: some View {
        Group {
            switch updater.phase {
            case .failed:
                Label(updater.statusText, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            case .upToDate:
                Label(upToDateText, systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            case .available:
                Label(updater.statusText, systemImage: "arrow.down.circle.fill").foregroundStyle(Color.accentColor)
            default:
                Text(updater.justUpdated && updater.phase == .idle ? "Updated — you're on the latest version" : updater.statusText)
                    .foregroundStyle(.secondary)
            }
        }
        .font(.caption)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var upToDateText: String {
        guard let checked = updater.lastChecked else { return "Up to date" }
        return "Up to date · checked \(checked.formatted(.relative(presentation: .named)))"
    }
}

struct UpdateButtons: View {
    @ObservedObject private var updater = Updater.shared

    var body: some View {
        HStack(spacing: 8) {
            switch updater.phase {
            case .checking, .downloading, .installing, .restarting:
                ProgressView().controlSize(.small)
            case .available:
                Button("Update to \(updater.update?.version ?? "")") { updater.installAsking() }
                    .buttonStyle(.borderedProminent)
            case .failed:
                if updater.installFailed, updater.update != nil {
                    Button("Download from GitHub") { UpdateLinks.open(updater.update?.pageURL ?? UpdateLogic.releasesPage) }
                    Button("Try Again") { updater.installAsking() }.buttonStyle(.borderedProminent)
                } else {
                    Button("Check Again") { updater.check() }
                }
            default:
                Button("Check Now") { updater.check() }
            }
        }
    }
}

/// Release notes as GitHub writes them: "**bold**", links and "- " bullets, headings dropped.
struct ReleaseNotes: View {
    let markdown: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                if line.hasPrefix("- ") || line.hasPrefix("* ") {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("•").foregroundStyle(.secondary)
                        inline(String(line.dropFirst(2)))
                    }
                    .padding(.leading, 6)
                } else {
                    inline(line)
                }
            }
        }
        .font(.callout)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var lines: [String] {
        markdown.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
    }

    private func inline(_ text: String) -> Text {
        let attributed = (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
        return Text(attributed)
    }
}

// MARK: - Banner

/// A small card for a sidebar, toolbar area or the top of a window. It's invisible unless
/// there's an update, one is installing, an install failed, or the app was just updated.
/// `showDetails` is called by "Details…" after a failed install (e.g. open Settings).
struct UpdateBanner: View {
    var showDetails: () -> Void = {}
    @ObservedObject private var updater = Updater.shared

    var body: some View {
        if let content {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(content.heading)
                        .font(.system(size: 10, weight: .semibold)).tracking(0.6)
                        .foregroundStyle(content.tint)
                    Spacer()
                    if updater.justUpdated && updater.update == nil {
                        Button { updater.justUpdated = false } label: {
                            Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Hide")
                    }
                }
                HStack(spacing: 8) {
                    Image(systemName: content.symbol).foregroundStyle(content.tint)
                    Text(content.title).font(.callout.weight(.medium)).lineLimit(2)
                    Spacer(minLength: 0)
                }
                if case .downloading(let fraction) = updater.phase {
                    ProgressView(value: fraction).controlSize(.small)
                }
                buttons
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(content.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }

    @ViewBuilder
    private var buttons: some View {
        switch updater.phase {
        case .available:
            Button("Update Now") { updater.installAsking() }
                .buttonStyle(.borderedProminent).controlSize(.small)
        case .failed where updater.installFailed:
            Button("Details…", action: showDetails).controlSize(.small)
        case .idle, .upToDate:
            if updater.justUpdated {
                Button("What's New") { UpdateLinks.open(UpdateLogic.releasePage(for: updater.currentVersion)) }
                    .controlSize(.small)
            }
        default:
            EmptyView()
        }
    }

    private struct Content { let heading: String; let title: String; let symbol: String; let tint: Color }

    private var content: Content? {
        let version = updater.update?.version ?? ""
        let name = UpdateConfig.appName
        switch updater.phase {
        case .available:
            return Content(heading: "UPDATE AVAILABLE", title: "\(name) \(version)", symbol: "arrow.down.circle.fill", tint: .accentColor)
        case .downloading:
            return Content(heading: "UPDATING", title: "Downloading \(version)…", symbol: "arrow.down.circle", tint: .accentColor)
        case .installing, .restarting:
            return Content(heading: "UPDATING", title: updater.statusText, symbol: "arrow.triangle.2.circlepath", tint: .accentColor)
        case .failed where updater.installFailed:
            return Content(heading: "UPDATE", title: "Couldn't install \(version)", symbol: "exclamationmark.triangle.fill", tint: .orange)
        case .idle, .upToDate:
            return updater.justUpdated
                ? Content(heading: "UPDATED", title: "Now on \(name) \(updater.currentVersion)", symbol: "checkmark.circle.fill", tint: .green)
                : nil
        default:
            return nil
        }
    }
}

// MARK: - Menu

/// Adds "Check for Updates…" under About in the app menu:
///     .commands { UpdateCommands(showSettings: { … }) }
struct UpdateCommands: Commands {
    var showSettings: () -> Void = {}

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button("Check for Updates…") {
                showSettings()
                Updater.shared.check()
            }
        }
    }
}
