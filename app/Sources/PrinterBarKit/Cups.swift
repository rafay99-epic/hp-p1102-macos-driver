import CCups
import Foundation

/// Where the driver lives once installed. Must match driver/install.sh.
public enum Driver {
    /// PRINTERBAR_QUEUE points the app at another queue (tools/perf uses a throwaway one).
    public static let queue = ProcessInfo.processInfo.environment["PRINTERBAR_QUEUE"] ?? "HP_LaserJet_P1102"
    public static let encoder = "/Library/Printers/HP-P1102/bin/foo2zjs"
    public static let filter = "/Library/Printers/HP-P1102/filter/rastertozjs"
    public static let ppd = "/Library/Printers/PPDs/Contents/Resources/HP-LaserJet-P1102.ppd"
    public static let deviceURI = "usb://Hewlett-Packard/HP%20LaserJet%20Professional%20P1102"
}

public struct Job: Identifiable, Equatable, Sendable {
    public enum State: Int, Sendable {
        case pending = 3, held, processing, stopped, canceled, aborted, completed
    }
    public let id: Int
    public let name: String
    public let state: State
    public let sheetsDone: Int
    public let created: Date
    public let completed: Date?
    public let reasons: [String]

    public init(id: Int, name: String, state: State, sheetsDone: Int, created: Date, completed: Date?, reasons: [String]) {
        self.id = id; self.name = name; self.state = state; self.sheetsDone = sheetsDone
        self.created = created; self.completed = completed; self.reasons = reasons
    }

    public var isActive: Bool { state.rawValue <= State.stopped.rawValue }
    public var failed: Bool { state == .aborted || state == .canceled }
}

public struct PrinterStatus: Equatable, Sendable {
    public enum State: Int, Sendable { case idle = 3, processing, stopped }
    public let state: State
    public let reasons: [String]
    public let message: String
    public let defaults: Queue.Defaults

    public init(state: State, reasons: [String], message: String, defaults: Queue.Defaults = .init()) {
        self.state = state; self.reasons = reasons; self.message = message; self.defaults = defaults
    }

    public var holdingNewJobs: Bool { reasons.contains("hold-new-jobs") }

    /// Reasons that mean a person has to do something. CUPS reports many
    /// informational keywords ("none", "cups-waiting-for-job-completed", ...)
    /// that must not light up the attention state.
    public var problems: [String] {
        reasons.map { $0.replacingOccurrences(of: "-error", with: "")
                       .replacingOccurrences(of: "-warning", with: "") }
            .filter { ["media-empty", "media-jam", "media-needed", "door-open", "cover-open",
                       "toner-empty", "offline", "other"].contains($0) }
    }
}

/// Thin Swift layer over libcups. Everything talks to the local cupsd.
public enum Cups {
    static let printerURI = "ipp://localhost/printers/\(Driver.queue)"

    /// nil when the queue does not exist. Also returns the queue defaults:
    /// cupsd reports every option set with `lpadmin -o X-default=` as an
    /// X-default attribute; an absent one means the PPD default, which is what
    /// Queue.Defaults() holds. Cheaper than running lpoptions.
    public static func printer() -> PrinterStatus? {
        guard let a = request(IPP_OP_GET_PRINTER_ATTRIBUTES, { req in
            addKeywords(req, "requested-attributes", ["printer-state", "printer-state-reasons", "printer-state-message",
                                                      "PageSize-default", "MediaType-default", "Density-default",
                                                      "TonerSave-default"])
        }).first else { return nil }
        var d = Queue.Defaults()
        d.paper = a.string("PageSize-default") ?? d.paper
        d.mediaType = a.string("MediaType-default") ?? d.mediaType
        d.density = a.string("Density-default") ?? d.density
        d.tonerSave = a.int("TonerSave-default").map { $0 != 0 } ?? d.tonerSave
        return PrinterStatus(
            state: PrinterStatus.State(rawValue: a.int("printer-state") ?? 3) ?? .idle,
            reasons: a.strings["printer-state-reasons"] ?? [],
            message: a.string("printer-state-message") ?? "",
            defaults: d)
    }

    public static func jobs(completed: Bool) -> [Job] {
        request(IPP_OP_GET_JOBS) { req in
            ippAddString(req, IPP_TAG_OPERATION, IPP_TAG_KEYWORD, "which-jobs", nil,
                         completed ? "completed" : "not-completed")
            // Only what PrinterBar shows. "all" makes cupsd load every job's
            // attributes from disk: ~130 ms with a 500-job history vs ~17 ms.
            addKeywords(req, "requested-attributes", ["job-id", "job-name", "job-state", "job-state-reasons",
                                                      "job-media-sheets-completed", "time-at-creation", "time-at-completed"])
        }.compactMap { a in
            guard let id = a.int("job-id") else { return nil }
            return Job(
                id: id,
                name: a.string("job-name") ?? "Untitled",
                state: Job.State(rawValue: a.int("job-state") ?? 3) ?? .pending,
                sheetsDone: a.int("job-media-sheets-completed") ?? 0,
                created: Date(timeIntervalSince1970: TimeInterval(a.int("time-at-creation") ?? 0)),
                completed: a.int("time-at-completed").flatMap { $0 > 0 ? Date(timeIntervalSince1970: TimeInterval($0)) : nil },
                reasons: a.strings["job-state-reasons"] ?? [])
        }
    }

