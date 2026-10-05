import Foundation

/// Queue settings changed through the CUPS command line tools. Admin users
/// can run these without a password; only installing the driver needs one.
public enum Queue {
    public struct Defaults: Equatable, Sendable {
        public var paper = "A4"
        public var mediaType = "Plain"
        public var density = "3"
        public var tonerSave = false
        public init() {}
    }

    public static let papers = ["A4", "Letter", "Legal"]
    public static let mediaTypes = ["Plain", "Light", "Heavy", "Recycled", "Rough", "Labels", "Envelope", "Transparency"]

    /// The queue's current defaults. These are what every app's print dialog starts with.
    public static func defaults() -> Defaults {
        parseDefaults(run("/usr/bin/lpoptions", "-p", Driver.queue, "-l").output)
    }

    public static func setDefaults(_ d: Defaults) -> Bool {
        run("/usr/sbin/lpadmin", "-p", Driver.queue,
            "-o", "PageSize-default=\(d.paper)", "-o", "PageRegion-default=\(d.paper)",
            "-o", "MediaType-default=\(d.mediaType)", "-o", "Density-default=\(d.density)",
            "-o", "TonerSave-default=\(d.tonerSave ? "True" : "False")").ok
    }

    /// Holds waiting and new jobs; the sheet being printed finishes.
    public static func pause(waiting: [Int]) {
        run("/usr/sbin/cupsdisable", "--hold", Driver.queue)
        waiting.forEach { Cups.hold($0) }
    }

    public static func resume(held: [Int]) {
        run("/usr/sbin/cupsenable", "--release", Driver.queue)
        held.forEach { Cups.release($0) }
    }

    /// Restarts a queue CUPS stopped after a backend error.
    public static func enable() { run("/usr/sbin/cupsenable", Driver.queue) }

    public static func makeDefaultPrinter() { run("/usr/sbin/lpadmin", "-d", Driver.queue) }

    /// Other queues pointing at the P1102, e.g. one macOS added by itself.
    public static func extraQueues() -> [String] {
        // lpstat -v: "device for NAME: URI"
        run("/usr/bin/lpstat", "-v").output.split(separator: "\n").compactMap { line in
            guard line.contains("HP%20LaserJet%20Professional%20P1102"),
                  let name = line.split(separator: ":").first?.split(separator: " ").last,
                  name != Driver.queue else { return nil }
            return String(name)
        }
    }

    public static func remove(_ queue: String) -> Bool { run("/usr/sbin/lpadmin", "-x", queue).ok }

    /// Parses `lpoptions -l` lines like "PageSize/Paper Size: Letter Legal *A4".
    static func parseDefaults(_ text: String) -> Defaults {
        var d = Defaults()
        for line in text.split(separator: "\n") {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].split(separator: "/").first.map(String.init) ?? ""
            guard let value = line[line.index(after: colon)...].split(separator: " ")
                .first(where: { $0.hasPrefix("*") })?.dropFirst() else { continue }
            switch key {
            case "PageSize": d.paper = String(value)
            case "MediaType": d.mediaType = String(value)
            case "Density": d.density = String(value)
            case "TonerSave": d.tonerSave = value == "True"
            default: break
            }
        }
        return d
    }

    @discardableResult
    static func run(_ tool: String, _ args: String...) -> (ok: Bool, output: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        do { try p.run() } catch { return (false, "") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus == 0, String(decoding: data, as: UTF8.self))
    }
}
