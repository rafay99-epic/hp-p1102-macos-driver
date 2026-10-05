import AppKit
import Observation
import PDFKit
import PrinterBarKit
import UniformTypeIdentifiers
import UserNotifications

enum Screen: Equatable {
    case main, queue, settings, testPage, driver, duplex
    case printFile([URL])
}

enum Status: Equatable {
    case driverMissing, notConnected, ready, printing, paused, unplugged
    case attention(String)

    var icon: Icon {
        switch self {
        case .ready, .notConnected: .ready
        case .printing: .printing
        case .paused: .paused
        case .attention, .driverMissing: .attention
        case .unplugged: .held
        }
    }
}

struct DuplexRun: Equatable {
    enum Phase: Equatable { case printingFront, reload, printingBack, calibrate, done }
    var name: String
    var paper: String
    var sheets: Int
    var phase: Phase
    var frontJob: Int?
    var backJob: Int?
    var backFile: URL?
    var calibrating: Bool
}

@MainActor @Observable
final class AppModel {
    var screen: Screen = .main
    var connected = false
    var printer: PrinterStatus?
    var active: [Job] = []
    var done: [Job] = []
    var defaults = Queue.Defaults()
    var duplex: DuplexRun?
    var message: String?
    var popoverOpen = false
    var driverFilesPresent = Setup.driverFilesPresent

    /// Page totals for jobs PrinterBar submitted. CUPS doesn't know the page
    /// count of a job until it has printed, so "page 2 of 5" needs this.
    var totals: [Int: Int] = [:]

    @ObservationIgnored var showPopover: () -> Void = {}
    @ObservationIgnored private var sawPrinter = false
    @ObservationIgnored private var progress: (job: Int, sheets: Int, since: Date)?
    @ObservationIgnored private var stalled = false
    @ObservationIgnored private var quitTask: Task<Void, Never>?
    @ObservationIgnored private var refreshing = false
    @ObservationIgnored private var readyMarked = false
    @ObservationIgnored private let prefs = UserDefaults.standard

    // MARK: Settings stored by the app

    var notifyFinish: Bool {
        get { access(keyPath: \.notifyFinish); return prefs.bool(forKey: "notifyFinish") }
        set { withMutation(keyPath: \.notifyFinish) { prefs.set(newValue, forKey: "notifyFinish") } }
    }
    var notifyProblems: Bool {
        get { access(keyPath: \.notifyProblems); return prefs.object(forKey: "notifyProblems") as? Bool ?? true }
        set { withMutation(keyPath: \.notifyProblems) { prefs.set(newValue, forKey: "notifyProblems") } }
    }
    var makeDefault: Bool {
        get { access(keyPath: \.makeDefault); return prefs.object(forKey: "makeDefault") as? Bool ?? true }
        set { withMutation(keyPath: \.makeDefault) { prefs.set(newValue, forKey: "makeDefault") } }
    }
    var openOnConnect: Bool {
        get { access(keyPath: \.openOnConnect); return LaunchAgent.isEnabled }
        set { withMutation(keyPath: \.openOnConnect) { newValue ? LaunchAgent.enable() : LaunchAgent.disable() } }
    }

    // MARK: Derived state

    var driverInstalled: Bool { driverFilesPresent && printer != nil }

    var status: Status {
        if !driverInstalled { return .driverMissing }
        if !connected { return active.isEmpty ? .notConnected : .unplugged }
        if let problem = attention { return .attention(problem) }
        if printer?.holdingNewJobs == true { return .paused }
        if active.contains(where: { $0.state == .processing }) { return .printing }
        return .ready
    }

    private var attention: String? {
        if let p = printer?.problems.first {
            return ["media-empty": "Out of paper", "media-needed": "Out of paper", "media-jam": "Paper jam",
                    "door-open": "Front door open", "cover-open": "Front door open",
                    "toner-empty": "Toner empty", "offline": "Printer offline"][p] ?? "Printer needs attention"
        }
        if printer?.state == .stopped { return "Printing stopped after an error" }
        if stalled { return "No progress for 60 s" }
        return nil
    }

    var current: Job? { active.first { $0.state == .processing } }
    var waiting: [Job] { active.filter { $0.state != .processing } }

    /// "2/5" next to the icon while printing.
    var title: String {
        guard let job = current else { return "" }
        let page = job.sheetsDone + 1
        return totals[job.id].map { "\(min(page, $0))/\($0)" } ?? "\(page)"
    }

    var pagesThisMonth: Int { prefs.integer(forKey: "pages.count") }

    // MARK: Lifecycle

