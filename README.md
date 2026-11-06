# Undertow

A macOS menu bar app that shows your upload and download speed in real time. Click it to
see which apps are using the network, where their data is going, and why your connection
might feel slow.

Requires macOS 13 or later. No root access, kernel extension or third-party dependencies.

## Install

### From a release

1. Download `Undertow-<version>.zip` from
   [Releases](https://github.com/absolute-cinema-jpg/undertow/releases), unzip it, and move
   `Undertow.app` to Applications.
2. **Right-click** the app, choose **Open**, then confirm.

macOS warns you on first launch because Undertow isn't notarised by Apple: that needs a paid
Developer ID, and this release is self-signed. If you'd rather not take a stranger's binary
on trust, which is reasonable for a tool that watches your network, build it yourself:

### From source

```bash
scripts/build.sh
cp -R dist/Undertow.app /Applications/
open /Applications/Undertow.app
```

You only need the Command Line Tools (`xcode-select --install`), not Xcode.

## Use

**Click** the menu bar item for the panel. **Right-click** for Settings and Quit. On first
launch the panel offers to download the IP owner table, which names most destinations.

### Open the panel from a keyboard shortcut

```bash
/Applications/Undertow.app/Contents/MacOS/Undertow --toggle-panel
```

This opens the panel, or closes it if it's already open, and starts Undertow if it isn't
running. The panel appears in about 0.1 seconds. Closing it hands the keyboard straight back
to the app you were in.

Bind that command to any launcher or hotkey tool. For
[Karabiner-Elements](https://karabiner-elements.pqrs.org), a ready-made rule for
Right Command + U is in [extras/karabiner-undertow.json](extras/karabiner-undertow.json):

```bash
cp extras/karabiner-undertow.json ~/.config/karabiner/assets/complex_modifications/
```

Then enable it under Complex Modifications > Add predefined rule. To use a different key,
change `key_code` and `modifiers` in the file first.

## What it answers

**"Why is my internet slow?"** The health card works outward from your Mac: router, then
internet, then what's using the connection. It tells you whether the likely cause is your
Wi-Fi, an app filling your connection, or something past your router, such as your VPN or ISP.

**"Is something leaking my data?"** The Watch section flags traffic worth a look:

| Alert | Fires when |
|---|---|
| Large upload | An app sends over 100 MB in 10 minutes (adjustable) |
| Upload while away | An app sends over 20 MB with no keyboard or mouse input |
| Unverified sender | A program sends data without a signature that Apple's chain vouches for, or poses as an Apple app |
| VPN bypass | An app's traffic leaves outside your VPN tunnel |
| New app | An app uses the network for the first time |
| New destination | An app sends over 100 KB somewhere it never has before |

New-app and new-destination alerts stay quiet for the first 24 hours while Undertow learns
what's normal. Otherwise everything you already use would be flagged as new.

Nothing an app says about itself earns it an exemption. Being treated as Apple, a browser or a
VPN depends on its code signature, checked in full against Apple's certificate chain. Trust is
tied to that signature too, so a different developer reusing a trusted app's ID isn't trusted.

## What it can't tell you

- **Which website or tab.** It sees that Chrome is talking to Amazon, but not the page,
  because browsers share connections and the traffic is encrypted. Seeing more would need
  root packet capture or a browser extension.
- **What the data is.** It sees how much went where, never the contents.
- **The exact company in every case.** The owner is whoever runs the network. A small site
  hosted on AWS or behind Cloudflare appears as Amazon or Cloudflare.
- **The server's location.** The flag shows where the network is registered.
- **The destination of unconnected UDP.** Some apps, often video calls and games, don't
  connect their UDP sockets to one address. These appear as "Unknown (no fixed destination)".

Alerts are prompts to take a look, not proof of a problem. A big iCloud upload triggers the
same rule a real leak would. A very short UDP exchange that starts and ends between two
samples can go uncounted.

**Undertow can reduce your risk, not rule it out.** Some evasion is beyond what it can see:

- Data sent slowly enough to stay under the thresholds raises no alert.
- An upload to someone's Amazon S3 storage just looks like Amazon, which an app may already use.
- A small amount of data hidden in DNS lookups is credited to macOS's DNS service.
- A validly signed app can misbehave. A signature says who made it, not that it's benign.
- Malware running as you can quit Undertow or edit its files, and malware with root can hide
  from `netstat` completely.

## Privacy

- Everything stays on this Mac. History is stored in
  `~/Library/Application Support/Undertow/history.sqlite`, readable only by your account and
  left out of backups. You can limit how long it's kept, turn it off, or wipe it in
  Settings > Data. With history off, Undertow records no traffic, destinations or alerts, and
  saves only the apps you've chosen to trust.
- IP owners come from a local table, so looking up an address tells nobody where you connect.

Undertow's own network use, all listed in Settings > Data:

| What | When | Can be turned off |
|---|---|---|
| Reverse DNS through your normal DNS server | New addresses, only while the panel is open | Yes |
| Ping to your router and 1.1.1.1 | Only while the panel is open | Yes |
| Owner table from iptoasn.com (about 11 MB) | Only when you ask | It's only ever on request |

## How it works

| Data | Source | Cost | When |
|---|---|---|---|
| Per-socket bytes and owning process | `netstat -anvbW` | ~5 ms | Every second |
| Hardware totals | `sysctl` (64-bit interface counters) | ~1 ms | Every second |
| Latency and retransmits | `nettop`, `ping` | ~180 ms | Panel open only |
| Who signed an app | Security framework, full check, no network access | Up to a few seconds per app | Cached until the file changes |

It uses about 2% of one core and about 50 MB of memory with the panel closed. A longer
update interval in Settings lowers the CPU use further.

Three kinds of traffic are counted separately, so the headline means what it says:

- **Internet:** what your apps exchange with public addresses.
- **Local network:** your NAS, printers and so on, which don't use your internet connection.
- **VPN tunnel:** the VPN's outer socket. This is the same data as the traffic inside the
  tunnel, so it isn't added to the total. Only a verified signature carrying Apple's restricted
  VPN entitlement qualifies. Command-line VPNs such as Homebrew's `openvpn` can't prove that, so
  their traffic counts as internet traffic and raises alerts. They can be marked as trusted.

## Development

```bash
scripts/build.sh checks                      # run the checks
scripts/build.sh debug                       # faster compile, no optimisation
scripts/package.sh 1.0.0                     # universal release zip and its checksum
dist/Undertow.app/Contents/MacOS/Undertow --snapshot /tmp/shots   # render views to PNG
dist/Undertow.app/Contents/MacOS/Undertow --test-drag              # simulated drags through the settings form
```

The login item is tied to the exact build, so after installing a new one, re-register it:

```bash
/Applications/Undertow.app/Contents/MacOS/Undertow --login-item off
/Applications/Undertow.app/Contents/MacOS/Undertow --login-item on
```

The checks are a plain executable because the Command Line Tools don't include XCTest.
SwiftPM isn't used because it fails on a CLT-only install.

| Path | Contents |
|---|---|
| `Sources/UndertowCore` | Parsing, attribution, storage, detection, no UI |
| `Sources/Undertow` | Status item, panel, settings |
| `Sources/CShim` | C wrappers for libproc and 64-bit interface counters |
| `Sources/UndertowChecks` | Checks, using real captured `netstat` and `nettop` output |

## License

Copyright (C) 2026 absolute-cinema-jpg

Undertow is free software, released under the [GNU General Public License v3.0](LICENSE). It
comes with no warranty, and it can't guarantee that nothing on your Mac is leaking data.

IP owner data comes from [iptoasn.com](https://iptoasn.com) and is public domain. It's
downloaded when you ask for it, and isn't included in this repository or the app.
