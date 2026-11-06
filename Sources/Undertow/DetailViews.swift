import AppKit
import SwiftUI
import UndertowCore

struct BackBar: View {
    @EnvironmentObject var store: AppStore

    var body: some View {
        HStack(spacing: 6) {
            Button {
                store.route = .home
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: "chevron.left").font(.system(size: 11, weight: .semibold))
                    Text("Back").font(.system(size: 12))
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.accentColor)
            .keyboardShortcut(.cancelAction)
            Spacer()
            RangePicker()
        }
        .padding(.top, 12)
        .padding(.bottom, 4)
    }
}

struct InfoRow: View {
    let label: String
    let value: String
    var tint: Color? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label).font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 70, alignment: .leading)
            Text(value)
                .font(.system(size: 11))
                .foregroundStyle(tint ?? .primary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }
}

// MARK: - App

struct AppDetailView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.theme) var theme
    let appID: String

    private var live: LiveApp? { store.detail.apps.first { $0.id == appID } }
    private var saved: HistoryRow? { store.historyApps.first { $0.id == appID } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            BackBar()
            header
            if let live, store.range == .live {
                identity(live)
                connections(live)
            } else {
                if let live { identity(live) }
                savedDestinations
            }
            actions
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            let path = live?.identity.path ?? saved?.path
            AppIcon(path: path, kind: live?.identity.kind ?? AppIcon.kind(id: appID, path: path), size: 32)
            VStack(alignment: .leading, spacing: 1) {
                Text(live?.identity.name ?? saved?.name ?? appID)
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(1)
                if let live, store.range == .live {
                    RatePair(down: live.down, up: live.up, aligned: false)
                } else if let saved {
                    TotalPair(rx: saved.rx, tx: saved.tx, aligned: false)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func identity(_ app: LiveApp) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if app.verifiedTunnel {
                Text("VPN tunnel, verified by its Apple-granted VPN entitlement. Its outer connection is the encrypted envelope around your other apps' data, so it isn't counted again.")
                    .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).padding(.bottom, 2)
            }
            if app.identity.impersonatesApple(signer: app.signer) {
                InfoRow(label: "Warning", value: "This app uses an Apple app ID, but Apple didn't sign it. Its name may not be genuine.", tint: .orange)
            }
            if let why = app.identity.explanation {
                Text(why).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).padding(.bottom, 2)
            }
            if app.signerPending {
                InfoRow(label: "Signed by", value: "Checking…")
            }
            if let s = app.signer {
                InfoRow(label: "Signed by", value: s.organisation ?? s.status.label, tint: s.status.isSuspicious ? .orange : nil)
                if s.status.isSuspicious, s.organisation != nil {
                    InfoRow(label: "Status", value: s.status.label, tint: .orange)
                }
            }
            if let launcher = app.identity.launchedBy {
                InfoRow(label: "Started by", value: launcher)
            }
            if let path = app.identity.path {
                InfoRow(label: "Location", value: path)
            }
            InfoRow(label: "This session", value: "↓ \(Format.bytes(app.totalDown))   ↑ \(Format.bytes(app.totalUp))")
            if let first = store.monitor.ledger?.firstSeen(app: app.id) {
                InfoRow(label: "First seen", value: first.formatted(date: .abbreviated, time: .shortened))
            }
        }
    }

    @ViewBuilder private func connections(_ app: LiveApp) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            SectionTitle(title: "Connections") {
                Text("\(app.connections.count)")
            }
            if app.connections.isEmpty { EmptyHint(text: "No recent connections.") }
            ForEach(app.connections) { conn in
                HoverRow(action: { store.route = .destination(conn.destination.key); store.refreshHistory() }) {
                    ConnectionRow(conn: conn)
                }
            }
        }
    }

    @ViewBuilder private var savedDestinations: some View {
        VStack(alignment: .leading, spacing: 2) {
            SectionTitle(title: "Destinations, \(store.range == .live ? TimeRange.hour.label : store.range.label)")
            if store.historyAppDestinations.isEmpty { EmptyHint(text: "Nothing recorded for this period.") }
            ForEach(store.historyAppDestinations) { row in
                HoverRow(action: { store.route = .destination(row.id); store.refreshHistory() }) {
                    HStack {
                        DestinationName(label: row.name, countryCode: row.countryCode, subtitle: row.subtitle, isLocal: row.cls == .local)
                        Spacer(minLength: 4)
                        TotalPair(rx: row.rx, tx: row.tx)
                    }
                }
            }
        }
    }

    private var actions: some View {
        let path = live?.identity.path ?? saved?.path
        let trusted = live?.trusted ?? false
        return HStack(spacing: 12) {
            if appID != "exited" {
                Button(trusted ? "Stop trusting" : "Trust this app") { store.setTrusted(appID: appID, !trusted) }
                    .help("A trusted app raises no Watch alerts while it's signed the same way. If its signature changes, alerts resume.")
            }
            if let path, FileManager.default.fileExists(atPath: path) {
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
            }
        }
        .buttonStyle(.plain)
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(Color.accentColor)
    }
}

