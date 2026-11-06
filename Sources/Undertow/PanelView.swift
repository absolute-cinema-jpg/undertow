import AppKit
import SwiftUI
import UndertowCore

private struct ContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

struct PanelView: View {
    @EnvironmentObject var store: AppStore
    let openSettings: () -> Void
    @State private var contentHeight: CGFloat = 260

    private var theme: Theme { Theme(prefs: store.prefs) }
    private var maxHeight: CGFloat {
        let screen = NSScreen.main?.visibleFrame.height ?? 800
        return min(screen - 60, 720)
    }

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch store.route {
                case .home:
                    HeaderView(openSettings: openSettings)
                case .app, .destination:
                    EmptyView()
                }
            }
            ScrollView(.vertical, showsIndicators: false) {
                content
                    .padding(.horizontal, 14)
                    .padding(.bottom, 12)
                    .background(GeometryReader { Color.clear.preference(key: ContentHeightKey.self, value: $0.size.height) })
            }
            .frame(height: min(contentHeight, maxHeight - (store.route == .home ? 96 : 0)))
            .onPreferenceChange(ContentHeightKey.self) { height in
                // Ignore small changes, so the panel doesn't twitch as rows update.
                if abs(height - contentHeight) > 1 { contentHeight = height }
            }
        }
        .frame(width: store.prefs.panelWidth.points)
        .environment(\.theme, theme)
    }

    @ViewBuilder private var content: some View {
        switch store.route {
        case .home:
            HomeSections()
        case .app(let id):
            AppDetailView(appID: id)
        case .destination(let key):
            DestinationDetailView(key: key)
        }
    }
}

private struct ThemeKey: EnvironmentKey {
    static let defaultValue = Theme(prefs: Prefs())
}
extension EnvironmentValues {
    var theme: Theme {
        get { self[ThemeKey.self] }
        set { self[ThemeKey.self] = newValue }
    }
}

// MARK: - Header

struct HeaderView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.theme) var theme
    let openSettings: () -> Void

    var body: some View {
        let value = store.liveHeadline.value(for: store.prefs.measure)
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 16) {
                SpeedReadout(symbol: "arrow.down", value: value.down, tint: theme.download)
                SpeedReadout(symbol: "arrow.up", value: value.up, tint: theme.upload)
                Spacer(minLength: 0)
                Button(action: openSettings) {
                    Image(systemName: "slider.horizontal.3").font(.system(size: 13))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Settings")
            }
            HStack(spacing: 6) {
                ConnectionCaption()
                Spacer(minLength: 0)
                RangePicker()
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 10)
    }
}

struct SpeedReadout: View {
    @Environment(\.theme) var theme
    let symbol: String
    let value: Double
    let tint: Color

    var body: some View {
        let parts = theme.rate(value).split(separator: " ", maxSplits: 1).map(String.init)
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(tint)
            Text(parts.first ?? "0")
                .font(.system(size: 22, weight: .semibold, design: .rounded).monospacedDigit())
            Text(parts.count > 1 ? parts[1] : "")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .fixedSize()
        .accessibilityElement(children: .combine)
    }
}

struct ConnectionCaption: View {
    @EnvironmentObject var store: AppStore
    var body: some View {
        let d = store.detail
        HStack(spacing: 4) {
            if let vpn = d.vpnName {
                Image(systemName: "lock.fill").font(.system(size: 9))
                Text(vpn)
            } else if let name = d.interfaceName {
                Text(name)
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }
}

struct RangePicker: View {
    @EnvironmentObject var store: AppStore
    var body: some View {
        Menu(store.range.label) {
            ForEach(TimeRange.allCases) { r in
                Button(r.label) { store.setRange(r) }
            }
        }
        .menuStyle(.borderlessButton)
        .controlSize(.small)
        .fixedSize()
        .help("Show live speeds or saved totals")
    }
}

// MARK: - Sections

struct HomeSections: View {
    @EnvironmentObject var store: AppStore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !store.detail.ownerTableAvailable, store.prefs.visibleSections.contains(.destinations) {
                OwnerTablePrompt()
            }
            ForEach(store.prefs.visibleSections) { section in
                switch section {
                case .graph: if store.range == .live { GraphSection() }
                case .health: HealthSection()
                case .breakdown: BreakdownSection()
                case .apps: AppsSection()
                case .destinations: DestinationsSection()
                case .watch: WatchSection()
                }
            }
        }
    }
}

