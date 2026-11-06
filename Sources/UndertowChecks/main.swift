import Foundation
import UndertowCore

// A plain test runner, because the Command Line Tools don't include XCTest.

var failures = 0
var passes = 0

func check(_ condition: @autoclosure () -> Bool, _ name: String, line: Int = #line) {
    if condition() {
        passes += 1
    } else {
        failures += 1
        print("FAIL line \(line): \(name)")
    }
}

func row(gen: UInt64, remote: String? = "1.2.3.4", port: Int? = 443, local: String? = "192.168.0.2", localPort: Int? = 50000,
         proto: TransportProto = .tcp, rx: UInt64 = 0, tx: UInt64 = 0, pid: Int32 = 100, epid: Int32 = 0) -> SocketRow {
    SocketRow(gen: gen, proto: proto, localIP: local, localPort: localPort, remoteIP: remote, remotePort: port,
              state: "ESTABLISHED", rx: rx, tx: tx, pid: pid, epid: epid)
}

func identity(_ name: String, kind: AppKind = .app, browser: Bool = false, id: String? = nil, bundle: String? = nil) -> AppIdentity {
    AppIdentity(id: id ?? "com.test.\(name)", name: name, kind: kind, path: "/Applications/\(name).app", executable: nil,
                bundleID: kind == .system ? nil : (bundle ?? "com.test.\(name)"), explanation: nil,
                claimsBrowser: browser, launchedBy: nil)
}

// MARK: netstat, using real lines captured from macOS 13

let netstatSample = """
Active Internet connections (including servers)
Proto Recv-Q Send-Q  Local Address          Foreign Address        (state)        rxbytes    txbytes  rhiwat  shiwat    pid   epid state  options           gencnt    flags   flags1 usscnt rtncnt fltrs
tcp4       0 131072  10.8.0.2.55510         203.0.113.10.443      ESTABLISHED       6775    9706264  131072  131072    631      0 00102 00000008 0000000000138360 00000080 00000900      1      0 00000
udp4       0      0  10.8.0.2.57530         203.0.113.20.443                     51533      10170 1048576   29040    631      0 00102 00000000 00000000001371e8 00000000 04200800      1      0 00000
udp4       0      0  *.5353                 *.*                                      2439       2336  786896    9216    457      0 00100 00000200 000000000013694e 00000001 00000800      1      0 00000
tcp4       0      0  192.168.1.5.57471     192.168.1.2.548       ESTABLISHED 186198288879 12273599387 4194240 2398336      0      0 00082 00000000 00000000000d1883 00000080 00000900      1      0 00000
tcp6       0      0  ::1.58722              ::1.9100               ESTABLISHED        118     124080  407754  146808  47214      0 00102 00000008 00000000000db310 00000080 00000800      1      0 00000
tcp6       0      0  2a00:1450:4009::1%en0.5228  2607:f8b0::a.443  ESTABLISHED        10         20  407754  146808  47214    999 00102 00000008 00000000000db311 00000080 00000800      1      0 00000
tcp4       0      0  192.168.1.5.61811     192.168.1.2.445       TIME_WAIT           52        220  131768  131768    453      0 02031 00000000 0000000000138966 00000080 00000900      1      0 00000
garbage line that should be skipped
tcp4 not enough columns
udp4       0      0  *.9999                 *.*                                         0          0  786896    9216    457      0 00100 00000200 000000000013694f 00000001 00000800      1      0 00000
tcp4       0      0  *.8185                 *.*                    LISTEN               0          0  131072  131072    457      0 00100 00000200 0000000000136950 00000001 00000800      1      0 00000
ffffffa3 stream      0      0 ffffffa3 0 0 0 /var/run/mDNSResponder
"""
let parsed = NetstatParser.parse(netstatSample)
check(parsed.count == 7, "parses active sockets, skips junk, Unix sockets and idle sockets (got \(parsed.count))")
check(parsed[0].proto == .tcp && parsed[0].remoteIP == "203.0.113.10" && parsed[0].remotePort == 443, "tcp remote")
check(parsed[0].tx == 9706264 && parsed[0].rx == 6775 && parsed[0].pid == 631, "tcp counters and pid")
check(parsed[0].gen == 0x138360, "gencnt parsed as hex")
check(parsed[1].proto == .udp && parsed[1].rx == 51533 && parsed[1].tx == 10170 && parsed[1].pid == 631, "udp columns aren't offset by the blank state")
check(parsed[2].remoteIP == nil && parsed[2].remotePort == nil && parsed[2].localIP == nil && parsed[2].localPort == 5353, "wildcard endpoints")
check(parsed[3].rx == 186198288879, "large counters")
check(parsed[3].pid == 0, "kernel-owned socket")
check(parsed[4].remoteIP == "::1" && parsed[4].remotePort == 9100, "ipv6 remote")
check(parsed[5].localIP == "2a00:1450:4009::1", "ipv6 zone stripped")
check(parsed[5].ownerPID == 999, "epid wins for delegated sockets")
check(parsed[6].state == "TIME_WAIT", "closed sockets still visible")

// MARK: Delta tracking

let tracker = FlowTracker()
check(tracker.ingest([row(gen: 1, rx: 1_000_000_000, tx: 5_000_000_000)]).isEmpty, "first sample is a baseline, so no spike at launch")
var deltas = tracker.ingest([row(gen: 1, rx: 1_000_000_100, tx: 5_000_000_050), row(gen: 2, rx: 700, tx: 30)])
check(deltas.count == 2, "existing + new socket")
check(deltas.first { $0.row.gen == 1 }?.rx == 100 && deltas.first { $0.row.gen == 1 }?.tx == 50, "existing socket counts only the change")
check(deltas.first { $0.row.gen == 2 }?.rx == 700, "a new socket counts all its bytes")
deltas = tracker.ingest([row(gen: 1, rx: 1_000_000_100, tx: 5_000_000_050)])
check(deltas.isEmpty, "idle socket produces nothing")
deltas = tracker.ingest([row(gen: 1, rx: 5, tx: 5)])
check(deltas.isEmpty, "counter going backwards doesn't underflow")
deltas = tracker.ingest([row(gen: 2, rx: 10, tx: 10), row(gen: 2, rx: 10, tx: 10)])
check(deltas.count == 1, "a socket listed twice (dual-stack) counts once")

