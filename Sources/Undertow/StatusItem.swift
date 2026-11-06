import AppKit
import Combine
import ServiceManagement
import SwiftUI
import UndertowCore

/// Lets a separate `Undertow --toggle-panel` process reach the running app. Any local process
/// can post this, so it carries no data and can do nothing beyond opening or closing the panel.
enum PanelCommand {
    static let bundleID = "local.undertow.app"
    private static let name = Notification.Name("local.undertow.app.togglePanel")

    static func send() {
        DistributedNotificationCenter.default().postNotificationName(name, object: nil, userInfo: nil, deliverImmediately: true)
    }

    static func listen(_ observer: Any, selector: Selector) {
        DistributedNotificationCenter.default().addObserver(observer, selector: selector, name: name, object: nil, suspensionBehavior: .deliverImmediately)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate, NSWindowDelegate {
    private let store = AppStore()
    private var statusItem: NSStatusItem!
    private var popover: NSPopover?
    private var settingsWindow: NSWindow?
    private var activity: NSObjectProtocol?
    private var spark = RingBuffer<Double>(capacity: StatusImage.sparkBars, filler: 0)
    private var valueWidth = StickyWidth()
    private var ownerWatch: AnyCancellable?
    private var lastRenderKey = ""
    /// The app you were in when the panel opened, so closing it hands the keyboard straight back.
    private var appBeforePanel: NSRunningApplication?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Without this, App Nap would throttle sampling, since a menu bar app has no visible window.
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep], reason: "Monitoring network traffic")

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.autosaveName = "UndertowMain"
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(statusItemClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.imagePosition = .imageOnly
            button.toolTip = "Undertow"
        }
        store.onHeadline = { [weak self] h in self?.render(h) }
        store.onPrefsChanged = { [weak self] in
            // New settings can change the text size, so measure afresh instead of holding the old width.
            self?.valueWidth = StickyWidth()
            self?.redraw()
        }
        store.onBadgeChanged = { [weak self] in self?.redraw() }
        redraw()
        store.start()