    func start() {
        // Turn on auto-launch the first time the app runs from /Applications.
        if Bundle.main.bundlePath.hasPrefix("/Applications/"), !prefs.bool(forKey: "agentOffered") {
            prefs.set(true, forKey: "agentOffered")
            LaunchAgent.enable()
        }
        LaunchAgent.refreshIfMoved()
        Task {
            while !Task.isCancelled {
                await refresh()
                try? await Task.sleep(for: .seconds(popoverOpen || !active.isEmpty || duplex != nil ? 2 : 10))
            }
        }
    }

    func deviceChanged(_ present: Bool) {
        connected = present
        if present {
            sawPrinter = true
            quitTask?.cancel()
            quitTask = nil
            if makeDefault, printer != nil { Queue.makeDefaultPrinter() }
        }
        Task { await refresh() }
        scheduleQuitIfIdle()
    }

    /// Quits once the printer is gone and nothing is waiting for it. Only
    /// after the printer was seen, so opening the app by hand with the
    /// printer off still works.
    private func scheduleQuitIfIdle() {
        guard sawPrinter, !connected, active.isEmpty, duplex == nil, quitTask == nil else { return }
        quitTask = Task {
            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled, !connected, active.isEmpty else { quitTask = nil; return }
            NSApp.terminate(nil)
        }
    }

    func refresh() async {
        guard !refreshing else { return }
        Perf.count("refresh")
        let started = DispatchTime.now().uptimeNanoseconds
        defer { Perf.count("refresh.us", Int((DispatchTime.now().uptimeNanoseconds - started) / 1000)) }
        refreshing = true
        defer { refreshing = false }
        let (p, a, d) = await Task.detached {
            (Cups.printer(), Cups.jobs(completed: false), Cups.jobs(completed: true))
        }.value
        let wasAttention = attention != nil
        let finished = Set(active.map(\.id)).subtracting(a.map(\.id))

        printer = p
        active = a.sorted { ($0.state == .processing ? 0 : 1, $0.id) < ($1.state == .processing ? 0 : 1, $1.id) }
        let cleared = Set(prefs.array(forKey: "cleared") as? [Int] ?? [])
        done = d.filter { Calendar.current.isDateInToday($0.completed ?? $0.created) && !cleared.contains($0.id) }
            .sorted { $0.id > $1.id }
        driverFilesPresent = Setup.driverFilesPresent
        // Never while Settings is open: it would overwrite an edit in flight.
        if p != nil, screen != .settings {
            defaults = await Task.detached { Queue.defaults() }.value
        }

        trackProgress()
        countPages(d)
        advanceDuplex()
        if notifyFinish {
            for job in d where finished.contains(job.id) && job.state == .completed {
                notify("Printed \(job.name)", "")
            }
        }
        if notifyProblems, !wasAttention, let problem = attention { notify("HP LaserJet P1102", problem) }
        if !readyMarked { readyMarked = true; Perf.mark("ready") }
        if !active.isEmpty { quitTask?.cancel(); quitTask = nil }
        scheduleQuitIfIdle()
    }

    private func trackProgress() {
        guard connected, let job = current else { progress = nil; stalled = false; return }
        if progress?.job != job.id || progress?.sheets != job.sheetsDone {
            progress = (job.id, job.sheetsDone, .now)
            stalled = false
        } else if let since = progress?.since {
            stalled = Date.now.timeIntervalSince(since) > 60
        }
    }

    private func countPages(_ completed: [Job]) {
        let month = Date.now.formatted(.dateTime.year().month(.twoDigits))
        if prefs.string(forKey: "pages.month") != month {
            prefs.set(month, forKey: "pages.month")
            prefs.set(0, forKey: "pages.count")
            prefs.set([Int](), forKey: "pages.counted")
        }
        var counted = Set(prefs.array(forKey: "pages.counted") as? [Int] ?? [])
        var total = prefs.integer(forKey: "pages.count")
        for job in completed where job.state == .completed && !counted.contains(job.id)
            && (job.completed ?? .distantPast).formatted(.dateTime.year().month(.twoDigits)) == month {
            counted.insert(job.id)
            total += job.sheetsDone
        }
        prefs.set(total, forKey: "pages.count")
        prefs.set(Array(counted), forKey: "pages.counted")
    }

    // MARK: Actions

    struct PrintOptions {
        var paper = "A4"
        var copies = 1
        var range = ""
        var tonerSave = false
    }

    /// PDFs, images and text go straight to CUPS. Anything else (Word,
    /// PowerPoint, Excel, Pages...) is handed to the app that opens it.
    func print(_ urls: [URL], _ o: PrintOptions) {
        var opts = ["PageSize": o.paper, "fit-to-page": "true", "copies": "\(o.copies)",
                    "TonerSave": o.tonerSave ? "True" : "False"]
        if !o.range.isEmpty { opts["page-ranges"] = o.range }
        for url in urls {
            if Setup.printsDirectly(url) {
                do {
                    let id = try Cups.submit(url, title: url.lastPathComponent, options: opts)
                    if o.range.isEmpty, let n = Setup.pageCount(url) { totals[id] = n * o.copies }
                } catch { flash("Couldn't print \(url.lastPathComponent): \(error.localizedDescription)") }
            } else if let app = Setup.handOff(url) {
                flash("Sent \(url.lastPathComponent) to \(app)")
            } else {
                flash("Opened \(url.lastPathComponent). Press ⌘P there to print.")
            }
        }
        screen = .main
        Task { await refresh() }
    }