// Real rows from Network framework connections, which all report a gencnt of zero.
let zeroGen = NetstatParser.parse("""
tcp4       0      0  10.8.0.2.62083         203.0.113.30.443    ESTABLISHED       2842    1349909  131072  188416  49912  49912 00102 00000000 0000000000000000 00000080 00000900      1      0 00000
tcp4       0      0  10.8.0.2.62090         203.0.113.30.443    ESTABLISHED       1000     500000  131072  188416  49913  49913 00102 00000000 0000000000000000 00000080 00000900      1      0 00000
tcp4       0      0  10.8.0.2.61756         203.0.113.40.443       ESTABLISHED       4000      27066  131072  188416    453    453 00102 00000000 0000000000000000 00000080 00000900      1      0 00000
""")
check(zeroGen.count == 3 && zeroGen.allSatisfy { $0.gen == 0 }, "these rows really do have no generation count")
check(Set(zeroGen.map(\.key)).count == 3, "BUG: connections with no generation count must stay separate")
let zt = FlowTracker()
_ = zt.ingest([])
var zd = zt.ingest(zeroGen)
check(zd.count == 3 && zd.map(\.tx).reduce(0, +) == 1349909 + 500000 + 27066, "BUG: every such connection is counted, not just the first (got \(zd.count))")
func bump(_ r: SocketRow, _ extra: UInt64) -> SocketRow { var c = r; c.tx += extra; return c }
zd = zt.ingest([bump(zeroGen[0], 100), bump(zeroGen[1], 200), zeroGen[2]])
check(zd.count == 2 && zd.first { $0.row.pid == 49912 }?.tx == 100 && zd.first { $0.row.pid == 49913 }?.tx == 200, "BUG: each one is tracked independently over time")
zd = zt.ingest([{ var c = zeroGen[2]; c.tx = 50; c.rx = 10; return c }()])
check(zd.isEmpty, "a counter that dips isn't counted again")
zd = zt.ingest([bump(zeroGen[2], 5)])
check(zd.first?.tx == 5, "counting resumes from the highest value seen")
let mixed = FlowTracker()
_ = mixed.ingest([])
check(mixed.ingest([row(gen: 7, tx: 10), zeroGen[0]]).count == 2, "both kinds of socket work side by side")
check(row(gen: 7).key == .generation(7), "a generation count is still preferred when present")

// MARK: IP scope

check(IP.scope(of: "127.0.0.1") == .loopback && IP.scope(of: "::1") == .loopback, "loopback")
for ip in ["10.8.0.1", "172.16.0.1", "172.31.255.1", "192.168.1.2", "169.254.1.1", "100.64.0.1", "224.0.0.251", "fe80::1", "fd00::1", "ff02::fb"] {
    check(IP.scope(of: ip) == .local, "\(ip) is local")
}
for ip in ["8.8.8.8", "172.32.0.1", "172.15.0.1", "100.128.0.1", "203.0.113.10", "2a00:1450:4009::1"] {
    check(IP.scope(of: ip) == .publicNet, "\(ip) is public")
}

// MARK: Classification

func cls(_ r: SocketRow, tunnel: Bool = false, up: Bool = true, onTunnel: Bool = false, system: Bool = false) -> FlowClass {
    FlowClassifier.classify(r, isVerifiedTunnel: tunnel, tunnelActive: up, onTunnelInterface: onTunnel, isVerifiedSystem: system)
}
check(cls(row(gen: 1)) == .internet, "public = internet")
check(cls(row(gen: 1, remote: "192.168.1.2")) == .local, "NAS = local")
check(cls(row(gen: 1, remote: "127.0.0.1", local: "127.0.0.1")) == .ignored, "loopback ignored")
check(cls(row(gen: 1), tunnel: true) == .envelope, "a verified VPN's outer socket isn't counted twice")
check(cls(row(gen: 1), tunnel: true, onTunnel: true) == .internet, "the VPN app's own calls through its tunnel still count")
check(cls(row(gen: 1), tunnel: true, up: false) == .internet, "no tunnel up means nothing to be an envelope for")
check(cls(row(gen: 1), tunnel: false) == .internet, "ATTACK: an app merely claiming to be a VPN stays visible")
let udpOn = { (port: Int) in row(gen: 1, remote: nil, port: nil, local: nil, localPort: port, proto: .udp) }
check(cls(udpOn(5353), system: true) == .local, "macOS mDNS is local")
check(cls(udpOn(1900)) == .internet && cls(udpOn(57621)) == .internet, "ATTACK: any other app on a discovery port stays visible")
check(cls(udpOn(40000)) == .internet, "unconnected UDP must not vanish, since it could be a hidden sender")

// MARK: Routes, using a real table with a VPN up

let routes = RouteParser.parse("""
Routing tables

Internet:
Destination        Gateway            Flags           Netif Expire
default            link#22            UCSg            utun3
default            192.168.0.1        UGScIg            en0
""")
check(routes.defaultInterface == "utun3" && routes.vpnActive, "VPN holds the default route")
check(routes.physicalGateway == "192.168.0.1" && routes.physicalInterface == "en0", "real router is still found behind the VPN")
let plain = RouteParser.parse("default            192.168.0.1        UGScg            en0")
check(!plain.vpnActive && plain.physicalGateway == "192.168.0.1", "no VPN")

// MARK: nettop and ping