struct SectionTitle<Trailing: View>: View {
    let title: String
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack {
            Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            Spacer()
            trailing().font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }
}

extension SectionTitle where Trailing == EmptyView {
    init(title: String) {
        self.title = title
        trailing = { EmptyView() }
    }
}

// MARK: Graph

struct GraphSection: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.theme) var theme
    @State private var hoverX: CGFloat?

    var body: some View {
        let samples = store.graph
        let peakDown = max(samples.map(\.down).max() ?? 0, 1)
        let peakUp = max(samples.map(\.up).max() ?? 0, 1)
        let span = Double(store.prefs.graphSpan)

        GeometryReader { geo in
            let size = geo.size
            let mid = size.height * 0.62
            ZStack(alignment: .topLeading) {
                Canvas { ctx, _ in
                    let now = samples.last?.date ?? Date()
                    func x(_ s: GraphSample) -> CGFloat {
                        size.width * CGFloat(1 - now.timeIntervalSince(s.date) / span)
                    }
                    func area(_ value: (GraphSample) -> Double, peak: Double, height: CGFloat, sign: CGFloat) -> Path {
                        var p = Path()
                        guard let first = samples.first else { return p }
                        p.move(to: CGPoint(x: x(first), y: mid))
                        for s in samples {
                            p.addLine(to: CGPoint(x: x(s), y: mid - sign * height * CGFloat(value(s) / peak)))
                        }
                        p.addLine(to: CGPoint(x: x(samples[samples.count - 1]), y: mid))
                        p.closeSubpath()
                        return p
                    }
                    ctx.fill(area(\.down, peak: peakDown, height: mid - 4, sign: 1), with: .color(theme.download.opacity(0.75)))
                    ctx.fill(area(\.up, peak: peakUp, height: size.height - mid - 2, sign: -1), with: .color(theme.upload.opacity(0.75)))
                    var base = Path()
                    base.move(to: CGPoint(x: 0, y: mid))
                    base.addLine(to: CGPoint(x: size.width, y: mid))
                    ctx.stroke(base, with: .color(.secondary.opacity(0.3)), lineWidth: 0.5)
                    if let hoverX {
                        var line = Path()
                        line.move(to: CGPoint(x: hoverX, y: 0))
                        line.addLine(to: CGPoint(x: hoverX, y: size.height))
                        ctx.stroke(line, with: .color(.primary.opacity(0.4)), lineWidth: 1)
                    }
                }
                graphCaption(samples: samples, width: size.width, span: span, peakDown: peakDown, peakUp: peakUp)
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let p): hoverX = p.x
                case .ended: hoverX = nil
                }
            }
        }
        .frame(height: 74)
    }

    @ViewBuilder
    private func graphCaption(samples: [GraphSample], width: CGFloat, span: Double, peakDown: Double, peakUp: Double) -> some View {
        let now = samples.last?.date ?? Date()
        VStack(alignment: .trailing, spacing: 0) {
            HStack {
                Spacer()
                if let hoverX, width > 0 {
                    let secondsAgo = (1 - Double(hoverX / width)) * span
                    let target = now.addingTimeInterval(-secondsAgo)
                    let nearest = samples.min { abs($0.date.timeIntervalSince(target)) < abs($1.date.timeIntervalSince(target)) }
                    if let nearest {
                        Text("\(Int(secondsAgo))s ago  ↓\(theme.rate(nearest.down))  ↑\(theme.rate(nearest.up))")
                    }
                } else {
                    Text("peak ↓\(theme.rate(peakDown))  ↑\(theme.rate(peakUp))")
                }
            }
            Spacer()
        }
        .font(.system(size: 9.5).monospacedDigit())
        .foregroundStyle(.secondary)
        .allowsHitTesting(false)
    }
}

