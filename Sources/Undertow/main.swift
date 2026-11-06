import AppKit
import UndertowCore

let arguments = CommandLine.arguments

// Maintenance: build the owner table from an already-downloaded file, then exit.
if let flag = arguments.firstIndex(of: "--import-owners"), arguments.count > flag + 1 {
    let db = OwnerDatabase(path: AppPaths.owners)
    do {
        let count = try db.importTSV(gzipPath: arguments[flag + 1])
        print("Imported \(count) ranges into \(AppPaths.owners)")
        exit(0)
    } catch {
        print("Import failed: \(error.localizedDescription)")
        exit(1)
    }
}

// Maintenance: same action as the "Open at login" switch in Settings.
if let flag = arguments.firstIndex(of: "--login-item"), arguments.count > flag + 1 {
    if let error = LoginItem.set(arguments[flag + 1] == "on") {
        print("Login item change failed: \(error)")
        exit(1)
    }
    print("Login item status: \(LoginItem.statusDescription)")
    exit(0)
}

// `Undertow --toggle-panel` opens or closes the panel in the copy that's already running,
// for binding to a keyboard shortcut. Starts Undertow first if it isn't running.
if arguments.contains("--toggle-panel") {
    let running = NSRunningApplication.runningApplications(withBundleIdentifier: PanelCommand.bundleID)
        .contains { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
    if running {
        PanelCommand.send()
    } else {
        let open = Process()
        open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        open.arguments = ["-a", Bundle.main.bundlePath, "--args", "--open-panel"]
        try? open.run()
        open.waitUntilExit()
    }
    exit(0)
}

let delegate = AppDelegate()
let app = NSApplication.shared
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