        // Maintenance: runs the same owner table refresh as the Update button in Settings.
        if CommandLine.arguments.contains("--update-owners") {
            ownerWatch = store.$ownerDownload.sink { state in
                switch state.phase {
                case .done(let count):
                    print("Owner table updated: \(count) ranges")
                    exit(0)
                case .failed(let message):
                    print("Owner table update failed: \(message)")
                    exit(1)
                default:
                    break
                }
            }
            store.downloadOwnerTable()
            return
        }
        if CommandLine.arguments.contains("--test-drag") {
            Snapshot.testDrag(store: store) { passed in
                store_flushAndExit(self.store, passed)
            }
            return
        }
        if let flag = CommandLine.arguments.firstIndex(of: "--snapshot"), CommandLine.arguments.count > flag + 1 {
            Snapshot.run(store: store, directory: CommandLine.arguments[flag + 1]) { NSApp.terminate(nil) }
            return
        }
        PanelCommand.listen(self, selector: #selector(togglePanelAction))
        if CommandLine.arguments.contains("--open-panel") {
            // Long enough for the status item to take its place in the menu bar.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.togglePanel() }
        }
        if CommandLine.arguments.contains("--open-settings") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.openSettings() }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        store.monitor.flush()
    }

    // MARK: Rendering

    private var latest = Headline()

    private func render(_ headline: Headline) {
        latest = headline
        let value = headline.value(for: store.prefs.measure)
        spark.append(value.down + value.up)
        // Repainting costs more than sampling, so skip it when the result would look the same.
        let p = store.prefs
        let width = currentValueWidth(value)
        let key = StatusImage.displayedText(prefs: p, throughput: value).joined(separator: "|") + "|\(width)"
        if key == lastRenderKey, !p.menuSparkline { return }
        lastRenderKey = key
        draw(value: value, valueWidth: width)
    }

    private func currentValueWidth(_ value: Throughput) -> CGFloat {
        let prefs = store.prefs
        if prefs.menuFixedWidth { return StatusImage.fixedValueWidth(prefs: prefs) }
        return CGFloat(valueWidth.update(needed: Double(StatusImage.neededValueWidth(prefs: prefs, throughput: value)), now: Date()))
    }

    /// Repaints from the latest reading. Settings changes and alerts call this directly,
    /// so they don't add a false sample to the activity graph.
    private func redraw() {
        let value = latest.value(for: store.prefs.measure)
        draw(value: value, valueWidth: currentValueWidth(value))
    }

    private func draw(value: Throughput, valueWidth: CGFloat) {
        guard let button = statusItem.button else { return }
        let dot = store.prefs.menuAlertDot && store.unreadEvents > 0
        let image = StatusImage.make(
            prefs: store.prefs, throughput: value, spark: store.prefs.menuSparkline ? spark.values() : [],
            alertDot: dot, appearance: button.effectiveAppearance, valueWidth: valueWidth)
        button.image = image
        // Variable length would already fit the image. Setting it only matters for clarity:
        // macOS adds its own spacing outside this length either way.
        let length = image.size.width
        if statusItem.length != length { statusItem.length = length }
        button.setAccessibilityLabel(
            "Download \(Format.rate(value.down, unit: store.prefs.units)), upload \(Format.rate(value.up, unit: store.prefs.units))")
    }

    // MARK: Clicks

    @objc private func statusItemClicked() {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            showMenu()
        } else {
            togglePanel()
        }
    }

    private func showMenu() {
        let menu = NSMenu()
        menu.addItem(withTitle: "Open Panel", action: #selector(togglePanelAction), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Settings…", action: #selector(openSettingsAction), keyEquivalent: ",").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Undertow", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func togglePanelAction() { togglePanel() }
    @objc private func openSettingsAction() { openSettings() }

    private func togglePanel() {
        if let popover, popover.isShown {
            popover.performClose(nil)
            return
        }
        guard let button = statusItem.button else { return }
        let view = PanelView(openSettings: { [weak self] in
            self?.appBeforePanel = nil  // Settings is taking the focus, so don't hand it back.
            self?.popover?.performClose(nil)
            self?.openSettings()
        }).environmentObject(store)
        let controller = NSHostingController(rootView: view)
        controller.sizingOptions = [.preferredContentSize]

        let pop = NSPopover()
        pop.behavior = .transient
        pop.animates = false
        pop.contentViewController = controller
        pop.delegate = self
        popover = pop
        store.panelOpened()
        // Takes keyboard focus so Esc works, and so a click elsewhere closes the panel.
        let front = NSWorkspace.shared.frontmostApplication
        appBeforePanel = front?.processIdentifier == ProcessInfo.processInfo.processIdentifier ? nil : front
        NSApp.activate(ignoringOtherApps: true)
        pop.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        pop.contentViewController?.view.window?.makeKey()
    }

    /// The view tree is thrown away on close, so a closed panel costs no CPU or memory.
    func popoverDidClose(_ notification: Notification) {
        store.panelClosed()
        popover?.contentViewController = nil
        popover = nil
        // If you clicked into another app, that app already has the focus and this does nothing.
        if NSApp.isActive, settingsWindow?.isVisible != true { appBeforePanel?.activate() }
        appBeforePanel = nil
    }

    private func openSettings() {
        if settingsWindow == nil {
            let controller = NSHostingController(rootView: SettingsView().environmentObject(store))
            let window = NSWindow(contentViewController: controller)
            window.title = "Undertow Settings"
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        settingsWindow = nil
    }
}

private func store_flushAndExit(_ store: AppStore, _ passed: Bool) {
    store.monitor.flush()
    exit(passed ? 0 : 1)
}

// MARK: - Status item image

enum StatusImage {
    static let sparkBars = 16
    /// Spacing macOS keeps around every status item, outside its length. It can't be removed.
    static let systemSpacing: CGFloat = 16

    private static func values(prefs: Prefs, throughput: Throughput) -> (down: Double, up: Double) {
        let idle = prefs.menuIdleThreshold
        return (throughput.down < idle ? 0 : throughput.down, throughput.up < idle ? 0 : throughput.up)
    }

    private static func text(_ v: Double, _ prefs: Prefs) -> String {
        Format.tightRate(v, unit: prefs.units, decimals: prefs.menuDecimals, short: prefs.menuShortUnits)
    }

    /// The strings currently on show. Also used to skip repaints when nothing has changed.
    static func displayedText(prefs: Prefs, throughput: Throughput) -> [String] {
        let v = values(prefs: prefs, throughput: throughput)
        switch prefs.menuContent {
        case .both: return [text(v.up, prefs), text(v.down, prefs)]
        case .download: return [text(v.down, prefs)]
        case .upload: return [text(v.up, prefs)]
        case .combined: return [text(v.down + v.up, prefs)]
        case .iconOnly: return []
        }
    }

    private static func isStacked(_ prefs: Prefs) -> Bool { prefs.menuLayout == .stacked && prefs.menuContent == .both }

    private static func font(_ prefs: Prefs) -> NSFont {
        let size: CGFloat
        switch (prefs.menuTextSize, isStacked(prefs)) {
        case (.small, true): size = 8.5
        case (.regular, true): size = 9.5
        case (.large, true): size = 10.5
        case (.small, false): size = 10.5
        case (.regular, false): size = 11.5
        case (.large, false): size = 12.5
        }
        return NSFont.monospacedDigitSystemFont(ofSize: size, weight: .medium)
    }

    private static func measure(_ s: String, _ prefs: Prefs) -> CGFloat {
        ceil((s as NSString).size(withAttributes: [.font: font(prefs)]).width)
    }

    private static func sample(_ digits: String, _ letter: String, _ prefs: Prefs) -> String {
        let suffix: String
        switch (prefs.units, prefs.menuShortUnits) {
        case (.bytes, false): suffix = "B/s"
        case (.bytes, true): suffix = "B"
        case (.bits, false): suffix = "bps"
        case (.bits, true): suffix = "b"
        }
        return "\(digits) \(letter)\(suffix)"
    }

    /// Room for what's on show now, with a floor so quiet moments don't make it twitch
    /// between "0 B/s" and "2.2 KB/s".
    static func neededValueWidth(prefs: Prefs, throughput: Throughput) -> CGFloat {
        let floor = measure(sample(prefs.menuDecimals > 0 ? "8.8" : "8", "K", prefs), prefs)
        return displayedText(prefs: prefs, throughput: throughput).reduce(floor) { max($0, measure($1, prefs)) }
    }

    /// Room for any speed, for the "keep a fixed width" setting. 8 is the widest digit and
    /// M the widest unit letter. Values never exceed three significant digits.
    static func fixedValueWidth(prefs: Prefs) -> CGFloat {
        measure(sample(prefs.menuDecimals > 0 ? "88.8" : "888", "M", prefs), prefs)
    }

    /// Draws the whole status item as one image. As a template image, macOS handles light
    /// bars, dark bars and the selected state on its own.
    static func make(prefs: Prefs, throughput: Throughput, spark: [Double], alertDot: Bool, appearance: NSAppearance, valueWidth: CGFloat) -> NSImage {
        let v = values(prefs: prefs, throughput: throughput)
        let (down, up) = (v.down, v.up)
        func text(_ value: Double) -> String { Self.text(value, prefs) }

        var lines: [(indicator: String, value: String, color: NSColor?)] = []
        let down1 = prefs.menuIndicator.down
        let up1 = prefs.menuIndicator.up
        let tinted = prefs.menuColor == .tinted
        switch prefs.menuContent {
        case .both:
            lines.append((up1, text(up), tinted && up > 0 ? Theme.nsUpload(prefs.palette) : nil))
            lines.append((down1, text(down), tinted && down > 0 ? Theme.nsDownload(prefs.palette) : nil))
        case .download:
            lines.append((down1, text(down), tinted && down > 0 ? Theme.nsDownload(prefs.palette) : nil))
        case .upload:
            lines.append((up1, text(up), tinted && up > 0 ? Theme.nsUpload(prefs.palette) : nil))
        case .combined:
            lines.append((prefs.menuIndicator == .none ? "" : "⇅", text(down + up), nil))
        case .iconOnly:
            break
        }

        let barHeight: CGFloat = 22
        let stacked = isStacked(prefs)
        let font = font(prefs)
        let attrs: [NSAttributedString.Key: Any] = [.font: font]

        func width(_ s: String) -> CGFloat { (s as NSString).size(withAttributes: attrs).width }
        // Only the glyphs actually on show count, so a narrow arrow doesn't reserve room for a wide one.
        let indicatorGlyphs = lines.map(\.indicator).filter { !$0.isEmpty }
        let indicatorWidth: CGFloat = indicatorGlyphs.isEmpty ? 0 : ceil(indicatorGlyphs.map(width).max() ?? 0) + 2

        let sparkWidth: CGFloat = spark.isEmpty ? 0 : 22
        let dotWidth: CGFloat = alertDot ? 8 : 0
        let isIconOnly = prefs.menuContent == .iconOnly

        var total: CGFloat = 2 + sparkWidth + dotWidth + 2
        if isIconOnly {
            total += 18
        } else if stacked {
            total += indicatorWidth + valueWidth
        } else {
            total += CGFloat(lines.count) * (indicatorWidth + valueWidth) + CGFloat(max(0, lines.count - 1)) * 6
        }
        if !spark.isEmpty, !isIconOnly { total += 3 }

        let needsColour = tinted || alertDot
        let image = NSImage(size: NSSize(width: ceil(total), height: barHeight), flipped: false) { _ in
            var x: CGFloat = 2
            let colour = NSColor.labelColor
            appearance.performAsCurrentDrawingAppearance {
                if alertDot {
                    NSColor.systemRed.setFill()
                    NSBezierPath(ovalIn: NSRect(x: x, y: barHeight / 2 - 3, width: 6, height: 6)).fill()
                    x += dotWidth
                }
                if !spark.isEmpty {
                    drawSpark(spark, in: NSRect(x: x, y: 4, width: sparkWidth - 2, height: barHeight - 8), colour: colour)
                    x += sparkWidth + (isIconOnly ? 0 : 3)
                }
                if isIconOnly {
                    drawGlyph(in: NSRect(x: x, y: 3, width: 16, height: 16), colour: colour)
                    return
                }
                func draw(_ line: (indicator: String, value: String, color: NSColor?), atX left: CGFloat, y: CGFloat) {
                    var a = attrs
                    a[.foregroundColor] = line.color ?? colour
                    if !line.indicator.isEmpty {
                        (line.indicator as NSString).draw(at: NSPoint(x: left, y: y), withAttributes: a)
                    }
                    a[.foregroundColor] = colour
                    // Stacked values right-align, so units line up. On one line that would leave
                    // a gap after the arrow, so there the number sits next to its indicator.
                    let vw = (line.value as NSString).size(withAttributes: a).width
                    let vx = stacked ? left + indicatorWidth + valueWidth - vw : left + indicatorWidth
                    (line.value as NSString).draw(at: NSPoint(x: vx, y: y), withAttributes: a)
                }
                let lineHeight = ceil(font.ascender - font.descender)
                if stacked {
                    draw(lines[0], atX: x, y: barHeight / 2 - 0.5)
                    draw(lines[1], atX: x, y: barHeight / 2 - lineHeight + 0.5)
                } else {
                    var left = x
                    let y = (barHeight - lineHeight) / 2
                    for line in lines.reversed() {
                        draw(line, atX: left, y: y)
                        left += indicatorWidth + valueWidth + 6
                    }
                }
            }
            return true
        }
        image.isTemplate = !needsColour
        return image
    }

    private static func drawSpark(_ allValues: [Double], in rect: NSRect, colour: NSColor) {
        let values = Array(allValues.suffix(sparkBars))
        guard values.count > 1, let peak = values.max(), peak > 0 else {
            colour.withAlphaComponent(0.4).setFill()
            NSBezierPath(rect: NSRect(x: rect.minX, y: rect.minY, width: rect.width, height: 1)).fill()
            return
        }
        // Bars keep their position from the right as the buffer fills after launch.
        let barWidth = rect.width / CGFloat(sparkBars)
        let start = rect.maxX - barWidth * CGFloat(values.count)
        colour.setFill()
        for (i, v) in values.enumerated() {
            let h = max(1, CGFloat(sqrt(v / peak)) * rect.height)
            NSBezierPath(rect: NSRect(x: start + CGFloat(i) * barWidth, y: rect.minY, width: max(1, barWidth - 0.5), height: h)).fill()
        }
    }

    private static func drawGlyph(in rect: NSRect, colour: NSColor) {
        colour.setStroke()
        for (i, y) in [rect.minY + 12.5, rect.minY + 8, rect.minY + 3.5].enumerated() {
            let p = NSBezierPath()
            let shift = CGFloat(i)
            p.move(to: NSPoint(x: rect.minX + shift, y: y))
            p.curve(
                to: NSPoint(x: rect.maxX - 1 + shift * 0.5, y: y),
                controlPoint1: NSPoint(x: rect.minX + 5, y: y + 3.4),
                controlPoint2: NSPoint(x: rect.minX + 10, y: y - 3.4))
            p.lineWidth = 1.6
            p.lineCapStyle = .round
            p.stroke()
        }
    }
}

// MARK: - Launch at login

enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    static var statusDescription: String {
        switch SMAppService.mainApp.status {
        case .enabled: return "enabled"
        case .notRegistered: return "not registered"
        case .requiresApproval: return "needs approval in System Settings > General > Login Items"
        case .notFound: return "not found"
        @unknown default: return "unknown"
        }
    }

    /// Returns an error message on failure, for showing in Settings.
    static func set(_ enabled: Bool) -> String? {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}