// MARK: Health

struct HealthSection: View {
    @EnvironmentObject var store: AppStore

    var body: some View {
        if store.prefs.healthProbes {
            let h = store.detail.health
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .top, spacing: 8) {
                    Circle().fill(color(h.verdict.level)).frame(width: 8, height: 8).padding(.top, 4)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(h.verdict.title).font(.system(size: 12, weight: .semibold))
                        Text(h.verdict.detail)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                HStack(spacing: 12) {
                    if h.routerAddress != nil { LatencyChip(label: "Router", stats: h.router) }
                    LatencyChip(label: "Internet", stats: h.internet)
                    if let retx = h.retransmitPercent {
                        Text("Resent \(String(format: "%.1f", retx))%")
                    }
                }
                .font(.system(size: 10.5).monospacedDigit())
                .foregroundStyle(.secondary)
                .padding(.leading, 16)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.5)))
        }
    }

    private func color(_ level: HealthLevel) -> Color {
        switch level {
        case .measuring: return .secondary
        case .good: return .green
        case .notice: return .yellow
        case .bad: return .red
        }
    }
}

struct LatencyChip: View {
    let label: String
    let stats: LatencyStats
    var body: some View {
        if let avg = stats.averageMs {
            Text("\(label) \(avg < 10 ? String(format: "%.1f", avg) : String(Int(avg))) ms" + (stats.lossPercent > 0 ? ", \(Int(stats.lossPercent))% lost" : ""))
        } else if stats.samples > 0 {
            Text("\(label) no reply")
        } else {
            Text("\(label) …")
        }
    }
}

// MARK: Breakdown

struct BreakdownSection: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.theme) var theme

    var body: some View {
        let h = store.liveHeadline
        VStack(alignment: .leading, spacing: 4) {
            SectionTitle(title: "Traffic breakdown")
            row("Internet", h.internet, help: Measure.internet.explanation)
            row("Local network", h.local, help: "Your NAS, printers and other devices at home. This doesn't use your internet connection.")
            if store.detail.vpnName != nil {
                row("VPN tunnel", h.envelope, help: "The encrypted envelope around your internet traffic, so not extra data. The difference from Internet is VPN overhead.")
            }
            row("On the wire", h.wire, help: Measure.wire.explanation)
        }
    }

    private func row(_ label: String, _ value: Throughput, help: String) -> some View {
        HStack {
            Text(label).font(.system(size: 12))
            Spacer()
            RatePair(down: value.down, up: value.up)
        }
        .help(help)
    }
}

// MARK: Apps

struct RatePair: View {
    @Environment(\.theme) var theme
    let down: Double
    let up: Double
    /// Columns line up in lists. A standalone pair, as in a detail header, sits flush left.
    var aligned = true

    var body: some View {
        HStack(spacing: 8) {
            value(down, "↓", theme.download)
            value(up, "↑", theme.upload)
        }
    }

    private func value(_ v: Double, _ arrow: String, _ tint: Color) -> some View {
        HStack(spacing: 2) {
            Text(arrow).foregroundStyle(v > 0 ? tint : Color.secondary.opacity(0.5))
            Text(v > 0 ? theme.rate(v) : "–")
                .foregroundStyle(v > 0 ? .primary : .tertiary)
        }
        .font(.system(size: 11).monospacedDigit())
        .frame(minWidth: aligned ? 68 : nil, alignment: .trailing)
    }
}

struct TotalPair: View {
    @Environment(\.theme) var theme
    let rx: UInt64
    let tx: UInt64
    var aligned = true

    var body: some View {
        HStack(spacing: 8) {
            value(rx, "↓", theme.download)
            value(tx, "↑", theme.upload)
        }
    }

    private func value(_ v: UInt64, _ arrow: String, _ tint: Color) -> some View {
        HStack(spacing: 2) {
            Text(arrow).foregroundStyle(v > 0 ? tint : Color.secondary.opacity(0.5))
            Text(v > 0 ? Format.bytes(v) : "–").foregroundStyle(v > 0 ? .primary : .tertiary)
        }
        .font(.system(size: 11).monospacedDigit())
        .frame(minWidth: aligned ? 68 : nil, alignment: .trailing)
    }
}