let quality = NettopParser.parse("""
,bytes_out,re-tx,rtt_avg,
kernel_task.0,25486901636,2403241,,
tcp4 192.168.1.5:57471<->192.168.1.2:548,11518143228,1495448,1.22 ms,
tcp4 10.8.0.2:61756<->203.0.113.40:443,26908,0,68.84 ms,
tcp6 2a00::1.5000<->2607:f8b0::a.443,100,5,12.50 ms,
tcp6 *.8185<->*.*,,,,
""")
check(quality["203.0.113.40|443"]?.rttMs == 68.84, "ipv4 rtt keyed by remote")
check(quality["192.168.1.2|548"]?.retransmitted == 1495448, "retransmits")
check(quality["2607:f8b0::a|443"]?.rttMs == 12.5, "ipv6 uses a dot before the port")
check(PingParser.parse("round-trip min/avg/max/stddev = 14.2/15.5/16.0/0.1 ms") == 15.5, "ping average")
check(PingParser.parse("1 packets transmitted, 0 packets received, 100.0% packet loss") == nil, "no reply = nil")

// MARK: Formatting

check(Format.rate(0) == "0 B/s", "zero")
check(Format.rate(999) == "999 B/s", "bytes have no decimals")
check(Format.rate(1500) == "1.5 KB/s", "KB")
check(Format.rate(150_000) == "150 KB/s", "large KB drops decimals so width stays stable")
check(Format.rate(12_400_000) == "12.4 MB/s", "MB")
check(Format.rate(1_000_000, unit: .bits) == "8.0 Mbps", "bits")
check(Format.rate(999_999) == "1.0 MB/s", "rounds up to the next unit instead of '1000 KB'")
check(Format.rate(-5) == "0 B/s", "never negative")
check(Format.bytes(1_500_000_000) == "1.5 GB", "total bytes")
check(Format.tightRate(8_880_000, decimals: 2) == "8.88 MB/s", "tight: two decimals under 10")
check(Format.tightRate(12_400_000, decimals: 2) == "12.4 MB/s", "tight: three significant digits (got \(Format.tightRate(12_400_000, decimals: 2)))")
check(Format.tightRate(123_400_000, decimals: 2) == "123 MB/s", "tight: no decimals over 100")
check(Format.tightRate(99_970_000, decimals: 1) == "100 MB/s", "tight: rounding up doesn't add a digit (got \(Format.tightRate(99_970_000, decimals: 1)))")
check(Format.tightRate(9_999_000, decimals: 2) == "10.0 MB/s", "tight: rounding at the 10 boundary (got \(Format.tightRate(9_999_000, decimals: 2)))")
check(Format.tightRate(2_240, decimals: 0) == "2 KB/s", "tight: respects fewer decimals")
check(Format.tightRate(606, decimals: 2) == "606 B/s", "tight: plain bytes have no decimals")
check(Format.tightRate(12_400_000, short: true) == "12.4 MB", "tight: short units")
check(Format.tightRate(1_000_000, unit: .bits, short: true) == "8.0 Mb", "tight: short bits")
var sticky = StickyWidth(hold: 20)
let w0 = Date(timeIntervalSince1970: 1000)
check(sticky.update(needed: 40, now: w0) == 40, "sticky: starts at what's needed")
check(sticky.update(needed: 48, now: w0.addingTimeInterval(1)) == 48, "sticky: grows at once, so text never clips")
check(sticky.update(needed: 40, now: w0.addingTimeInterval(5)) == 48, "sticky: holds when the need drops")
check(sticky.update(needed: 40, now: w0.addingTimeInterval(20)) == 48, "sticky: still holding just before the limit")
check(sticky.update(needed: 40, now: w0.addingTimeInterval(21)) == 40, "sticky: shrinks after the hold")
_ = sticky.update(needed: 48, now: w0.addingTimeInterval(30))
_ = sticky.update(needed: 40, now: w0.addingTimeInterval(45))
check(sticky.update(needed: 48, now: w0.addingTimeInterval(46)) == 48 && sticky.update(needed: 40, now: w0.addingTimeInterval(60)) == 48, "sticky: a new peak restarts the hold")
check(DragReorder.targetIndex(start: 1, translation: 0, rowHeight: 34, count: 6) == 1, "drag: no movement")
check(DragReorder.targetIndex(start: 1, translation: 16, rowHeight: 34, count: 6) == 1, "drag: under halfway stays")
check(DragReorder.targetIndex(start: 1, translation: 18, rowHeight: 34, count: 6) == 2, "drag: past halfway swaps")
check(DragReorder.targetIndex(start: 2, translation: -40, rowHeight: 34, count: 6) == 1, "drag: upward")
check(DragReorder.targetIndex(start: 1, translation: -500, rowHeight: 34, count: 6) == 0, "drag: clamps at the top")
check(DragReorder.targetIndex(start: 4, translation: 500, rowHeight: 34, count: 6) == 5, "drag: clamps at the bottom")
check(DragReorder.moved([1, 2, 3, 4], from: 0, to: 2) == [2, 3, 1, 4], "drag: move down")
check(DragReorder.moved([1, 2, 3, 4], from: 3, to: 1) == [1, 4, 2, 3], "drag: move up")
check(DragReorder.moved([1, 2], from: 5, to: 0) == [1, 2], "drag: bad index is ignored")
check(Sanitize.displayText("gnp\u{202E}exe.app") == "gnpexe.app", "right-to-left override removed")
check(Sanitize.displayText("Sp\u{200B}otify\nX") == "SpotifyX", "invisible characters and newlines removed")
check(Sanitize.displayText("日本語 Café") == "日本語 Café", "ordinary international text is kept")
check(Sanitize.displayText(String(repeating: "a", count: 5000)).count == 200, "length capped")
check(Sanitize.isPlausibleHostname("edge-1.example.co.uk") && !Sanitize.isPlausibleHostname("1.2.3.4"), "hostname shape")
check(!Sanitize.isPlausibleHostname("evil\u{202E}.com") && !Sanitize.isPlausibleHostname("localhost"), "hostname rejects tricks and bare names")
check(ReverseDNS.confirms(ip: "1.2.3.4", name: "a.example.com", forwardAddresses: ["9.9.9.9", "1.2.3.4"]), "forward lookup leads back")
check(!ReverseDNS.confirms(ip: "6.6.6.6", name: "www.apple.com", forwardAddresses: ["17.253.144.10"]), "ATTACK: a server can't pose as apple.com via its reverse DNS")
check(!ReverseDNS.confirms(ip: "6.6.6.6", name: "x.example.com", forwardAddresses: []), "no forward answer means no name")
var ring = RingBuffer<Int>(capacity: 3, filler: 0)
ring.append(1); ring.append(2)
check(ring.values() == [1, 2], "ring partial")
ring.append(3); ring.append(4)
check(ring.values() == [2, 3, 4], "ring wraps, oldest first")
check(ring.values(last: 2) == [3, 4], "ring tail")