    /// Submits a file and returns its job id.
    public static func submit(_ file: URL, title: String, options: [String: String]) throws -> Int {
        var opts: UnsafeMutablePointer<cups_option_t>?
        var count: Int32 = 0
        for (k, v) in options { count = cupsAddOption(k, v, count, &opts) }
        defer { cupsFreeOptions(count, opts) }
        let id = cupsPrintFile(Driver.queue, file.path, title, count, opts)
        guard id > 0 else { throw CupsError(lastError) }
        return Int(id)
    }

    @discardableResult public static func cancel(_ id: Int) -> Bool {
        cupsCancelJob2(nil, Driver.queue, Int32(id), 0) == IPP_STATUS_OK
    }

    @discardableResult public static func restart(_ id: Int) -> Bool { jobOp(IPP_OP_RESTART_JOB, id) }
    @discardableResult public static func hold(_ id: Int) -> Bool { jobOp(IPP_OP_HOLD_JOB, id) }
    @discardableResult public static func release(_ id: Int) -> Bool { jobOp(IPP_OP_RELEASE_JOB, id) }

    /// Moves a waiting job to the front (CUPS prints higher priority first).
    @discardableResult public static func printNext(_ id: Int) -> Bool {
        jobOp(IPP_OP_SET_JOB_ATTRIBUTES, id) { req in
            ippAddInteger(req, IPP_TAG_JOB, IPP_TAG_INTEGER, "job-priority", 100)
        }
    }

    public static var lastError: String { String(cString: cupsLastErrorString()) }

    // MARK: IPP plumbing

    private static func addKeywords(_ req: OpaquePointer, _ name: String, _ values: [String]) {
        let strings = values.map { strdup($0) }
        defer { strings.forEach { free($0) } }
        strings.map { UnsafePointer($0) }.withUnsafeBufferPointer { buf in
            _ = ippAddStrings(req, IPP_TAG_OPERATION, IPP_TAG_KEYWORD, name, Int32(values.count), nil, buf.baseAddress)
        }
    }

    private static func jobOp(_ op: ipp_op_t, _ id: Int, _ extra: (OpaquePointer) -> Void = { _ in }) -> Bool {
        _ = request(op) { req in
            ippAddInteger(req, IPP_TAG_OPERATION, IPP_TAG_INTEGER, "job-id", Int32(id))
            extra(req)
        }
        return cupsLastError().rawValue < 0x0100
    }

    /// Sends one IPP request about our queue and returns one attribute set per
    /// printer or job group in the response.
    private static func request(_ op: ipp_op_t, _ configure: (OpaquePointer) -> Void = { _ in }) -> [Attributes] {
        guard let req = ippNewRequest(op) else { return [] }
        ippAddString(req, IPP_TAG_OPERATION, IPP_TAG_URI, "printer-uri", nil, printerURI)
        ippAddString(req, IPP_TAG_OPERATION, IPP_TAG_NAME, "requesting-user-name", nil, cupsUser())
        configure(req)
        guard let resp = Perf.time("ipp.\(String(cString: ippOpString(op)))", { cupsDoRequest(nil, req, "/") }) else { return [] }
        defer { ippDelete(resp) }
        guard ippGetStatusCode(resp).rawValue < 0x0100 else { return [] }

        var groups: [Attributes] = []
        var current: Attributes?
        var attr = ippFirstAttribute(resp)
        while let a = attr {
            let group = ippGetGroupTag(a)
            if let name = ippGetName(a), group == IPP_TAG_PRINTER || group == IPP_TAG_JOB {
                var set = current ?? Attributes()
                set.add(String(cString: name), a)
                current = set
            } else if let c = current {
                groups.append(c)
                current = nil
            }
            attr = ippNextAttribute(resp)
        }
        if let c = current { groups.append(c) }
        return groups
    }
}

struct Attributes {
    var ints: [String: Int] = [:]
    var strings: [String: [String]] = [:]

    func int(_ name: String) -> Int? { ints[name] }
    func string(_ name: String) -> String? { strings[name]?.first }

    mutating func add(_ name: String, _ a: OpaquePointer) {
        let tag = ippGetValueTag(a)
        if tag == IPP_TAG_INTEGER || tag == IPP_TAG_ENUM {
            ints[name] = Int(ippGetInteger(a, 0))
        } else if tag == IPP_TAG_BOOLEAN {
            ints[name] = Int(ippGetBoolean(a, 0))
        } else {
            strings[name] = (0..<ippGetCount(a)).compactMap { i in
                ippGetString(a, i, nil).map { String(cString: $0) }
            }
        }
    }
}

public struct CupsError: LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}
