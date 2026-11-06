import Foundation

public enum MenuContent: String, Codable, CaseIterable, Identifiable, Sendable {
    case both, download, upload, combined, iconOnly
    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .both: return "Download and upload"
        case .download: return "Download only"
        case .upload: return "Upload only"
        case .combined: return "Combined total"
        case .iconOnly: return "Icon only"
        }
    }
}

public enum MenuLayout: String, Codable, CaseIterable, Identifiable, Sendable {
    case stacked, inline
    public var id: String { rawValue }
    public var label: String { self == .stacked ? "Two lines" : "One line" }
}

public enum MenuIndicator: String, Codable, CaseIterable, Identifiable, Sendable {
    case arrows, triangles, letters, none
    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .arrows: return "Arrows ↓ ↑"
        case .triangles: return "Triangles ▼ ▲"
        case .letters: return "Letters D U"
        case .none: return "None"
        }
    }
    public var down: String {
        switch self {
        case .arrows: return "↓"
        case .triangles: return "▼"
        case .letters: return "D"
        case .none: return ""
        }
    }
    public var up: String {
        switch self {
        case .arrows: return "↑"
        case .triangles: return "▲"
        case .letters: return "U"
        case .none: return ""
        }
    }
}

public enum MenuColor: String, Codable, CaseIterable, Identifiable, Sendable {
    case monochrome, tinted
    public var id: String { rawValue }
    public var label: String { self == .monochrome ? "Match the menu bar" : "Colour the indicators" }
}

public enum TextSize: String, Codable, CaseIterable, Identifiable, Sendable {
    case small, regular, large
    public var id: String { rawValue }
    public var label: String { rawValue.capitalized }
}

/// What the headline number counts.
public enum Measure: String, Codable, CaseIterable, Identifiable, Sendable {
    case internet, allApps, wire
    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .internet: return "Internet traffic"
        case .allApps: return "Internet + local network"
        case .wire: return "Everything on the wire"
        }
    }
    public var explanation: String {
        switch self {
        case .internet: return "What your apps send to and receive from the internet. Skips your NAS and printers, and doesn't count VPN traffic twice. Best for finding what's using your internet."
        case .allApps: return "Adds traffic to devices on your own network, such as a NAS."
        case .wire: return "The raw total from your network hardware. Includes VPN overhead, and is the true load on your connection."
        }
    }
}

public enum PanelSection: String, Codable, CaseIterable, Identifiable, Sendable {
    case graph, health, breakdown, apps, destinations, watch
    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .graph: return "Speed graph"
        case .health: return "Connection health"
        case .breakdown: return "Traffic breakdown"
        case .apps: return "Apps"
        case .destinations: return "Destinations"
        case .watch: return "Watch alerts"
        }
    }
    public var symbol: String {
        switch self {
        case .graph: return "waveform.path.ecg"
        case .health: return "stethoscope"
        case .breakdown: return "square.split.2x1"
        case .apps: return "square.grid.2x2"
        case .destinations: return "globe"
        case .watch: return "eye"
        }
    }
}

public enum PanelWidth: String, Codable, CaseIterable, Identifiable, Sendable {
    case narrow, regular, wide
    public var id: String { rawValue }
    public var label: String { rawValue.capitalized }
    public var points: Double {
        switch self {
        case .narrow: return 320
        case .regular: return 380
        case .wide: return 480
        }
    }
}

public enum Density: String, Codable, CaseIterable, Identifiable, Sendable {
    case compact, comfortable
    public var id: String { rawValue }
    public var label: String { rawValue.capitalized }
}

public enum Palette: String, Codable, CaseIterable, Identifiable, Sendable {
    case classic, ocean, grape, graphite
    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .classic: return "Blue and orange"
        case .ocean: return "Teal and coral"
        case .grape: return "Violet and gold"
        case .graphite: return "Graphite"
        }
    }
}

public enum TimeRange: String, Codable, CaseIterable, Identifiable, Sendable {
    case live, hour, today, week, month
    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .live: return "Live"
        case .hour: return "1 hour"
        case .today: return "Today"
        case .week: return "7 days"
        case .month: return "30 days"
        }
    }
    public func start(now: Date, calendar: Calendar = .current) -> Date {
        switch self {
        case .live, .hour: return now.addingTimeInterval(-3600)
        case .today: return calendar.startOfDay(for: now)
        case .week: return now.addingTimeInterval(-7 * 86400)
        case .month: return now.addingTimeInterval(-30 * 86400)
        }
    }
}

public enum PanelPreset: String, CaseIterable, Identifiable, Sendable {
    case minimal, balanced, everything
    public var id: String { rawValue }
    public var label: String { rawValue.capitalized }
    public var summary: String {
        switch self {
        case .minimal: return "Speeds and your busiest apps."
        case .balanced: return "Graph, health, apps, destinations and alerts."
        case .everything: return "Every section and detail."
        }
    }
}