struct ConnectionRow: View {
    @EnvironmentObject var store: AppStore
    let conn: LiveConnection

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 8) {
                DestinationName(label: conn.destination.label, countryCode: conn.destination.countryCode, subtitle: nil, isLocal: conn.cls == .local)
                if conn.outsideVPN {
                    Image(systemName: "lock.open.fill").font(.system(size: 9)).foregroundStyle(.orange).help("Not going through your VPN")
                }
                Spacer(minLength: 4)
                RatePair(down: conn.down, up: conn.up)
            }
            if !subtitle.isEmpty {
                Text(subtitle).font(.system(size: 10).monospacedDigit()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
        }
    }

    private var subtitle: String {
        var parts: [String] = []
        if store.prefs.showHostnames, let host = conn.destination.hostname {
            parts.append(host)
        } else if let ip = conn.remoteIP {
            parts.append(ip)
        }
        let service = Format.serviceName(port: conn.remotePort, proto: conn.proto)
        if store.prefs.showPorts {
            if let port = conn.remotePort { parts.append("\(conn.proto.rawValue) \(port)") }
            if let iface = conn.interface { parts.append(iface) }
        } else if let service {
            parts.append(service)
        }
        if store.prefs.showLatency, let rtt = conn.rttMs { parts.append("\(Int(rtt)) ms") }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Destination

struct DestinationDetailView: View {
    @EnvironmentObject var store: AppStore
    let key: String

    private var live: LiveDestination? { store.detail.destinations.first { $0.id == key } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            BackBar()
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    let flag = OwnerNames.flag(live?.destination.countryCode)
                    if !flag.isEmpty { Text(flag).font(.system(size: 15)) }
                    Text(live?.destination.label ?? Self.label(for: key))
                        .font(.system(size: 15, weight: .semibold))
                        .lineLimit(2)
                }
                if let live, store.range == .live { RatePair(down: live.down, up: live.up, aligned: false) }
            }
            if let live {
                VStack(alignment: .leading, spacing: 4) {
                    if let raw = live.destination.rawOwner { InfoRow(label: "Network", value: raw) }
                    if let asn = live.destination.asn { InfoRow(label: "ASN", value: "AS\(asn)") }
                    if let cc = live.destination.countryCode { InfoRow(label: "Registered", value: Self.countryName(cc)) }
                    if !live.ips.isEmpty {
                        InfoRow(label: live.ips.count == 1 ? "Address" : "Addresses", value: live.ips.prefix(8).joined(separator: "\n") + (live.ips.count > 8 ? "\n+\(live.ips.count - 8) more" : ""))
                    }
                    if !live.hostnames.isEmpty { InfoRow(label: "Hostnames", value: live.hostnames.prefix(5).joined(separator: "\n")) }
                    InfoRow(label: "This session", value: "↓ \(Format.bytes(live.totalDown))   ↑ \(Format.bytes(live.totalUp))")
                }
                if key == "unconnected" {
                    Text("These UDP sockets don't connect to one address, so macOS can't report where the data goes. Video calls and games commonly work this way.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            appsList
            if live?.destination.countryCode != nil {
                Text("Country is where the network is registered, which isn't always where the server is.")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder private var appsList: some View {
        VStack(alignment: .leading, spacing: 2) {
            SectionTitle(title: "Who's talking to it")
            if store.range == .live, let live {
                ForEach(store.detail.apps.filter { live.appIDs.contains($0.id) }) { app in
                    let relevant = app.connections.filter { $0.destination.key == key }
                    HoverRow(action: { store.route = .app(app.id); store.refreshHistory() }) {
                        HStack(spacing: 8) {
                            AppIcon(path: app.identity.path, kind: app.identity.kind)
                            Text(app.identity.name).font(.system(size: 12)).lineLimit(1)
                            Spacer(minLength: 4)
                            RatePair(down: relevant.reduce(0) { $0 + $1.down }, up: relevant.reduce(0) { $0 + $1.up })
                        }
                    }
                }
            } else {
                if store.historyDestinationApps.isEmpty { EmptyHint(text: "Nothing recorded for this period.") }
                ForEach(store.historyDestinationApps) { row in
                    HoverRow(action: { store.route = .app(row.id); store.refreshHistory() }) {
                        HStack(spacing: 8) {
                            AppIcon(path: row.path, kind: AppIcon.kind(id: row.id, path: row.path))
                            Text(row.name).font(.system(size: 12)).lineLimit(1)
                            Spacer(minLength: 4)
                            TotalPair(rx: row.rx, tx: row.tx)
                        }
                    }
                }
            }
        }
    }

    private static func label(for key: String) -> String {
        if key == "unconnected" { return "Unknown (no fixed destination)" }
        if key == "discovery" { return "Local network discovery" }
        guard let colon = key.firstIndex(of: ":") else { return key }
        return String(key[key.index(after: colon)...])
    }

    private static func countryName(_ code: String) -> String {
        Locale.current.localizedString(forRegionCode: code) ?? code
    }
}