    func printTestPage(paper: String) {
        guard let url = Bundle.main.url(forResource: "testpage-\(paper)", withExtension: "pdf") else {
            return flash("Test page missing from the app bundle")
        }
        print([url], PrintOptions(paper: paper))
    }

    func cancel(_ job: Job) { Cups.cancel(job.id); Task { await refresh() } }
    func cancelAll() { active.forEach { Cups.cancel($0.id) }; Task { await refresh() } }
    func printNext(_ job: Job) { Cups.printNext(job.id); Task { await refresh() } }
    func reprint(_ job: Job) {
        if !Cups.restart(job.id) { flash("CUPS no longer has that file") }
        Task { await refresh() }
    }
    func release(_ job: Job) { Cups.release(job.id); Task { await refresh() } }

    func togglePause() {
        if status == .paused {
            Queue.resume(held: active.filter { $0.state == .held }.map(\.id))
        } else {
            Queue.pause(waiting: active.filter { $0.state == .pending }.map(\.id))
        }
        Task { await refresh() }
    }

    /// Resumes a queue CUPS stopped after an error; the stuck job starts over.
    func tryAgain() {
        Queue.enable()
        stalled = false
        progress = nil
        Task { await refresh() }
    }

    func clearDone() {
        let cleared = (prefs.array(forKey: "cleared") as? [Int] ?? []) + done.map(\.id)
        prefs.set(Array(cleared.suffix(500)), forKey: "cleared")
        done = []
    }

    func saveDefaults() {
        let d = defaults
        Task.detached {
            if !Queue.setDefaults(d) { await self.flash("Couldn't save defaults") }
        }
    }

    func installDriver() {
        do {
            try Setup.installDriver()
            Queue.extraQueues().forEach { _ = Queue.remove($0) }
            flash("Driver installed")
        } catch {
            flash(error.localizedDescription)
        }
        Task { await refresh() }
    }

    // MARK: Two-sided

    /// Starts a two-sided run. A nil url prints the calibration sheet instead.
    func startDuplex(_ url: URL?, paper: String) {
        let calibrating = url == nil
        do {
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("PrinterBar-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let source = try url ?? Duplex.calibrationSheet(in: dir)
            let split = try Duplex.split(source, settings: .load(), into: dir)
            let opts = ["PageSize": paper, "fit-to-page": "true"]
            let front = try Cups.submit(split.odd, title: "\(source.lastPathComponent) (front)", options: opts)
            totals[front] = split.sheets
            duplex = DuplexRun(name: source.lastPathComponent, paper: paper, sheets: split.sheets, phase: .printingFront,
                               frontJob: front, backFile: split.even, calibrating: calibrating)
            if split.even == nil { duplex?.phase = .printingBack; duplex?.backJob = front }
            screen = .duplex
        } catch {
            flash(error.localizedDescription)
        }
    }

    func printBacks() {
        guard var run = duplex, let file = run.backFile else { return }
        do {
            let id = try Cups.submit(file, title: "\(run.name) (back)", options: ["PageSize": run.paper, "fit-to-page": "true"])
            totals[id] = run.sheets
            run.backJob = id
            run.phase = .printingBack
            duplex = run
        } catch { flash(error.localizedDescription) }
    }

    func finishCalibration(_ order: Duplex.Settings.Order, upsideDown: Bool) {
        var s = Duplex.Settings.load()
        s.calibrate(order: order, upsideDown: upsideDown)
        s.save()
        duplex = nil
        screen = .main
        flash("Saved. Two-sided printing will use this from now on.")
    }

    private func advanceDuplex() {
        guard var run = duplex else { return }
        let activeIDs = Set(active.map(\.id))
        switch run.phase {
        case .printingFront where run.frontJob.map { !activeIDs.contains($0) } ?? false:
            run.phase = .reload
        case .printingBack where run.backJob.map { !activeIDs.contains($0) } ?? false:
            run.phase = run.calibrating ? .calibrate : .done
        default: return
        }
        duplex = run
    }

    // MARK: Messages

    func flash(_ text: String) {
        message = text
        Task {
            try? await Task.sleep(for: .seconds(6))
            if message == text { message = nil }
        }
    }

    private func notify(_ title: String, _ body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        Task {
            let center = UNUserNotificationCenter.current()
            guard (try? await center.requestAuthorization(options: [.alert])) == true else { return }
            try? await center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }
}
