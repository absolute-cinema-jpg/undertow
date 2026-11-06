import AppKit
import SwiftUI
import UndertowCore

struct SettingsView: View {
    @EnvironmentObject var store: AppStore

    var body: some View {
        TabView {
            MenuBarSettings().tabItem { Label("Menu Bar", systemImage: "menubar.rectangle") }
            PanelSettings().tabItem { Label("Panel", systemImage: "rectangle.grid.1x2") }
            WatchSettings().tabItem { Label("Watch", systemImage: "eye") }
            DataSettings().tabItem { Label("Data", systemImage: "externaldrive") }
        }
        .frame(width: 500, height: 600)
        .padding(.top, 8)
    }
}

/// Form footers centre or right-align by default, which reads badly over several lines.
struct FooterText: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Menu bar

struct MenuBarSettings: View {
    @EnvironmentObject var store: AppStore

    var body: some View {
        Form {
            Section {
                Picker("Show", selection: $store.prefs.menuContent) {
                    ForEach(MenuContent.allCases) { Text($0.label).tag($0) }
                }
                if store.prefs.menuContent == .both {
                    Picker("Layout", selection: $store.prefs.menuLayout) {
                        ForEach(MenuLayout.allCases) { Text($0.label).tag($0) }
                    }
                }
                if store.prefs.menuContent != .iconOnly {
                    Picker("Indicators", selection: $store.prefs.menuIndicator) {
                        ForEach(MenuIndicator.allCases) { Text($0.label).tag($0) }
                    }
                    Picker("Text size", selection: $store.prefs.menuTextSize) {
                        ForEach(TextSize.allCases) { Text($0.label).tag($0) }
                    }
                    Picker("Decimals", selection: $store.prefs.menuDecimals) {
                        Text("None").tag(0)
                        Text("Up to one").tag(1)
                        Text("Up to two").tag(2)
                    }
                    Picker("Colour", selection: $store.prefs.menuColor) {
                        ForEach(MenuColor.allCases) { Text($0.label).tag($0) }
                    }
                }
                Toggle("Activity graph", isOn: $store.prefs.menuSparkline)
                Toggle("Red dot for new alerts", isOn: $store.prefs.menuAlertDot)
                if store.prefs.menuContent != .iconOnly {
                    Toggle("Shorter units (MB instead of MB/s)", isOn: $store.prefs.menuShortUnits)
                    Toggle("Keep a fixed width", isOn: $store.prefs.menuFixedWidth)
                }
            } header: {
                Text("Appearance")
            } footer: {
                FooterText("Changes appear in your menu bar right away. Normally the width follows your current speeds and narrows after about 20 quiet seconds. A fixed width takes more room, but icons next to it never move.")
            }

            Section("Values") {
                Picker("Units", selection: $store.prefs.units) {
                    Text("Bytes (MB/s)").tag(RateUnit.bytes)
                    Text("Bits (Mbps)").tag(RateUnit.bits)
                }
                Picker("Treat as idle below", selection: $store.prefs.menuIdleThreshold) {
                    Text("Always show exact").tag(0.0)
                    Text("1 KB/s").tag(1000.0)
                    Text("10 KB/s").tag(10000.0)
                    Text("100 KB/s").tag(100000.0)
                }
                Picker("Count", selection: $store.prefs.measure) {
                    ForEach(Measure.allCases) { Text($0.label).tag($0) }
                }
                Text(store.prefs.measure.explanation).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Panel

struct PanelSettings: View {
    @EnvironmentObject var store: AppStore

    var body: some View {
        Form {
            Section("Quick setup") {
                HStack(alignment: .top, spacing: 10) {
                    ForEach(PanelPreset.allCases) { preset in
                        Button {
                            store.prefs.apply(preset)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(preset.label).font(.system(size: 12, weight: .semibold))
                                Text(preset.summary)
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                            .contentShape(Rectangle())
                            .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.5)))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            Section {
                SectionOrderList()
            } header: {
                Text("Sections")
            } footer: {
                FooterText("Drag a section to change its order, and use the switch to show or hide it.")
            }

            Section("Row details") {
                Toggle("App icons", isOn: $store.prefs.showIcons)
                Toggle("Usage bars", isOn: $store.prefs.showBars)
                Toggle("Warning and status badges", isOn: $store.prefs.showTrustBadges)
                Toggle("Country flags", isOn: $store.prefs.showCountry)
                Toggle("Hostnames and app names under destinations", isOn: $store.prefs.showHostnames)
                Toggle("Protocol, port and network on connections", isOn: $store.prefs.showPorts)
                Toggle("Latency on connections", isOn: $store.prefs.showLatency)
                Toggle("Include local network devices in lists", isOn: $store.prefs.showLocalInLists)
                Toggle("Show the VPN's own tunnel in lists", isOn: $store.prefs.showVPNEnvelope)
            }

            Section("Layout") {
                Picker("Rows per list", selection: $store.prefs.rowLimit) {
                    ForEach([3, 5, 6, 8, 10, 15, 25], id: \.self) { Text("\($0)").tag($0) }
                }
                Picker("Row spacing", selection: $store.prefs.density) {
                    ForEach(Density.allCases) { Text($0.label).tag($0) }
                }
                Picker("Panel width", selection: $store.prefs.panelWidth) {
                    ForEach(PanelWidth.allCases) { Text($0.label).tag($0) }
                }
                Picker("Graph covers", selection: $store.prefs.graphSpan) {
                    Text("1 minute").tag(60)
                    Text("5 minutes").tag(300)
                    Text("15 minutes").tag(900)
                    Text("1 hour").tag(3600)
                }
                Picker("Colours", selection: $store.prefs.palette) {
                    ForEach(Palette.allCases) { Text($0.label).tag($0) }
                }
                Picker("Open showing", selection: $store.prefs.defaultRange) {
                    ForEach(TimeRange.allCases) { Text($0.label).tag($0) }
                }
            }
        }
        .formStyle(.grouped)
    }

}

/// The panel's sections, reorderable by dragging. A custom list, because a Form's rows
/// don't support drag-to-reorder and a nested List brings its own scrolling and selection.
struct SectionOrderList: View {
    @EnvironmentObject var store: AppStore
    /// The order while a drag is under way. Saved only on release.
    @State private var liveOrder: [PanelSection]?
    @State private var dragged: PanelSection?
    @State private var translation: CGFloat = 0
    @State private var startIndex = 0

    static let rowHeight: CGFloat = 34
    private static let spaceName = "sectionOrder"

    private var order: [PanelSection] { liveOrder ?? store.prefs.sectionOrder }

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(order.enumerated()), id: \.element) { index, section in
                row(section, index: index)
            }
        }
        .coordinateSpace(name: Self.spaceName)
    }

    private func row(_ section: PanelSection, index: Int) -> some View {
        let isDragged = dragged == section
        return HStack(spacing: 8) {
            // The switch sits outside the drag area, so toggling can't turn into a drag.
            HStack(spacing: 10) {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.tertiary)
                Label(section.label, systemImage: section.symbol)
                Spacer(minLength: 0)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .onHover { over in
                if over { NSCursor.openHand.push() } else { NSCursor.pop() }
            }
            .gesture(dragGesture(section))
            Toggle("Show \(section.label)", isOn: visibility(section))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)  // the size a Form gives the switches in other sections
        }
        .frame(height: Self.rowHeight)
        .background {
            if isDragged {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color(nsColor: .controlBackgroundColor))
                    .shadow(color: .black.opacity(0.25), radius: 5, y: 2)
                    .padding(.horizontal, -6)
            }
        }
        .overlay(alignment: .bottom) {
            if !isDragged, index < order.count - 1 { Divider() }
        }
        // The list has already moved this row to its new slot, so only the rest of the drag is offset.
        .offset(y: isDragged ? translation - CGFloat(index - startIndex) * Self.rowHeight : 0)
        .zIndex(isDragged ? 1 : 0)
        .accessibilityElement(children: .contain)
        .accessibilityHint("Drag to reorder")
        .accessibilityAction(named: "Move up") { nudge(section, by: -1) }
        .accessibilityAction(named: "Move down") { nudge(section, by: 1) }
    }

