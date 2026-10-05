import Foundation
import IOKit
import XPC
import notify

/// Darwin notifications (notify(3)). CUPS on macOS posts com.apple.jobChange,
/// com.apple.printerHistoryChange and com.apple.printerListChange; it does not
/// support IPP subscriptions (Create-Printer-Subscriptions is rejected).
@MainActor
enum DarwinNotify {
    static func observe(_ name: String, _ handler: @escaping @MainActor () -> Void) {
        var token: Int32 = 0
        notify_register_dispatch(name, &token, .main) { _ in MainActor.assumeIsolated { handler() } }
    }
}

/// Reports when a P1102 appears on or leaves USB. The printer drops off USB
/// when it is switched off, so "present" means plugged in and powered on.
final class DeviceWatcher {
    private(set) var count = 0
    var onChange: (Bool) -> Void = { _ in }
    private var port: IONotificationPortRef?
    private var added: io_iterator_t = 0
    private var removed: io_iterator_t = 0

    static func matching() -> CFDictionary {
        let d = IOServiceMatching("IOUSBHostDevice") as NSMutableDictionary
        d["idVendor"] = 0x03f0
        d["idProduct"] = 0x002a
        return d
    }

    func start() {
        port = IONotificationPortCreate(kIOMainPortDefault)
        CFRunLoopAddSource(CFRunLoopGetMain(), IONotificationPortGetRunLoopSource(port).takeUnretainedValue(), .defaultMode)
        let me = Unmanaged.passUnretained(self).toOpaque()
        IOServiceAddMatchingNotification(port, kIOFirstMatchNotification, Self.matching(), { ctx, it in
            Unmanaged<DeviceWatcher>.fromOpaque(ctx!).takeUnretainedValue().drain(it, delta: 1)
        }, me, &added)
        IOServiceAddMatchingNotification(port, kIOTerminatedNotification, Self.matching(), { ctx, it in
            Unmanaged<DeviceWatcher>.fromOpaque(ctx!).takeUnretainedValue().drain(it, delta: -1)
        }, me, &removed)
        // Arms the notifications and counts devices already attached.
        drain(added, delta: 1)
        drain(removed, delta: -1)
        onChange(count > 0)
    }

    private func drain(_ it: io_iterator_t, delta: Int) {
        var changed = false
        while case let service = IOIteratorNext(it), service != 0 {
            IOObjectRelease(service)
            count = max(0, count + delta)
            changed = true
        }
        if changed { onChange(count > 0) }
    }
}

/// Lets launchd start PrinterBar when a P1102 is attached, so nothing runs
/// in the background while the printer is off.
enum LaunchAgent {
    static let label = "com.rafay.printerbar"
    static var plist: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }
    static var domain: String { "gui/\(getuid())" }

    static var isEnabled: Bool { FileManager.default.fileExists(atPath: plist.path) }

    static func enable() {
        let dict: [String: Any] = [
            "Label": label,
            "ProgramArguments": [Bundle.main.executablePath ?? ""],
            "LimitLoadToSessionType": "Aqua",
            "ProcessType": "Interactive",
            "LaunchEvents": ["com.apple.iokit.matching": [
                "p1102-attached": [
                    "IOProviderClass": "IOUSBHostDevice",
                    "idVendor": 0x03f0,
                    "idProduct": 0x002a,
                    "IOMatchLaunchStream": true,
                ],
            ]],
        ]
        try? FileManager.default.createDirectory(at: plist.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let data = try? PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0),
              (try? data.write(to: plist)) != nil else { return }
        launchctl("bootout", "\(domain)/\(label)")
        launchctl("bootstrap", domain, plist.path)
    }

    static func disable() {
        launchctl("bootout", "\(domain)/\(label)")
        try? FileManager.default.removeItem(at: plist)
    }

    /// Re-registers if the app moved since the agent was written.
    static func refreshIfMoved() {
        guard isEnabled,
              let dict = NSDictionary(contentsOf: plist),
              let args = dict["ProgramArguments"] as? [String],
              args.first != Bundle.main.executablePath else { return }
        enable()
    }

    /// launchd keeps relaunching the app until the attach event is taken, so
    /// this must run on every launch.
    static func takeLaunchEvents() {
        xpc_set_event_stream_handler("com.apple.iokit.matching", DispatchQueue.main) { _ in }
    }

    private static func launchctl(_ args: String...) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = args
        p.standardError = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        try? p.run()
        p.waitUntilExit()
    }
}
