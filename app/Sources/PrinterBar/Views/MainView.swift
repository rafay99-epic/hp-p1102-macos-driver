import PrinterBarKit
import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let _ = Perf.count("body.root")
        VStack(alignment: .leading, spacing: 0) {
            switch model.screen {
            case .main: MainView()
            case .queue: QueueView()
            case .settings: SettingsView()
            case .testPage: TestPageView()
            case .driver: DriverView()
            case .duplex: DuplexView()
            case .printFile(let urls): PrintFileView(urls: urls)
            }
            if let message = model.message {
                Sep()
                Note(message)
            }
        }
        .padding(.vertical, 6)
        .frame(width: 330)
        .background(Color.black)
        .font(.system(size: 13))
        .environment(\.colorScheme, .dark)
    }
}

struct StatusHeader: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let (text, color): (String, Color) = switch model.status {
        case .ready: ("● Ready", Ink.dim)
        case .printing: ("▶ Printing", Ink.dim)
        case .paused: ("❚❚ Paused", Ink.dim)
        case .notConnected: ("◌ Not connected", Ink.dim)
        case .unplugged: ("◌ Unplugged", Ink.dim)
        case .attention: ("▲ Needs attention", Ink.bad)
        case .driverMissing: ("▲ Driver missing", Ink.bad)
        }
        Row(title: "HP LaserJet P1102", bold: true) { Text(text).foregroundStyle(color) }
    }
}

struct MainView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        StatusHeader()
        Sep()
        switch model.status {
        case .driverMissing: driverMissing
        case .attention(let problem): attention(problem)
        case .unplugged: unplugged
        default: ledger
        }
    }

    @ViewBuilder private var ledger: some View {
        if model.active.isEmpty {
            Note(model.status == .notConnected
                 ? "Plug in the printer and switch it on."
                 : "No jobs. Drop a file on the icon or press ⌘P in any app.")
        } else {
            JobRows()
            Sep()
            Action(model.status == .paused ? "Resume Printing" : "Pause Printing", "⌘.", key: ".") { model.togglePause() }
            Action("Cancel All") { model.cancelAll() }
        }
        Sep()
        Action("Print File…", "⌘O", key: "o") { Pick.files(model) }
        Action("Print Two-Sided…", "⌘D", key: "d") { Pick.duplex(model) }
        Action("Test Page", "⌘T", key: "t") { model.screen = .testPage }
        Sep()
        Action(defaultsLine) { model.screen = .settings }
        Action("Queue", queueLine) { model.screen = .queue }
        Action("Settings", "⌘, ›", key: ",") { model.screen = .settings }
        Action("Quit", "⌘Q", key: "q") { NSApp.terminate(nil) }
    }

    private var defaultsLine: String {
        let d = model.defaults
        return "\(d.paper) · \(d.mediaType) · Density \(d.density) · Toner save \(d.tonerSave ? "on" : "off")"
    }

    private var queueLine: String {
        "\(model.waiting.count) waiting · \(model.done.count) today ›"
    }

    @ViewBuilder private func attention(_ problem: String) -> some View {
        Row(problem, color: Ink.bad)
        Note("Check the paper and that the front door is closed. If the green light is blinking, turn the printer off and on.")
        if let job = model.current {
            Sep()
            Row(job.name, "stopped at page \(job.sheetsDone + 1)\(model.totals[job.id].map { " of \($0)" } ?? "")")
        }
        Action("Try Again", "↩", key: .return, modifiers: [], prominent: true) { model.tryAgain() }
        if let job = model.current { Action("Cancel Job") { model.cancel(job) } }
    }

    @ViewBuilder private var unplugged: some View {
        Note("\(model.active.count) job\(model.active.count == 1 ? " is" : "s are") waiting. They print when the printer is back on.")
        JobRows(showCurrent: false)
        Sep()
        Action("Cancel All and Quit") { model.cancelAll(); NSApp.terminate(nil) }
    }

    @ViewBuilder private var driverMissing: some View {
        Note("This Mac has no driver for the printer yet.")
        Action("Install Driver", "asks for your password", prominent: true) { model.installDriver() }
        Note("Or in Terminal: sudo make install")
        Sep()
        Action("Quit", "⌘Q", key: "q") { NSApp.terminate(nil) }
    }
}

/// The active job with its progress, then the waiting jobs.
struct JobRows: View {
    @Environment(AppModel.self) private var model
    var showCurrent = true

    var body: some View {
        if showCurrent, let job = model.current {
            let total = model.totals[job.id]
            Row(title: job.name) {
                HStack(spacing: 6) {
                    Text("page \(job.sheetsDone + 1)\(total.map { " of \($0)" } ?? "")")
                    TextLink("✕") { model.cancel(job) }
                }
            }
            Meter(fraction: total.map { Double(job.sheetsDone) / Double($0) } ?? 0)
        }
        ForEach(showCurrent ? model.waiting : model.active) { job in
            Row(title: job.name) {
                HStack(spacing: 6) {
                    Text(job.state == .held ? "held" : model.totals[job.id].map { "\($0) pp" } ?? "waiting")
                    TextLink("✕") { model.cancel(job) }
                }
            }
        }
    }
}

struct QueueView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Header(title: "Queue", back: { model.screen = .main }) {
            if !model.done.isEmpty { TextLink("Clear Done") { model.clearDone() } }
        }
        if let job = model.current {
            SectionLabel("Now")
            Row(title: job.name) {
                HStack(spacing: 6) {
                    Text("\(job.sheetsDone + 1)\(model.totals[job.id].map { "/\($0)" } ?? "")")
                    TextLink("✕") { model.cancel(job) }
                }
            }
        }
        if !model.waiting.isEmpty {
            SectionLabel("Waiting")
            ForEach(model.waiting) { job in
                Row(title: job.name) {
                    HStack(spacing: 6) {
                        if let n = model.totals[job.id] { Text("\(n) pp ·") }
                        if job.state == .held {
                            TextLink("Release") { model.release(job) }
                        } else {
                            TextLink("Print Next") { model.printNext(job) }
                        }
                        Text("·")
                        TextLink("✕") { model.cancel(job) }
                    }
                }
            }
        }
        if !model.done.isEmpty {
            SectionLabel("Done today")
            ForEach(model.done.prefix(8)) { job in
                Row(title: job.name) {
                    HStack(spacing: 6) {
                        Text((job.completed ?? job.created).formatted(date: .omitted, time: .shortened) + " ·")
                        if job.failed {
                            Text(job.state == .canceled ? "canceled ·" : "failed ·").foregroundStyle(Ink.bad)
                            TextLink("Retry") { model.reprint(job) }
                        } else {
                            Text("\(job.sheetsDone) p ·")
                            TextLink("Reprint") { model.reprint(job) }
                        }
                    }
                }
            }
        }
        if model.active.isEmpty && model.done.isEmpty { Note("Nothing printed today.") }
        Sep()
        Row(title: "This month \(model.pagesThisMonth) pages", color: Ink.dim) {
            TextLink("Printers & Scanners ›") {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Print-Scan-Settings.extension")!)
            }
        }
    }
}