public struct Prefs: Codable, Equatable, Sendable {
    // Menu bar
    public var menuContent: MenuContent = .both
    public var menuLayout: MenuLayout = .stacked
    public var menuIndicator: MenuIndicator = .arrows
    public var menuColor: MenuColor = .monochrome
    public var menuTextSize: TextSize = .regular
    public var menuDecimals: Int = 1
    public var menuSparkline: Bool = false
    public var menuAlertDot: Bool = true
    /// "12.4 MB" rather than "12.4 MB/s".
    public var menuShortUnits: Bool = false
    /// Reserves room for any speed, so neighbouring icons never move, at the cost of width.
    public var menuFixedWidth: Bool = false
    /// Below this rate (bytes/s) the menu bar shows zero, so background chatter doesn't flicker.
    public var menuIdleThreshold: Double = 1000

    // Units and measure, shared by the menu bar and panel
    public var units: RateUnit = .bytes
    public var measure: Measure = .internet

    // Panel layout
    public var sectionOrder: [PanelSection] = PanelSection.allCases
    public var hiddenSections: Set<PanelSection> = [.breakdown]
    public var panelWidth: PanelWidth = .regular
    public var density: Density = .comfortable
    public var palette: Palette = .classic
    public var rowLimit: Int = 6
    public var graphSpan: Int = 300
    public var defaultRange: TimeRange = .live

    // Row details
    public var showIcons: Bool = true
    public var showBars: Bool = true
    public var showTrustBadges: Bool = true
    public var showCountry: Bool = true
    public var showHostnames: Bool = true
    public var showPorts: Bool = false
    public var showLatency: Bool = false
    public var showLocalInLists: Bool = true
    public var showVPNEnvelope: Bool = false

    // Data collection
    public var interval: Double = 1
    public var reverseDNS: Bool = true
    public var recordHistory: Bool = true
    public var retentionDays: Int = 30
    public var healthProbes: Bool = true
    public var pingTarget: String = "1.1.1.1"

    // Watch
    public var watchEnabled: Set<WatchKind> = Set(WatchKind.allCases)
    public var notifyKinds: Set<WatchKind> = []
    public var largeUploadMB: Int = 100
    public var idleUploadMB: Int = 20

    public init() {}

    public var detectorConfig: DetectorConfig {
        var c = DetectorConfig()
        c.enabled = watchEnabled
        // "New" means never seen before, which needs a saved record. With history off there
        // isn't one, so these would re-fire for everything after every launch.
        if !recordHistory {
            c.enabled.remove(.newApp)
            c.enabled.remove(.newDestination)
        }
        c.largeUploadBytes = UInt64(max(1, largeUploadMB)) * 1_000_000
        c.idleUploadBytes = UInt64(max(1, idleUploadMB)) * 1_000_000
        return c
    }

    public var visibleSections: [PanelSection] { sectionOrder.filter { !hiddenSections.contains($0) } }

    /// Applies a preset to the panel only, leaving menu bar choices and privacy settings alone.
    public mutating func apply(_ preset: PanelPreset) {
        switch preset {
        case .minimal:
            hiddenSections = [.graph, .health, .breakdown, .destinations, .watch]
            rowLimit = 5
            density = .compact
            showBars = false
            showTrustBadges = false
            showHostnames = false
            showCountry = false
            showPorts = false
            showLatency = false
            showVPNEnvelope = false
        case .balanced:
            hiddenSections = [.breakdown]
            rowLimit = 6
            density = .comfortable
            showBars = true
            showTrustBadges = true
            showHostnames = true
            showCountry = true
            showPorts = false
            showLatency = false
            showVPNEnvelope = false
        case .everything:
            hiddenSections = []
            rowLimit = 15
            density = .comfortable
            showBars = true
            showTrustBadges = true
            showHostnames = true
            showCountry = true
            showPorts = true
            showLatency = true
            showVPNEnvelope = true
        }
    }

    /// Decodes saved settings over the defaults. A setting added in a later version takes
    /// its default rather than making the whole saved file fail to load.
    public static func decode(_ data: Data) -> Prefs {
        guard let saved = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let defaultsData = try? JSONEncoder().encode(Prefs()),
            var merged = try? JSONSerialization.jsonObject(with: defaultsData) as? [String: Any]
        else { return Prefs() }
        for (key, value) in saved { merged[key] = value }
        guard let mergedData = try? JSONSerialization.data(withJSONObject: merged),
            var prefs = try? JSONDecoder().decode(Prefs.self, from: mergedData)
        else { return Prefs() }
        // A section added in a later version joins the end of a customised order.
        for section in PanelSection.allCases where !prefs.sectionOrder.contains(section) {
            prefs.sectionOrder.append(section)
        }
        return prefs
    }
}