    private func dragGesture(_ section: PanelSection) -> some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .named(Self.spaceName))
            .onChanged { value in
                if dragged != section {
                    let current = store.prefs.sectionOrder
                    liveOrder = current
                    startIndex = current.firstIndex(of: section) ?? 0
                    dragged = section
                    NSCursor.closedHand.push()
                }
                translation = value.translation.height
                let working = liveOrder ?? store.prefs.sectionOrder
                guard let from = working.firstIndex(of: section) else { return }
                let target = DragReorder.targetIndex(
                    start: startIndex, translation: translation, rowHeight: Self.rowHeight, count: working.count)
                if target != from {
                    withAnimation(.easeOut(duration: 0.14)) {
                        liveOrder = DragReorder.moved(working, from: from, to: target)
                    }
                }
            }
            .onEnded { _ in
                NSCursor.pop()
                if let liveOrder { store.prefs.sectionOrder = liveOrder }
                withAnimation(.easeOut(duration: 0.14)) {
                    dragged = nil
                    translation = 0
                    liveOrder = nil
                }
            }
    }

    /// VoiceOver can't drag, so each row also offers Move Up and Move Down actions.
    private func nudge(_ section: PanelSection, by offset: Int) {
        let current = store.prefs.sectionOrder
        guard let from = current.firstIndex(of: section) else { return }
        store.prefs.sectionOrder = DragReorder.moved(current, from: from, to: from + offset)
    }

    private func visibility(_ section: PanelSection) -> Binding<Bool> {
        Binding(
            get: { !store.prefs.hiddenSections.contains(section) },
            set: { visible in
                if visible {
                    store.prefs.hiddenSections.remove(section)
                } else {
                    store.prefs.hiddenSections.insert(section)
                }
            })
    }
}