// MARK: Owner names, using real table entries

check(OwnerNames.clean("AMAZON-02 - Amazon.com, Inc.") == "Amazon", "amazon")
check(OwnerNames.clean("CLOUDFLARENET-UK Cloudflare Inc") == "Cloudflare", "cloudflare variant folds to one brand")
check(OwnerNames.clean("GOOGLE CLOUD NETWORKING - Google Access LLC") == "Google", "google")
check(OwnerNames.clean("AKAMAI-ASN1 Akamai International B.V.") == "Akamai", "akamai")
check(OwnerNames.clean("GTELECOM-AS-AP - Gtelecom Pty Ltd") == "Gtelecom", "strips handle and suffixes (got \(OwnerNames.clean("GTELECOM-AS-AP - Gtelecom Pty Ltd")))")
check(OwnerNames.clean("EXAMPLE-AS EXAMPLE NETWORKS LIMITED") == "Example Networks", "tones down caps (got \(OwnerNames.clean("EXAMPLE-AS EXAMPLE NETWORKS LIMITED")))")
check(OwnerNames.flag("US") == "🇺🇸" && OwnerNames.flag("None") == "" && OwnerNames.flag(nil) == "", "flags")

// MARK: Identity rules

check(IdentityRules.outermostApp(in: "/Applications/Brave Browser.app/Contents/Frameworks/Brave Browser Framework.framework/Helpers/Brave Browser Helper.app/Contents/MacOS/Brave Browser Helper") == "/Applications/Brave Browser.app", "helpers fold into the main app")
check(IdentityRules.outermostApp(in: "/usr/bin/curl") == nil, "loose binary")
check(IdentityRules.claimsBrowser(bundleID: "com.google.Chrome.helper") && !IdentityRules.claimsBrowser(bundleID: "com.spotify.client"), "browser detection")
let vpnKey = "com.apple.developer.networking.networkextension"
check(CodeSigning.grantsPacketTunnel([vpnKey: ["packet-tunnel-provider-systemextension"]]), "the real entitlement Proton's extension carries")
check(CodeSigning.grantsPacketTunnel([vpnKey: ["packet-tunnel-provider"]]), "app extension form of it")
check(!CodeSigning.grantsPacketTunnel([vpnKey: ["content-filter-provider"]]) && !CodeSigning.grantsPacketTunnel(nil), "other entitlements aren't a VPN")
check(CodeSigning.organisationName(fromCertificateSummary: "Developer ID Application: Spotify (2FNC3A47ZF)") == "Spotify", "organisation name")

// MARK: Signatures, checked against real files on this Mac

check(CodeSigning.inspect(path: "/usr/bin/curl").status == .apple, "curl is signed by Apple")
check(CodeSigning.inspect(path: "/usr/bin/curl").trustKey == "apple", "Apple's trust key")
let sigDir = NSTemporaryDirectory() + "undertow-sig-\(UUID().uuidString)"
try! FileManager.default.createDirectory(atPath: sigDir, withIntermediateDirectories: true)
check(CodeSigning.inspect(path: sigDir + "/missing").status.isSuspicious, "a deleted binary counts as suspicious")
try! Data("#!/bin/sh\n".utf8).write(to: URL(fileURLWithPath: sigDir + "/plain"))
check(CodeSigning.inspect(path: sigDir + "/plain").status.isSuspicious, "an unsigned file counts as suspicious")
try? FileManager.default.removeItem(atPath: sigDir)
check(SignerInfo(status: .developerID, teamID: "T1", codeHash: "aa").trustKey == "team:T1", "trust follows a verified developer across updates")
check(SignerInfo(status: .adHoc, codeHash: "aa").trustKey == "code:aa", "trust in an unverified app covers only that exact build")
check(SignerInfo(status: .invalid, codeHash: "aa").trustKey == nil, "tampered code can't be trusted")
check(SignerInfo(status: .unsigned).trustKey == nil, "nothing to tie trust to")
for bad in [SignerStatus.development, .untrustedCertificate, .adHoc, .unsigned, .invalid, .unknown] {
    check(bad.isSuspicious && !bad.isVerified, "\(bad) isn't verified")
}

// MARK: Detector

let t0 = Date(timeIntervalSince1970: 1_800_000_000)
func detector(installed: Date = t0.addingTimeInterval(-200_000), known: Set<String> = [], pairs: Set<String> = [], trusted: [String: String] = [:]) -> Detector {
    Detector(config: DetectorConfig(), installDate: installed, knownApps: known, knownPairs: pairs, trusted: trusted)
}
func flow(_ app: AppIdentity, tx: UInt64 = 0, rx: UInt64 = 0, dest: String = "Amazon", signer: SignerInfo? = nil, cls: FlowClass = .internet, outside: Bool = false) -> ObservedFlow {
    ObservedFlow(app: app, signer: signer, cls: cls, destination: dest, rx: rx, tx: tx, outsideVPN: outside)
}

