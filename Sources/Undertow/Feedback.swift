import AppKit
import SwiftUI
import UndertowCore

/// Whether the Send Feedback sheet is showing. Shared so the right-click menu can open it.
final class FeedbackNav: ObservableObject {
    static let shared = FeedbackNav()
    @Published var showSheet = false
}

extension AppStore {
    /// Undertow's lines for a report's technical details: settings, on/off states and counts.
    ///
    /// Undertow knows which apps you use and where they connect, and issues are public, so
    /// none of that goes in: no app names, addresses, hostnames, network or VPN names, and
    /// not the latency check address, which is typed by the person.
    var feedbackDetails: [String] {
        let p = prefs
        let d = detail
        let shown = p.sectionOrder.filter { !p.hiddenSections.contains($0) }.map(\.rawValue)
        let customBands = p.graphBandLimits != GraphScale.defaultLimits
        let watch = WatchKind.allCases.filter { p.watchEnabled.contains($0) }.map(\.rawValue)
        var alertCounts: [String: Int] = [:]
        for event in events { alertCounts[event.kind.rawValue, default: 0] += 1 }
        let alerts = alertCounts.isEmpty ? "none" : alertCounts.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", ")
        let owners: String
        if let date = monitor.owners.lastUpdated, monitor.owners.isAvailable {
            let days = max(0, Int(Date().timeIntervalSince(date) / 86400))
            owners = days == 0 ? "downloaded today" : "downloaded \(days) day\(days == 1 ? "" : "s") ago"
        } else {
            owners = "not downloaded"
        }
        let learning = d.learningRemaining > 0 ? "\(Int((d.learningRemaining / 3600).rounded(.up)))h left" : "done"

        return [
            "Menu bar: \(p.menuContent.rawValue), \(p.menuLayout.rawValue), \(p.units.rawValue), refresh every \(Int(p.interval))s, measuring \(p.measure.rawValue)",
            "Panel sections shown: \(shown.joined(separator: ", ")); opens on \(p.rememberRange ? "last range" : p.defaultRange.rawValue)",
            "Graph: \(p.graphScale.rawValue)\(p.graphScale == .bands ? (customBands ? " (custom)" : " (default)") : ""), covers \(p.graphSpan)s",
            "History: \(p.recordHistory ? "on, \(p.retentionDays) days" : "off"); learning period \(learning)",
            "Owner table: \(owners)",
            "Hostname lookups: \(p.reverseDNS ? "on" : "off"); latency checks: \(p.healthProbes ? "on" : "off")",
            "Watch: \(watch.count == WatchKind.allCases.count ? "all" : watch.joined(separator: ", ")); alerts on record: \(alerts)",
            "Now: \(d.apps.count) apps, \(d.destinations.count) destinations; VPN \(d.vpnName == nil ? "not connected" : "connected"); health \(String(describing: d.health.verdict.level))",
            "Open at login: \(LoginItem.statusDescription); automatic update checks: \(Updater.shared.automaticChecks ? "on" : "off")",
        ]
    }
}

/// Settings > Panel: the command that opens and closes the panel, for binding to a key.
struct ToggleCommandSection: View {
    @State private var copied = false

    /// The copy that's running, so it's right even if Undertow isn't in Applications.
    static var command: String {
        let path = Bundle.main.executablePath ?? "/Applications/Undertow.app/Contents/MacOS/Undertow"
        let quoted = path.contains(" ") ? "'\(path.replacingOccurrences(of: "'", with: "'\\''"))'" : path
        return "\(quoted) --toggle-panel"
    }

    var body: some View {
        Section {
            HStack(alignment: .center, spacing: 10) {
                Text(Self.command)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button(copied ? "Copied" : "Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(Self.command, forType: .string)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copied = false }
                }
            }
        } header: {
            Text("Shell command")
        } footer: {
            FooterText("This command opens the panel, or closes it if it's open, and starts Undertow if it isn't running. To run it with a key of your choice, bind it in Karabiner-Elements, Keyboard Maestro or Automator. In Automator, make a Quick Action that runs it as a shell script, then give it a shortcut in System Settings > Keyboard > Keyboard Shortcuts > Services.")
        }
    }
}
