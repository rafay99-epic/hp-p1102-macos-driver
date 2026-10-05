import Foundation

/// Counters for tools/perf. Off (and free) unless PRINTERBAR_PERF is set;
/// then they are printed to stderr when the app exits.
public enum Perf {
    public static let enabled = ProcessInfo.processInfo.environment["PRINTERBAR_PERF"] != nil
    private static let lock = NSLock()
    nonisolated(unsafe) private static var counts: [String: Int] = [:]

    public static func count(_ key: String, _ n: Int = 1) {
        guard enabled else { return }
        lock.withLock { counts[key, default: 0] += n }
    }

    /// Runs `body` and adds its duration in microseconds to `key.us`.
    public static func time<T>(_ key: String, _ body: () throws -> T) rethrows -> T {
        guard enabled else { return try body() }
        let start = DispatchTime.now().uptimeNanoseconds
        defer { count(key + ".us", Int((DispatchTime.now().uptimeNanoseconds - start) / 1000)); count(key) }
        return try body()
    }

    /// Prints a wall-clock timestamp right away, e.g. "first refresh done".
    public static func mark(_ name: String) {
        guard enabled else { return }
        FileHandle.standardError.write(Data("PERF \(name)_epoch_ms \(Int(Date().timeIntervalSince1970 * 1000))\n".utf8))
    }

    public static func dump() {
        guard enabled else { return }
        lock.withLock {
            for (k, v) in counts.sorted(by: { $0.key < $1.key }) { FileHandle.standardError.write(Data("PERF \(k) \(v)\n".utf8)) }
        }
    }
}
