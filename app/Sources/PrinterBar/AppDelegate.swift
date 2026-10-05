import AppKit
import PrinterBarKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate, NSWindowDelegate, NSDraggingDestination {
    let model = AppModel()
    private let device = DeviceWatcher()
    private var item: NSStatusItem!
    private let popover = NSPopover()

    func applicationDidFinishLaunching(_ note: Notification) {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.target = self
            button.action = #selector(toggle)
            button.imagePosition = .imageLeading
            button.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
            // The status item's window forwards drag events to its delegate.
            button.window?.registerForDraggedTypes([.fileURL])
            button.window?.delegate = self
        }

        popover.behavior = .transient
        popover.animates = false
        popover.appearance = NSAppearance(named: .darkAqua)
        popover.delegate = self

        model.showPopover = { [weak self] in self?.show() }
        trackIcon()
        device.onChange = { [weak self] present in self?.model.deviceChanged(present) }
        device.start()
        model.start()
    }

    private func trackIcon() {
        withObservationTracking {
            let image = model.status.icon.image, title = model.title
            guard let button = item.button else { return }
            // Setting either one relayouts the status item, so only on change.
            if button.image !== image { Perf.count("icon.set"); button.image = image }
            if button.title != title { button.title = title }
        } onChange: { [weak self] in
            DispatchQueue.main.async { self?.trackIcon() }
        }
    }

    @objc private func toggle() {
        popover.isShown ? popover.performClose(nil) : show()
    }

    private func show() {
        guard let button = item.button else { return }
        // The SwiftUI view tree exists only while the popover is open; the
        // app spends most of its life closed in the menu bar.
        if popover.contentViewController == nil {
            let host = NSHostingController(rootView: RootView().environment(model))
            host.sizingOptions = .preferredContentSize
            popover.contentViewController = host
        }
        NSApp.activate()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    func popoverDidShow(_ notification: Notification) {
        model.popoverOpen = true
        model.setNeedsRefresh(history: true)
    }

    func popoverDidClose(_ notification: Notification) {
        model.popoverOpen = false
        if model.screen != .duplex { model.screen = .main }
        popover.contentViewController = nil
    }

    // MARK: Dropping files on the icon

    func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }

    func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                                         options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        guard !urls.isEmpty else { return false }
        // Holding Option while dropping a PDF prints it two-sided.
        if NSEvent.modifierFlags.contains(.option), urls.count == 1, urls[0].pathExtension.lowercased() == "pdf" {
            model.startDuplex(urls[0], paper: model.defaults.paper)
        } else {
            model.screen = .printFile(urls)
        }
        show()
        return true
    }
}