/// Thin proportional bar under a row. Compares rows at a glance.
struct UsageBar: View {
    @Environment(\.theme) var theme
    let down: Double
    let up: Double
    let peak: Double

    var body: some View {
        GeometryReader { geo in
            let scale = peak > 0 ? geo.size.width / CGFloat(peak) : 0
            HStack(spacing: 1) {
                if down > 0 { Capsule().fill(theme.download.opacity(0.8)).frame(width: max(1, CGFloat(down) * scale)) }
                if up > 0 { Capsule().fill(theme.upload.opacity(0.8)).frame(width: max(1, CGFloat(up) * scale)) }
                Spacer(minLength: 0)
            }
        }
        .frame(height: 2)
    }
}

struct AppIcon: View {
    @Environment(\.theme) var theme
    let path: String?
    let kind: AppKind
    var size: CGFloat? = nil

    /// History stores only an ID and a path, so the kind is worked out from those.
    static func kind(id: String, path: String?) -> AppKind {
        if id.hasPrefix("system:") { return .system }
        if id == "exited" { return .exited }
        guard let path else { return .commandLine }
        return [".app", ".appex", ".systemextension"].contains { path.hasSuffix($0) } ? .app : .commandLine
    }

    var body: some View {
        let side = size ?? theme.iconSize
        Group {
            if let image = IconCache.icon(for: path), kind == .app {
                Image(nsImage: image).resizable()
            } else {
                Image(systemName: fallback)
                    .font(.system(size: side * 0.62))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: side, height: side)
    }

    private var fallback: String {
        switch kind {
        case .app: return "app"
        case .commandLine: return "terminal"
        case .system, .kernel: return "gearshape"
        case .exited: return "xmark.circle"
        }
    }
}

/// A row that highlights on hover and reports hover state, so ranking pauses under the pointer.
struct HoverRow<Content: View>: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.theme) var theme
    let action: () -> Void
    @ViewBuilder var content: () -> Content
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            content()
                .padding(.vertical, theme.rowPadding)
                .padding(.horizontal, 6)
                .contentShape(Rectangle())
                .background(RoundedRectangle(cornerRadius: 6).fill(hovering ? Color.primary.opacity(0.07) : .clear))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, -6)
        .onHover { over in
            hovering = over
            store.listHovered = over
        }
    }
}

struct AppsSection: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.theme) var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            SectionTitle(title: "Apps")
            if store.range == .live {
                live
            } else {
                history
            }
        }
    }

    @ViewBuilder private var live: some View {
        let apps = store.detail.apps.filter { app in
            if app.primaryClass == .envelope { return store.prefs.showVPNEnvelope }
            if app.primaryClass == .local { return store.prefs.showLocalInLists }
            return true
        }
        // When counting internet traffic, internet users rank first and set the bar scale.
        // A busy NAS shouldn't push the app that's actually using your internet off the list.
        let internetOnly = store.prefs.measure == .internet
        let ordered = internetOnly ? apps.filter { $0.primaryClass == .internet } + apps.filter { $0.primaryClass != .internet } : apps
        let shown = Array(ordered.prefix(store.prefs.rowLimit))
        let peak = shown.filter { !internetOnly || $0.primaryClass == .internet }.map { rates($0).down + rates($0).up }.max() ?? 0
        if shown.isEmpty {
            EmptyHint(text: "Watching for traffic…")
        }
        ForEach(shown) { app in
            let r = rates(app)
            HoverRow(action: { go(.app(app.id)) }) {
                HStack(spacing: 8) {
                    if store.prefs.showIcons { AppIcon(path: app.identity.path, kind: app.identity.kind) }
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 8) {
                            NameLine(app: app)
                            Spacer(minLength: 4)
                            RatePair(down: r.down, up: r.up)
                        }
                        if store.prefs.showBars, peak > 0, r.down + r.up >= peak * 0.02, !internetOnly || app.primaryClass == .internet {
                            UsageBar(down: r.down, up: r.up, peak: peak)
                        }
                    }
                }
            }
        }
    }

    private func rates(_ app: LiveApp) -> (down: Double, up: Double) {
        store.prefs.measure == .internet && app.primaryClass == .internet ? (app.internetDown, app.internetUp) : (app.down, app.up)
    }

    @ViewBuilder private var history: some View {
        let shown = store.historyApps.prefix(store.prefs.rowLimit)
        if shown.isEmpty {
            EmptyHint(text: "Nothing recorded for this period yet.")
        }
        ForEach(shown) { row in
            HoverRow(action: { go(.app(row.id)) }) {
                HStack(spacing: 8) {
                    if store.prefs.showIcons {
                        AppIcon(path: row.path, kind: AppIcon.kind(id: row.id, path: row.path))
                    }
                    Text(row.name).font(.system(size: 12)).lineLimit(1).truncationMode(.tail)
                    Spacer(minLength: 4)
                    TotalPair(rx: row.rx, tx: row.tx)
                }
            }
        }
    }

    private func go(_ route: Route) {
        store.route = route
        store.refreshHistory()
    }
}