var d = detector()
var ev = d.observe(flow(identity("Spy")), now: t0, idleSeconds: 0)
check(ev.contains { $0.kind == .newApp }, "unknown app raises newApp")
ev = d.observe(flow(identity("Spy")), now: t0, idleSeconds: 0)
check(!ev.contains { $0.kind == .newApp }, "only once")
check(d.drainBaselineUpdates().apps.count == 1, "new app is queued for saving")

d = detector(installed: t0)
ev = d.observe(flow(identity("Existing")), now: t0.addingTimeInterval(3600), idleSeconds: 0)
check(ev.isEmpty, "learning period doesn't flag apps you already use")
check(d.learningRemaining(now: t0.addingTimeInterval(3600)) > 0, "still learning")

d = detector(known: ["system:x"])
ev = d.observe(flow(identity("x", kind: .system, id: "system:x"), tx: 1_000_000, signer: SignerInfo(status: .unsigned)), now: t0, idleSeconds: 0)
check(!ev.contains { $0.kind == .unsignedSender }, "macOS services aren't flagged as unsigned")

let tool = identity("tool")
d = detector(known: [tool.id])
ev = d.observe(flow(tool, tx: 10, signer: SignerInfo(status: .unsigned)), now: t0, idleSeconds: 0)
check(ev.contains { $0.kind == .unsignedSender }, "unsigned sender flagged")
ev = d.observe(flow(tool, tx: 10, signer: SignerInfo(status: .unsigned)), now: t0.addingTimeInterval(60), idleSeconds: 0)
check(!ev.contains { $0.kind == .unsignedSender }, "cooldown stops repeats")
ev = d.observe(flow(tool, rx: 500, signer: SignerInfo(status: .unsigned)), now: t0.addingTimeInterval(90_000), idleSeconds: 0)
check(!ev.contains { $0.kind == .unsignedSender }, "receiving alone doesn't count as sending")

let uploader = identity("Uploader")
d = detector(known: [uploader.id], pairs: ["\(uploader.id)|Amazon"])
ev = d.observe(flow(uploader, tx: 60_000_000), now: t0, idleSeconds: 0)
check(!ev.contains { $0.kind == .largeUpload }, "below threshold")
ev = d.observe(flow(uploader, tx: 60_000_000), now: t0.addingTimeInterval(120), idleSeconds: 0)
check(ev.contains { $0.kind == .largeUpload && $0.detail.contains("Amazon") }, "rolling window crosses threshold and names the destination")
ev = d.observe(flow(uploader, tx: 200_000_000), now: t0.addingTimeInterval(180), idleSeconds: 0)
check(!ev.contains { $0.kind == .largeUpload }, "cooldown")

d = detector(known: [uploader.id], pairs: ["\(uploader.id)|Amazon"])
_ = d.observe(flow(uploader, tx: 60_000_000), now: t0, idleSeconds: 0)
ev = d.observe(flow(uploader, tx: 60_000_000), now: t0.addingTimeInterval(1200), idleSeconds: 0)
check(!ev.contains { $0.kind == .largeUpload }, "uploads outside the 10 minute window don't add up")

d = detector(known: [uploader.id], pairs: ["\(uploader.id)|Amazon"])
ev = d.observe(flow(uploader, tx: 25_000_000), now: t0, idleSeconds: 10)
check(!ev.contains { $0.kind == .idleUpload }, "not idle")
ev = d.observe(flow(uploader, tx: 15_000_000), now: t0.addingTimeInterval(1), idleSeconds: 600)
check(!ev.contains { $0.kind == .idleUpload }, "only bytes sent while idle count toward the idle rule")
ev = d.observe(flow(uploader, tx: 15_000_000), now: t0.addingTimeInterval(2), idleSeconds: 600)
check(ev.contains { $0.kind == .idleUpload }, "idle upload flagged")

d = detector(known: [uploader.id])
ev = d.observe(flow(uploader, tx: 50_000, dest: "Tencent"), now: t0, idleSeconds: 0)
check(!ev.contains { $0.kind == .newDestination }, "small requests to a new place are ignored")
ev = d.observe(flow(uploader, tx: 60_000, dest: "Tencent"), now: t0, idleSeconds: 0)
check(ev.contains { $0.kind == .newDestination && $0.detail.contains("Tencent") }, "new destination once enough data has gone there")
ev = d.observe(flow(uploader, tx: 600_000, dest: "Tencent"), now: t0, idleSeconds: 0)
check(!ev.contains { $0.kind == .newDestination }, "only the first time")

let browser = identity("Browser", browser: true)
d = detector(known: [browser.id])
ev = d.observe(flow(browser, tx: 500_000, dest: "Somewhere", signer: SignerInfo(status: .developerID, teamID: "T")), now: t0, idleSeconds: 0)
check(!ev.contains { $0.kind == .newDestination }, "verified browsers visit new places by design")
d = detector(known: [browser.id])
ev = d.observe(flow(browser, tx: 500_000, dest: "Somewhere", signer: SignerInfo(status: .adHoc, codeHash: "x")), now: t0, idleSeconds: 0)
check(ev.contains { $0.kind == .newDestination }, "ATTACK: an unsigned app claiming to be a browser gets no exemption")

d = detector(known: [uploader.id])
ev = d.observe(flow(uploader, tx: 300_000, outside: true), now: t0, idleSeconds: 0)
check(ev.contains { $0.kind == .outsideVPN }, "VPN bypass flagged")

