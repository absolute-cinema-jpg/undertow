import AppKit
import SwiftUI
import UndertowCore

/// Developer tool: `Undertow --snapshot <dir>` renders the real views with live data to PNG,
/// so the UI can be checked without Screen Recording permission.
///
/// Each step returns to the run loop before rendering. Live data arrives on the main queue,
/// so a step that waited in place would block it and capture stale values.
enum Snapshot {
    private struct Step {
        var setup: () -> Void
        var render: () -> Void
    }

    static func run(store: AppStore, directory: String, seconds: Double = 10, done: @escaping () -> Void) {
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        store.panelOpened()
        let scheme: ColorScheme = ProcessInfo.processInfo.environment["UNDERTOW_LIGHT"] != nil ? .light : .dark
        let original = store.prefs
        var steps: [Step] = []

        func panel(_ name: String, setup: @escaping () -> Void) {
            steps.append(Step(
                setup: {
                    setup()
                    store.refreshHistory()
                },
                render: {
                    render(PanelView(openSettings: {}).environmentObject(store), scheme: scheme, to: "\(directory)/\(name).png")
                }))
        }

        panel("panel-home") { store.route = .home }
        panel("panel-app") {
            if let app = store.detail.apps.first(where: { $0.primaryClass == .internet }) { store.route = .app(app.id) }
        }
        panel("panel-destination") {
            if let d = store.detail.destinations.first(where: { $0.cls == .internet && $0.id != "unconnected" }) { store.route = .destination(d.id) }
        }
        panel("preset-minimal") {
            store.route = .home
            store.prefs.apply(.minimal)
        }
        panel("preset-everything") { store.prefs.apply(.everything) }
        panel("panel-today") {
            store.prefs = original
            store.range = .today
        }
        panel("panel-today-app") {
            if let row = store.historyApps.first { store.route = .app(row.id) }
        }

        steps.append(Step(
            setup: {
                store.route = .home
                store.range = .live
            },
            render: {
                renderStatusVariants(to: "\(directory)/status.png")
                let tabs: [(AnyView, String)] = [
                    (AnyView(MenuBarSettings()), "settings-menubar"), (AnyView(PanelSettings()), "settings-panel"),
                    (AnyView(WatchSettings()), "settings-watch"), (AnyView(DataSettings()), "settings-data"),
                ]
                for (view, name) in tabs {
                    render(view.environmentObject(store).frame(width: 500), scheme: scheme, to: "\(directory)/\(name).png")
                }
            }))

        func runStep(_ index: Int) {
            guard index < steps.count else {
                print("Snapshots written to \(directory)")
                done()
                return
            }
            steps[index].setup()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                steps[index].render()
                DispatchQueue.main.async { runStep(index + 1) }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { runStep(0) }
    }

    /// Developer tool: `Undertow --test-drag`. Sends simulated mouse events through the real
    /// settings form and checks the result, since dragging can't be proven by a static render.
    /// Restores your settings afterwards.
    static func testDrag(store: AppStore, done: @escaping (Bool) -> Void) {
        let original = store.prefs
        var testPrefs = original
        testPrefs.sectionOrder = PanelSection.allCases
        testPrefs.hiddenSections = []
        store.prefs = testPrefs

        let height: CGFloat = 900
        let host = NSHostingView(rootView: PanelSettings().environmentObject(store).frame(width: 500, height: height))
        host.frame = NSRect(x: 0, y: 0, width: 500, height: height)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        window.alphaValue = 0.01
        window.orderFront(nil)
        window.makeKey()

        var passed = true
        func expect(_ ok: Bool, _ name: String) {
            print((ok ? "ok    " : "FAIL  ") + name)
            passed = passed && ok
        }
        func send(_ type: NSEvent.EventType, _ point: NSPoint) {
            let event = NSEvent.mouseEvent(
                with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                pressure: type == .leftMouseUp ? 0 : 1)!
            window.sendEvent(event)
        }
        /// Runs each step on its own run loop pass, as real mouse events would arrive.
        func sequence(_ steps: [() -> Void], then next: @escaping () -> Void) {
            guard let first = steps.first else { return next() }
            first()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) { sequence(Array(steps.dropFirst()), then: next) }
        }
        func drag(from: NSPoint, byY: CGFloat, then next: @escaping () -> Void) {
            var steps: [() -> Void] = [{ send(.leftMouseDown, from) }]
            for i in 1...10 {
                let p = NSPoint(x: from.x, y: from.y + byY * CGFloat(i) / 10)
                steps.append { send(.leftMouseDragged, p) }
            }
            steps.append { send(.leftMouseUp, NSPoint(x: from.x, y: from.y + byY)) }
            sequence(steps, then: next)
        }

        let row = SectionOrderList.rowHeight
        // Window coordinates count up from the bottom. The first row's position in the form
        // comes from the render, and is confirmed by the first drag having the right effect.
        let firstRowY = height - CGFloat(ProcessInfo.processInfo.environment["UNDERTOW_ROW_TOP"].flatMap(Double.init) ?? 208)
        func rowPoint(_ i: Int, x: CGFloat = 120) -> NSPoint { NSPoint(x: x, y: firstRowY - row * CGFloat(i)) }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            let a = PanelSection.allCases
            drag(from: rowPoint(0), byY: -row * 3) {
                expect(store.prefs.sectionOrder == [a[1], a[2], a[3], a[0], a[4], a[5]], "drag first row down three places: \(store.prefs.sectionOrder.map(\.rawValue))")
                let afterFirst = store.prefs.sectionOrder
                drag(from: rowPoint(5), byY: row * 2) {
                    expect(store.prefs.sectionOrder == DragReorder.moved(afterFirst, from: 5, to: 3), "drag last row up two places: \(store.prefs.sectionOrder.map(\.rawValue))")
                    let beforeSmall = store.prefs.sectionOrder
                    drag(from: rowPoint(2), byY: -row * 0.3) {
                        expect(store.prefs.sectionOrder == beforeSmall, "a small drag changes nothing")
                        drag(from: rowPoint(1), byY: row * 40) {
                            expect(store.prefs.sectionOrder.first == beforeSmall[1] && store.prefs.sectionOrder.count == a.count, "a huge drag stops at the top and loses nothing")
                            let orderBeforeToggle = store.prefs.sectionOrder
                            let target = orderBeforeToggle[2]
                            let switchPoint = rowPoint(2, x: 456)
                            // A native switch runs its own tracking loop on mouse down and reads the
                            // mouse up from the queue, so that has to be waiting there first.
                            let up = NSEvent.mouseEvent(
                                with: .leftMouseUp, location: switchPoint, modifierFlags: [],
                                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                context: nil, eventNumber: 0, clickCount: 1, pressure: 0)!
                            sequence([{
                                window.postEvent(up, atStart: false)
                                send(.leftMouseDown, switchPoint)
                            }]) {
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                                    expect(store.prefs.hiddenSections.contains(target), "clicking the switch hides that section")
                                    expect(store.prefs.sectionOrder == orderBeforeToggle, "clicking the switch doesn't reorder")
                                    window.orderOut(nil)
                                    store.prefs = original
                                    print("settings restored: \(store.prefs == original)")
                                    done(passed)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private static func render<V: View>(_ view: V, scheme: ColorScheme, to path: String) {
        let appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        let host = NSHostingView(rootView: view.environment(\.colorScheme, scheme))
        host.appearance = appearance
        var size = host.fittingSize
        // Forms scroll internally and report little height, so give them room to lay out.
        if size.height < 200 { size.height = 900 }
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.appearance = appearance
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.25))
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        let canvas = NSImage(size: host.bounds.size)
        host.cacheDisplay(in: host.bounds, to: rep)
        canvas.addRepresentation(rep)
        let flat = NSImage(size: host.bounds.size)
        flat.lockFocus()
        (scheme == .dark ? NSColor(white: 0.13, alpha: 1) : NSColor(white: 0.96, alpha: 1)).setFill()
        NSRect(origin: .zero, size: host.bounds.size).fill()
        canvas.draw(in: NSRect(origin: .zero, size: host.bounds.size))
        flat.unlockFocus()
        write(flat, to: path)
    }

    private static func renderStatusVariants(to path: String) {
        let sample = Throughput(down: 12_400_000, up: 386_000)
        let spark: [Double] = (0..<24).map { 1000 + 9000 * abs(sin(Double($0) / 3)) }
        var variants: [(String, Prefs, [Double], Bool)] = []
        var p = Prefs()
        variants.append(("Default", p, [], false))
        p = Prefs(); p.menuLayout = .inline
        variants.append(("One line", p, [], false))
        p = Prefs(); p.menuContent = .download; p.menuDecimals = 0
        variants.append(("Download only", p, [], false))
        p = Prefs(); p.menuContent = .combined
        variants.append(("Combined", p, [], false))
        p = Prefs(); p.menuContent = .iconOnly
        variants.append(("Icon only", p, [], false))
        p = Prefs(); p.menuColor = .tinted; p.menuSparkline = true
        variants.append(("Tinted + graph", p, spark, false))
        p = Prefs(); p.units = .bits; p.menuIndicator = .letters
        variants.append(("Bits + letters", p, [], false))
        p = Prefs(); p.menuTextSize = .large; p.menuIndicator = .none
        variants.append(("Large + alert", p, [], true))
        p = Prefs(); p.menuShortUnits = true
        variants.append(("Short units", p, [], false))
        p = Prefs(); p.menuFixedWidth = true
        variants.append(("Fixed width", p, [], false))
        p = Prefs(); p.menuDecimals = 2; p.menuSparkline = true
        variants.append(("2 decimals + graph", p, spark, false))

        let dark = NSAppearance(named: .darkAqua)!
        let rowHeight: CGFloat = 30
        let size = NSSize(width: 420, height: rowHeight * CGFloat(variants.count))
        let scale: CGFloat = 2
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        dark.performAsCurrentDrawingAppearance {
            NSColor(white: 0.16, alpha: 1).setFill()
            NSRect(origin: .zero, size: size).fill()
            for (i, v) in variants.enumerated() {
                let y = size.height - rowHeight * CGFloat(i + 1) + 4
                (v.0 as NSString).draw(at: NSPoint(x: 10, y: y + 3), withAttributes: [.foregroundColor: NSColor.secondaryLabelColor, .font: NSFont.systemFont(ofSize: 11)])
                let valueWidth = v.1.menuFixedWidth
                    ? StatusImage.fixedValueWidth(prefs: v.1)
                    : StatusImage.neededValueWidth(prefs: v.1, throughput: sample)
                let img = StatusImage.make(prefs: v.1, throughput: sample, spark: v.2, alertDot: v.3, appearance: dark, valueWidth: valueWidth)
                let target = NSRect(x: 130, y: y, width: img.size.width, height: img.size.height)
                if img.isTemplate {
                    // Stand in for what the menu bar does with a template image on a dark bar.
                    let tinted = NSImage(size: img.size, flipped: false) { r in
                        img.draw(in: r)
                        NSColor.white.set()
                        r.fill(using: .sourceAtop)
                        return true
                    }
                    tinted.draw(in: target)
                } else {
                    img.draw(in: target)
                }
                ("\(Int(img.size.width + StatusImage.systemSpacing)) pt in menu bar" as NSString).draw(at: NSPoint(x: 340, y: y + 3), withAttributes: [.foregroundColor: NSColor.tertiaryLabelColor, .font: NSFont.systemFont(ofSize: 10)])
            }
        }
        NSGraphicsContext.restoreGraphicsState()
        if let data = rep.representation(using: .png, properties: [:]) { try? data.write(to: URL(fileURLWithPath: path)) }
    }

    private static func write(_ image: NSImage, to path: String) {
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
            let data = rep.representation(using: .png, properties: [:])
        else { return }
        try? data.write(to: URL(fileURLWithPath: path))
    }
}