struct NameLine: View {
    @EnvironmentObject var store: AppStore
    let app: LiveApp

    var body: some View {
        HStack(spacing: 4) {
            Text(app.identity.name).font(.system(size: 12)).lineLimit(1).truncationMode(.tail)
            if store.prefs.showTrustBadges {
                if let s = app.signer, s.status.isSuspicious || app.identity.impersonatesApple(signer: s), !app.verifiedApple, !app.trusted {
                    Image(systemName: "exclamationmark.shield.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.orange)
                        .help(s.status.label)
                }
                if app.isNew {
                    Badge(text: "NEW", tint: .accentColor)
                }
                if app.primaryClass == .local {
                    Badge(text: "LAN", tint: .secondary)
                } else if app.primaryClass == .envelope {
                    Badge(text: "VPN", tint: .secondary)
                }
            }
        }
    }
}

struct Badge: View {
    let text: String
    let tint: Color
    var body: some View {
        Text(text)
            .font(.system(size: 8.5, weight: .semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 3.5)
            .padding(.vertical, 1)
            .background(RoundedRectangle(cornerRadius: 3).stroke(tint.opacity(0.5), lineWidth: 0.5))
            .fixedSize()
    }
}

struct EmptyHint: View {
    let text: String
    var body: some View {
        Text(text).font(.system(size: 11)).foregroundStyle(.tertiary).padding(.vertical, 6)
    }
}

// MARK: Destinations

struct DestinationsSection: View {
    @EnvironmentObject var store: AppStore

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            SectionTitle(title: "Destinations")
            if store.range == .live {
                live
            } else {
                history
            }
        }
    }

    @ViewBuilder private var live: some View {
        let list = store.detail.destinations.filter { d in
            if d.cls == .envelope { return store.prefs.showVPNEnvelope }
            if d.cls == .local { return store.prefs.showLocalInLists }
            return true
        }
        let internetOnly = store.prefs.measure == .internet
        let ordered = internetOnly ? list.filter { $0.cls == .internet } + list.filter { $0.cls != .internet } : list
        let shown = Array(ordered.prefix(store.prefs.rowLimit))
        let peak = shown.filter { !internetOnly || $0.cls == .internet }.map { $0.down + $0.up }.max() ?? 0
        if shown.isEmpty { EmptyHint(text: "No connections yet.") }
        ForEach(shown) { d in
            HoverRow(action: { go(d.id) }) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        DestinationName(
                            label: d.destination.label, countryCode: d.destination.countryCode,
                            subtitle: d.appNames.prefix(2).joined(separator: ", ") + (d.appNames.count > 2 ? " +\(d.appNames.count - 2)" : ""),
                            isLocal: d.cls == .local)
                        Spacer(minLength: 4)
                        RatePair(down: d.down, up: d.up)
                    }
                    if store.prefs.showBars, peak > 0, d.down + d.up >= peak * 0.02, !internetOnly || d.cls == .internet {
                        UsageBar(down: d.down, up: d.up, peak: peak)
                    }
                }
            }
        }
    }

    @ViewBuilder private var history: some View {
        let shown = store.historyDestinations.filter { store.prefs.showLocalInLists || $0.cls != .local }.prefix(store.prefs.rowLimit)
        if shown.isEmpty { EmptyHint(text: "Nothing recorded for this period yet.") }
        ForEach(shown) { row in
            HoverRow(action: { go(row.id) }) {
                HStack(spacing: 8) {
                    DestinationName(label: row.name, countryCode: row.countryCode, subtitle: nil, isLocal: row.cls == .local)
                    Spacer(minLength: 4)
                    TotalPair(rx: row.rx, tx: row.tx)
                }
            }
        }
    }

    private func go(_ key: String) {
        store.route = .destination(key)
        store.refreshHistory()
    }
}