let goodSigner = SignerInfo(status: .developerID, teamID: "GOOD")
d = detector(known: [uploader.id], pairs: ["\(uploader.id)|Amazon"], trusted: [uploader.id: "team:GOOD"])
ev = d.observe(flow(uploader, tx: 500_000_000, signer: goodSigner, outside: true), now: t0, idleSeconds: 999)
check(ev.isEmpty, "a trusted app with the same signature raises nothing")
d = detector(known: [uploader.id], pairs: ["\(uploader.id)|Amazon"], trusted: [uploader.id: "team:GOOD"])
ev = d.observe(flow(uploader, tx: 500_000_000, signer: SignerInfo(status: .developerID, teamID: "EVIL"), outside: true), now: t0, idleSeconds: 999)
check(ev.contains { $0.kind == .largeUpload }, "ATTACK: a different developer using a trusted app's ID isn't trusted")
d = detector(known: [uploader.id], pairs: ["\(uploader.id)|Amazon"], trusted: [uploader.id: "code:abc"])
ev = d.observe(flow(uploader, tx: 500_000_000, signer: SignerInfo(status: .adHoc, codeHash: "changed")), now: t0, idleSeconds: 999)
check(ev.contains { $0.kind == .unsignedSender }, "ATTACK: a modified build of a trusted unsigned app isn't trusted")
d = detector(known: [uploader.id], trusted: [uploader.id: "team:GOOD"])
ev = d.observe(flow(uploader, tx: 500_000_000, signer: nil), now: t0, idleSeconds: 999)
check(!ev.isEmpty, "trust needs a confirmed signature")

let fakeApple = identity("Safari", browser: true, bundle: "com.apple.Safari.fake")
let realApple = identity("Safari", browser: true, bundle: "com.apple.Safari")
d = detector()
ev = d.observe(flow(fakeApple, tx: 300_000, signer: SignerInfo(status: .adHoc, codeHash: "x"), outside: true), now: t0, idleSeconds: 0)
check(ev.contains { $0.kind == .newApp }, "ATTACK: a fake Apple app counts as new")
check(ev.contains { $0.kind == .unsignedSender && $0.title.contains("claims to be an Apple app") }, "ATTACK: a fake Apple app is called out by name")
check(ev.contains { $0.kind == .outsideVPN }, "ATTACK: a fake Apple app can't bypass the VPN unnoticed")
check(ev.contains { $0.kind == .newDestination }, "ATTACK: a fake Apple app sending somewhere new is reported")
d = detector()
ev = d.observe(flow(fakeApple, tx: 10, signer: SignerInfo(status: .developerID, teamID: "EVIL")), now: t0, idleSeconds: 0)
check(ev.contains { $0.title.contains("claims to be an Apple app") }, "ATTACK: even a validly signed app can't pose as Apple")
d = detector()
ev = d.observe(flow(realApple, tx: 300_000, signer: SignerInfo(status: .apple), outside: true), now: t0, idleSeconds: 0)
check(ev.isEmpty, "the real Apple app, verified by signature, stays quiet")
check(!fakeApple.isVerifiedApple(signer: nil), "no signature yet means not verified")
let appleTool = AppIdentity(id: "/usr/bin/curl", name: "curl", kind: .commandLine, path: "/usr/bin/curl", executable: "/usr/bin/curl", bundleID: nil, explanation: nil, claimsBrowser: false, launchedBy: nil)
d = detector()
ev = d.observe(flow(appleTool, tx: 300_000, signer: SignerInfo(status: .apple), outside: true), now: t0, idleSeconds: 0)
check(ev.contains { $0.kind == .newApp } && ev.contains { $0.kind == .newDestination } && ev.contains { $0.kind == .outsideVPN }, "ATTACK: Apple-signed curl gets no exemption, since malware can drive it")

let gone = AppIdentity(id: "exited", name: "Gone", kind: .exited, path: nil, executable: nil, bundleID: nil, explanation: nil, claimsBrowser: false, launchedBy: nil)
d = detector()
ev = d.observe(flow(gone, tx: 500_000), now: t0, idleSeconds: 0)
check(ev.isEmpty, "small traffic from an exited process isn't worth an alert")
ev = d.observe(flow(gone, tx: 600_000), now: t0, idleSeconds: 0)
check(ev.contains { $0.kind == .unsignedSender && $0.title.contains("already exited") }, "ATTACK: a quick-exit sender is reported")
check(gone.trustKey(signer: nil) == nil, "an unidentified process can't be trusted")
var off = Prefs()
off.recordHistory = false
check(!off.detectorConfig.enabled.contains(.newApp) && !off.detectorConfig.enabled.contains(.newDestination), "with history off, alerts that rely on it stop")
check(off.detectorConfig.enabled.contains(.largeUpload) && off.detectorConfig.enabled.contains(.unsignedSender), "other alerts keep working with history off")

d = detector(known: [])
ev = d.observe(flow(uploader, tx: 500_000_000, cls: .local), now: t0, idleSeconds: 999)
check(ev.isEmpty, "a big NAS backup is not a leak")
ev = d.observe(flow(uploader, tx: 500_000_000, cls: .envelope), now: t0, idleSeconds: 999)
check(ev.isEmpty, "VPN envelope is not a leak")

// MARK: Diagnosis

