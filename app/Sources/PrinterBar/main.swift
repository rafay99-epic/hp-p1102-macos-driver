import AppKit
import PrinterBarKit

// launchd starts the app when a P1102 is attached; take that event first or
// launchd relaunches the app in a loop.
LaunchAgent.takeLaunchEvents()

if CommandLine.arguments.contains("--render-screens") {
    MainActor.assumeIsolated { Snapshots.render(to: CommandLine.arguments.last!) }
    exit(0)
}

// tools/perf stops the app with SIGTERM and reads the counters from stderr.
if Perf.enabled {
    signal(SIGTERM, SIG_IGN)
    let term = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
    term.setEventHandler { Perf.dump(); exit(0) }
    term.resume()
    objc_setAssociatedObject(NSApplication.shared, "perf.term", term, .OBJC_ASSOCIATION_RETAIN)
}

// One copy at a time. A second launch (say, launchd seeing the printer while
// the app is already open) gives launchd a moment to deliver its event, then exits.
let me = NSRunningApplication.current
if NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
    .contains(where: { $0 != me }) {
    DispatchQueue.main.asyncAfter(deadline: .now() + 1) { exit(0) }
    dispatchMain()
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