// MARK: - Watch

struct WatchSettings: View {
    @EnvironmentObject var store: AppStore
    @State private var permissionDenied = false

    var body: some View {
        Form {
            Section {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                    GridRow {
                        Text("").gridColumnAlignment(.leading)
                        Text("Show").font(.caption).foregroundStyle(.secondary)
                        Text("Notify").font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(WatchKind.allCases) { kind in
                        GridRow {
                            Text(kind.label)
                            Toggle("Show \(kind.label)", isOn: enabledBinding(kind)).labelsHidden()
                            Toggle("Notify for \(kind.label)", isOn: notifyBinding(kind))
                                .labelsHidden()
                                .disabled(!store.prefs.watchEnabled.contains(kind))
                        }
                    }
                }
                if permissionDenied {
                    Text("Notifications are off for Undertow. You can allow them in System Settings > Notifications.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            } header: {
                Text("Alert me about")
            } footer: {
                FooterText("These are prompts to take a look, not proof of a problem. A big iCloud upload will trigger the same alert as a real leak. Trusting an app quiets its alerts only while it stays signed the same way.")
            }

            Section("Thresholds") {
                Picker("Large upload", selection: $store.prefs.largeUploadMB) {
                    ForEach([25, 50, 100, 250, 500, 1000], id: \.self) { Text("\($0) MB in 10 minutes").tag($0) }
                }
                Picker("Upload while away", selection: $store.prefs.idleUploadMB) {
                    ForEach([5, 10, 20, 50, 100], id: \.self) { Text("\($0) MB in 10 minutes").tag($0) }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func enabledBinding(_ kind: WatchKind) -> Binding<Bool> {
        Binding(
            get: { store.prefs.watchEnabled.contains(kind) },
            set: { on in
                if on {
                    store.prefs.watchEnabled.insert(kind)
                } else {
                    store.prefs.watchEnabled.remove(kind)
                    store.prefs.notifyKinds.remove(kind)
                }
            })
    }

    private func notifyBinding(_ kind: WatchKind) -> Binding<Bool> {
        Binding(
            get: { store.prefs.notifyKinds.contains(kind) },
            set: { on in
                if on {
                    Notifier.requestPermission { granted in
                        permissionDenied = !granted
                        if granted { store.prefs.notifyKinds.insert(kind) }
                    }
                } else {
                    store.prefs.notifyKinds.remove(kind)
                }
            })
    }
}

// MARK: - Data

struct DataSettings: View {
    @EnvironmentObject var store: AppStore
    @State private var loginEnabled = LoginItem.isEnabled
    @State private var loginError: String?
    @State private var confirmClear = false
    @State private var confirmReset = false

    var body: some View {
        Form {
            Section("General") {
                Toggle("Open at login", isOn: Binding(
                    get: { loginEnabled },
                    set: { on in
                        loginError = LoginItem.set(on)
                        loginEnabled = LoginItem.isEnabled
                    }))
                if let loginError {
                    Text(loginError).font(.caption).foregroundStyle(.red)
                }
                Picker("Update every", selection: $store.prefs.interval) {
                    Text("1 second").tag(1.0)
                    Text("2 seconds").tag(2.0)
                    Text("5 seconds").tag(5.0)
                }
            }

            Section {
                Toggle("Keep a history", isOn: $store.prefs.recordHistory)
                Picker("Keep for", selection: $store.prefs.retentionDays) {
                    ForEach([1, 7, 30, 90, 365], id: \.self) { Text($0 == 1 ? "1 day" : "\($0) days").tag($0) }
                }
                .disabled(!store.prefs.recordHistory)
                HStack {
                    Button("Clear History…") { confirmClear = true }
                    Button("Reset Everything…") { confirmReset = true }
                }
            } header: {
                Text("History")
            } footer: {
                FooterText("History reveals which services you use, so it's stored only on this Mac, readable only by your account, and left out of backups. Turning it off stops recording, and alerts about new apps and destinations stop with it, because they rely on that record. Clearing erases what's saved except your trusted apps, and starts the learning period again. Resetting also forgets trusted apps.")
            }

            Section {
                HStack {
                    if let date = store.monitor.owners.lastUpdated, store.monitor.owners.isAvailable {
                        Text("Updated \(date.formatted(date: .abbreviated, time: .omitted))")
                    } else {
                        Text("Not downloaded")
                    }
                    Spacer()
                    if store.monitor.owners.isAvailable, store.ownerDownload.phase == .idle {
                        Button("Update") { store.downloadOwnerTable() }
                    } else {
                        OwnerDownloadControl()
                    }
                }
            } header: {
                Text("IP owner table")
            } footer: {
                FooterText("About 11 MB from iptoasn.com. Downloading it tells that site nothing about what you connect to, because lookups happen on this Mac.")
            }

            Section {
                Toggle("Look up hostnames (reverse DNS)", isOn: $store.prefs.reverseDNS)
                Toggle("Check latency while the panel is open", isOn: $store.prefs.healthProbes)
                TextField("Latency check address", text: $store.prefs.pingTarget)
                    .disabled(!store.prefs.healthProbes)
            } header: {
                Text("Network activity by Undertow")
            } footer: {
                FooterText("Hostname lookups go to your normal DNS server and latency checks ping your router and this address, both only while the panel is open. Undertow sends nothing else, apart from the owner table download above. A hostname only shows if it leads back to the same address, so a server can't pass itself off as someone else.")
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Clear all recorded traffic and alerts?", isPresented: $confirmClear) {
            Button("Clear History", role: .destructive) { store.clearHistory(includingBaseline: false) }
        } message: {
            Text("This erases traffic history, alerts and known destinations, and starts the learning period again. Your trusted apps are kept. This can't be undone.")
        }
        .confirmationDialog("Reset everything Undertow has learned?", isPresented: $confirmReset) {
            Button("Reset Everything", role: .destructive) { store.clearHistory(includingBaseline: true) }
        } message: {
            Text("This erases history, alerts, trusted apps and known destinations, and starts the learning period again. This can't be undone.")
        }
    }
}