func stats(_ ms: Double?, loss: Double = 0) -> LatencyStats { LatencyStats(samples: 5, averageMs: ms, bestMs: ms, lossPercent: loss) }
func diag(router: LatencyStats = stats(2), internet: LatencyStats = stats(20), down: Double = 0, up: Double = 0, peakUp: Double = 10_000_000, peakDown: Double = 100_000_000, retx: Double? = nil, vpn: String? = nil) -> Verdict {
    Diagnosis.evaluate(HealthInput(router: router, internet: internet, hasRouter: true, down: down, up: up, peakDown: peakDown, peakUp: peakUp,
        topDown: ("Steam", down), topUp: ("Dropbox", up), retransmitPercent: retx, vpnName: vpn))
}
check(Diagnosis.evaluate(HealthInput(router: LatencyStats(), internet: LatencyStats(), hasRouter: true, down: 0, up: 0, peakDown: 0, peakUp: 0, topDown: nil, topUp: nil, retransmitPercent: nil, vpnName: nil)).level == .measuring, "needs samples first")
check(diag().level == .good, "healthy")
check(diag(router: stats(2, loss: 50)).title.contains("router"), "router loss blames the local link")
check(diag(router: stats(80), internet: stats(100)).title.contains("local network"), "a slow router is reported before slow internet")
check(diag(internet: stats(20, loss: 50), vpn: "ProtonVPN").detail.contains("ProtonVPN"), "loss past the router names the VPN")
var loaded = LatencyStats(samples: 5, averageMs: 300, bestMs: 30, lossPercent: 0)
let full = diag(internet: loaded, up: 9_000_000)
check(full.level == .bad && full.detail.contains("Dropbox"), "bufferbloat blames the uploader (\(full.detail))")
loaded = LatencyStats(samples: 5, averageMs: 300, bestMs: 30, lossPercent: 0)
let notUs = diag(internet: loaded, down: 1000, up: 1000)
check(notUs.title.contains("not this Mac"), "high latency with nothing running points elsewhere")
check(diag(up: 9_000_000).level == .notice, "heavy but responsive is a notice, not an alarm")
check(diag(retx: 12).title.contains("resent"), "retransmits are reported")
check(LatencyStats([10, nil, 20, nil]).lossPercent == 50 && LatencyStats([10, nil, 20, nil]).averageMs == 15, "latency window stats")

// MARK: Prefs

var prefs = Prefs()
prefs.menuContent = .download
prefs.hiddenSections = [.graph]
let encoded = try! JSONEncoder().encode(prefs)
check(Prefs.decode(encoded) == prefs, "settings round trip")
var obj = try! JSONSerialization.jsonObject(with: encoded) as! [String: Any]
obj["rowLimit"] = nil
obj["sectionOrder"] = ["apps"]
let older = Prefs.decode(try! JSONSerialization.data(withJSONObject: obj))
check(older.menuContent == .download && older.rowLimit == Prefs().rowLimit, "settings saved by an older version keep their values and gain defaults")
check(older.sectionOrder.first == .apps && older.sectionOrder.count == PanelSection.allCases.count, "new sections join a customised order")
check(Prefs.decode(Data("not json".utf8)) == Prefs(), "a corrupt settings file falls back to defaults")
prefs = Prefs()
prefs.menuContent = .upload
prefs.reverseDNS = false
prefs.apply(.minimal)
check(prefs.visibleSections == [.apps] && prefs.menuContent == .upload && !prefs.reverseDNS, "presets change only the panel")
prefs.apply(.everything)
check(prefs.visibleSections.count == PanelSection.allCases.count, "everything shows all")

// MARK: Ledger

let tmp = NSTemporaryDirectory() + "undertow-check-\(UUID().uuidString)"
try! FileManager.default.createDirectory(atPath: tmp, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(atPath: tmp) }
let ledger = Ledger(path: tmp + "/ledger.sqlite")!
let mode = (try! FileManager.default.attributesOfItem(atPath: tmp + "/ledger.sqlite"))[.posixPermissions] as! NSNumber
check(mode.intValue == 0o600, "history file is private to this user")
ledger.recordApp(id: "a", name: "App A", path: "/a", now: t0)
ledger.recordApp(id: "b", name: "App B", path: nil, now: t0)
ledger.addUsage(now: t0, app: "a", ip: "1.1.1.1", rx: 100, tx: 10)
ledger.addUsage(now: t0, app: "a", ip: "1.1.1.1", rx: 100, tx: 10)
ledger.addUsage(now: t0, app: "b", ip: "8.8.8.8", rx: 5000, tx: 5)
ledger.flush()
ledger.addUsage(now: t0, app: "a", ip: "1.1.1.1", rx: 1, tx: 1)
var top = ledger.topApps(since: t0.addingTimeInterval(-60))
check(top.count == 2 && top[0].name == "App B", "totals are ranked")
check(top.first { $0.id == "a" }?.rx == 201 && top.first { $0.id == "a" }?.tx == 21, "buffered and saved usage both counted")
check(ledger.topApps(since: t0.addingTimeInterval(7200)).isEmpty, "date filter")
check(ledger.topDestinations(since: t0.addingTimeInterval(-60), app: "a").first?.ip == "1.1.1.1", "per-app destinations")
check(ledger.apps(forIPs: ["8.8.8.8"], since: t0.addingTimeInterval(-60)).first?.id == "b", "who sent data here")
ledger.setTrusted(app: "a", name: "App A", path: "/a", key: "team:T", now: t0)
check(ledger.trustedApps() == ["a": "team:T"], "trust saved with its signature")
ledger.setTrusted(app: "new", name: "New", path: nil, key: "code:x", now: t0)
check(ledger.trustedApps()["new"] == "code:x", "an app with no record yet can be trusted")
ledger.setTrusted(app: "new", name: "New", path: nil, key: nil, now: t0)
check(ledger.trustedApps()["new"] == nil, "trust can be removed")
ledger.recordPair(app: "a", dest: "Amazon", now: t0)
check(ledger.knownPairs() == ["a|Amazon"], "pair saved")
let eid = ledger.insert(event: WatchEvent(date: t0, kind: .largeUpload, appID: "a", appName: "App A", title: "T", detail: "D"))
check(ledger.recentEvents().first?.id == eid && ledger.recentEvents().first?.read == false, "event saved")
ledger.markAllEventsRead()
check(ledger.recentEvents().first?.read == true, "event read")
let installed = ledger.installDate(now: t0)
check(ledger.installDate(now: t0.addingTimeInterval(999)) == installed, "install date is stable")
ledger.recordPair(app: "b", dest: "Active", now: t0)
ledger.touchPairs(["b|Active"], now: t0.addingTimeInterval(3 * 86400))
ledger.recordApp(id: "c", name: "Recent", path: nil, now: t0.addingTimeInterval(3 * 86400))
ledger.prune(olderThanDays: 1, now: t0.addingTimeInterval(3 * 86400))
check(ledger.topApps(since: t0.addingTimeInterval(-86400)).isEmpty && ledger.recentEvents().isEmpty, "retention removes old traffic and alerts")
check(!ledger.knownPairs().contains("a|Amazon"), "retention removes old app and destination records")
check(ledger.knownPairs().contains("b|Active"), "destinations still in use are kept")
check(!ledger.knownApps().contains("b") && ledger.knownApps().contains("c"), "retention removes apps gone quiet")
check(ledger.trustedApps() == ["a": "team:T"], "retention keeps trust decisions")
ledger.addUsage(now: t0, app: "a", ip: "1.1.1.1", rx: 1, tx: 1)
ledger.wipe(includingBaseline: false)
check(ledger.topApps(since: t0.addingTimeInterval(-86400)).isEmpty, "clearing erases traffic")
check(ledger.knownPairs().isEmpty, "clearing erases the record of destinations")
check(ledger.knownApps() == ["a"] && ledger.trustedApps() == ["a": "team:T"], "clearing keeps only trusted apps")
check(ledger.installDate(now: t0.addingTimeInterval(500)) == t0.addingTimeInterval(500), "clearing restarts the learning period")
ledger.wipe(includingBaseline: true)
check(ledger.knownApps().isEmpty, "full wipe")