struct DestinationName: View {
    @EnvironmentObject var store: AppStore
    let label: String
    let countryCode: String?
    let subtitle: String?
    let isLocal: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 4) {
                if store.prefs.showCountry, let flag = Optional(OwnerNames.flag(countryCode)), !flag.isEmpty {
                    Text(flag).font(.system(size: 11)).help("Registered in \(countryCode ?? "")")
                }
                Text(label).font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
                if isLocal, store.prefs.showTrustBadges { Badge(text: "LAN", tint: .secondary) }
            }
            if store.prefs.showHostnames, let subtitle, !subtitle.isEmpty {
                Text(subtitle).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
            }
        }
    }
}

// MARK: Watch

struct WatchSection: View {
    @EnvironmentObject var store: AppStore

    var body: some View {
        let shown = store.events.prefix(store.prefs.rowLimit)
        VStack(alignment: .leading, spacing: 2) {
            SectionTitle(title: "Watch") {
                if store.detail.learningRemaining > 0 {
                    Text("Learning normal traffic, \(Int(ceil(store.detail.learningRemaining / 3600)))h left")
                }
            }
            if shown.isEmpty {
                EmptyHint(text: "Nothing unusual so far.")
            }
            ForEach(shown) { event in
                WatchRow(event: event)
            }
        }
    }
}

struct WatchRow: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.theme) var theme
    let event: WatchEvent
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: event.kind.symbol)
                .font(.system(size: 12))
                .foregroundStyle(event.kind.isHighSignal ? Color.orange : Color.accentColor)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(event.title)
                    .font(.system(size: 12, weight: event.read ? .regular : .semibold))
                    .fixedSize(horizontal: false, vertical: true)
                Text("\(event.detail) \(Format.relative(event.date))")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if hovering {
                    HStack(spacing: 10) {
                        Button("Details") { store.route = .app(event.appID); store.refreshHistory() }
                        Button("Trust this app") { store.setTrusted(appID: event.appID, true); store.dismiss(event) }
                        Button("Dismiss") { store.dismiss(event) }
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(Color.accentColor)
                    .padding(.top, 2)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, theme.rowPadding)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}

struct OwnerTablePrompt: View {
    @EnvironmentObject var store: AppStore

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Show who owns each address?").font(.system(size: 12, weight: .semibold))
            Text("Downloads an 11 MB table once from iptoasn.com. Lookups then stay on this Mac, so nobody learns where you connect.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            OwnerDownloadControl()
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.5)))
    }
}

struct OwnerDownloadControl: View {
    @EnvironmentObject var store: AppStore

    var body: some View {
        switch store.ownerDownload.phase {
        case .idle:
            Button("Download") { store.downloadOwnerTable() }.controlSize(.small)
        case .downloading:
            HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Downloading…").font(.system(size: 11)) }
        case .importing:
            HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Building table…").font(.system(size: 11)) }
        case .done(let count):
            Text("Done. \(count.formatted()) address ranges ready.").font(.system(size: 11)).foregroundStyle(.secondary)
        case .failed(let message):
            VStack(alignment: .leading, spacing: 4) {
                Text(message).font(.system(size: 11)).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                Button("Try Again") { store.downloadOwnerTable() }.controlSize(.small)
            }
        }
    }
}
