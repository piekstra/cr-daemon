import Foundation

/// Scrubs GitHub token-shaped substrings from any string before it is written
/// to disk or stderr. Tokens should never be logged in the first place; this is
/// defense-in-depth in case one slips into an error message.
public enum Redact {
    private static let patterns: [NSRegularExpression] = {
        ["gh[pousr]_[A-Za-z0-9]{20,}", "github_pat_[A-Za-z0-9_]{20,}"]
            .compactMap { try? NSRegularExpression(pattern: $0) }
    }()

    public static func scrub(_ s: String) -> String {
        var out = s
        for re in patterns {
            let range = NSRange(out.startIndex..., in: out)
            out = re.stringByReplacingMatches(
                in: out, range: range, withTemplate: "***redacted***")
        }
        return out
    }
}

/// Structured JSONL logger. One JSON object per line, appended to
/// ~/Library/Logs/cr-daemon/cr-daemon.log with size-based rotation (one
/// backup). Thread-safe via a serial queue; also echoes to stderr so launchd
/// captures it. Values are redacted before write.
public final class Logger: @unchecked Sendable {
    public enum Level: String { case debug, info, warn, error }

    public static let shared = Logger()

    private let queue = DispatchQueue(label: "com.piekstra.cr-daemon.logger")
    private let fileURL: URL
    private let maxBytes: Int
    private let echoToStderr: Bool

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    public init(fileURL: URL = Paths.logFile, maxBytes: Int = 5_000_000, echoToStderr: Bool = true) {
        self.fileURL = fileURL
        self.maxBytes = maxBytes
        self.echoToStderr = echoToStderr
    }

    public func log(_ level: Level, _ event: String, _ fields: [String: Any] = [:]) {
        let ts = Self.iso.string(from: Date())
        queue.async { [self] in write(ts: ts, level: level, event: event, fields: fields) }
    }

    public func debug(_ e: String, _ f: [String: Any] = [:]) { log(.debug, e, f) }
    public func info(_ e: String, _ f: [String: Any] = [:]) { log(.info, e, f) }
    public func warn(_ e: String, _ f: [String: Any] = [:]) { log(.warn, e, f) }
    public func error(_ e: String, _ f: [String: Any] = [:]) { log(.error, e, f) }

    /// Block until every queued write has drained to disk. Writes are async on a
    /// serial queue, so a line logged immediately before a deliberate `exit()` or
    /// process teardown (daemon.shutdown, watchdog.wedged) would otherwise be lost
    /// — the process dies before its write runs. Call this right after such a line.
    public func flush() { queue.sync {} }

    private func write(ts: String, level: Level, event: String, fields: [String: Any]) {
        var obj: [String: Any] = ["ts": ts, "level": level.rawValue, "event": event]
        for (k, v) in fields { obj[k] = jsonSafe(v) }
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]),
            let raw = String(data: data, encoding: .utf8)
        else { return }
        let line = Redact.scrub(raw) + "\n"
        rotateIfNeeded()
        append(line)
        if echoToStderr { FileHandle.standardError.write(Data(line.utf8)) }
    }

    private func jsonSafe(_ v: Any) -> Any {
        switch v {
        case is Int, is Double, is Bool, is String: return v
        default: return String(describing: v)
        }
    }

    private func append(_ line: String) {
        let data = Data(line.utf8)
        let fm = FileManager.default
        if !fm.fileExists(atPath: fileURL.path) {
            try? data.write(to: fileURL)
            return
        }
        guard let fh = try? FileHandle(forWritingTo: fileURL) else { return }
        defer { try? fh.close() }
        _ = try? fh.seekToEnd()
        try? fh.write(contentsOf: data)
    }

    private func rotateIfNeeded() {
        let fm = FileManager.default
        guard let attrs = try? fm.attributesOfItem(atPath: fileURL.path),
            let size = attrs[.size] as? Int, size > maxBytes
        else { return }
        let backup = fileURL.appendingPathExtension("1")
        try? fm.removeItem(at: backup)
        try? fm.moveItem(at: fileURL, to: backup)
    }
}