// MARK: Owner table

let tsv = tmp + "/owners.tsv"
var lines = ["1.0.0.0\t1.0.0.255\t13335\tUS\tCLOUDFLARENET - Cloudflare, Inc.",
             "1.0.1.0\t1.0.3.255\t0\tNone\tNot routed",
             "1.0.4.0\t1.0.7.255\t38803\tAU\tGTELECOM-AS-AP - Gtelecom Pty Ltd",
             "2a00:1450::\t2a00:1450:ffff:ffff:ffff:ffff:ffff:ffff\t15169\tUS\tGOOGLE - Google LLC",
             "bad line",
             "1.2.3.4\tnot-an-ip\t5\tUS\tBad",
             "9.9.9.9\t9.9.9.0\t5\tUS\tBackwards range",
             "1.1.1.0\t1.1.1.255\t13335\tUS\tCLOUDFLARENET - Cloudflare, Inc.",
             "8.8.8.0\t8.8.8.255\t15169\tUS\tGOOGLE - Google LLC",
             "17.0.0.0\t17.255.255.255\t714\tUS\tAPPLE-ENGINEERING - Apple Inc.\u{202E}"]
try! lines.joined(separator: "\n").write(toFile: tsv, atomically: true, encoding: .utf8)
func gzip(_ path: String) -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
    p.arguments = ["-kf", path]
    try! p.run()
    p.waitUntilExit()
    return path + ".gz"
}
let owners = OwnerDatabase(path: tmp + "/owners.sqlite")
check(!owners.isAvailable && owners.lookup("1.0.0.1") == nil, "no table yet")
var rejected = false
do { try owners.importTSV(gzipPath: gzip(tsv)) } catch { rejected = true }
check(rejected && !owners.isAvailable, "a suspiciously small file is rejected")
for i in 0..<100_001 {
    lines.append("10.\((i >> 16) & 255).\((i >> 8) & 255).\(i & 255)\t10.\((i >> 16) & 255).\((i >> 8) & 255).\(i & 255)\t64512\tZZ\tFILLER")
}
try! lines.joined(separator: "\n").write(toFile: tsv, atomically: true, encoding: .utf8)
let imported = try! owners.importTSV(gzipPath: gzip(tsv))
check(imported == 100_007, "imports valid routed rows only (got \(imported))")
check(owners.lookup("9.9.9.5") == nil, "a backwards range is ignored")
check(owners.lookup("17.0.0.1")?.rawName.contains("\u{202E}") == false, "invisible characters don't reach the table")
check(owners.isAvailable, "table opens after import")
check(owners.lookup("1.0.0.1")?.name == "Cloudflare" && owners.lookup("1.0.0.1")?.countryCode == "US", "ipv4 inside a range")
check(owners.lookup("1.0.0.0")?.asn == 13335 && owners.lookup("1.0.0.255")?.asn == 13335, "range edges are inclusive")
check(owners.lookup("1.0.2.1") == nil, "an unrouted gap returns nothing rather than a neighbour")
check(owners.lookup("2a00:1450:4009::1")?.name == "Google", "ipv6")
check(owners.lookup("nonsense") == nil, "bad input")
try! Data("not gzip".utf8).write(to: URL(fileURLWithPath: tmp + "/bad.gz"))
rejected = false
do { try owners.importTSV(gzipPath: tmp + "/bad.gz") } catch { rejected = true }
check(rejected && owners.lookup("1.0.0.1")?.name == "Cloudflare", "a corrupt update leaves the working table intact")

func expectRejected(_ text: String, _ name: String) {
    let path = tmp + "/reject.tsv"
    try! text.write(toFile: path, atomically: true, encoding: .utf8)
    var failed = false
    do { try owners.importTSV(gzipPath: gzip(path)) } catch { failed = true }
    check(failed && owners.lookup("1.0.0.1")?.name == "Cloudflare", "\(name), and the working table survives")
}
let poisoned = lines.joined(separator: "\n").replacingOccurrences(of: "8.8.8.0\t8.8.8.255\t15169", with: "8.8.8.0\t8.8.8.255\t666")
expectRejected(poisoned, "ATTACK: a table with the wrong owner for a known address is rejected")
expectRejected(lines.joined(separator: "\n") + "\n" + String(repeating: "x", count: 3_000_000), "ATTACK: an impossibly long line is rejected")

print("\(passes) passed, \(failures) failed")
exit(failures == 0 ? 0 : 1)
