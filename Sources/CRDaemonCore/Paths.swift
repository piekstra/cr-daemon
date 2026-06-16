import Foundation

/// Canonical on-disk locations for cr-daemon. All runtime state lives under
/// Application Support; human-facing logs under ~/Library/Logs.
public enum Paths {
    public static let bundleID = "com.piekstra.cr-daemon"
    public static let appName = "cr-daemon"

    public static var appSupportDir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(appName, isDirectory: true)
    }

    public static var logsDir: URL {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent(appName, isDirectory: true)
    }

    public static var configFile: URL { appSupportDir.appendingPathComponent("config.json") }
    public static var stateFile: URL { appSupportDir.appendingPathComponent("state.json") }
    public static var eventsLog: URL { appSupportDir.appendingPathComponent("events.jsonl") }
    public static var lockFile: URL { appSupportDir.appendingPathComponent("daemon.lock") }
    public static var crashLog: URL { appSupportDir.appendingPathComponent("crash-counter.json") }
    public static var logFile: URL { logsDir.appendingPathComponent("cr-daemon.log") }

    /// Create the state + log directories if missing. Safe to call repeatedly.
    @discardableResult
    public static func ensureDirectories() -> Bool {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: appSupportDir, withIntermediateDirectories: true)
            try fm.createDirectory(at: logsDir, withIntermediateDirectories: true)
            return true
        } catch {
            FileHandle.standardError.write(Data("cr-daemon: failed to create directories: \(error)\n".utf8))
            return false
        }
    }
}
