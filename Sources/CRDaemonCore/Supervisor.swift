import Foundation

/// Process-lifecycle guards: single-instance locking and a crash-loop circuit
/// breaker. launchd is the primary supervisor (KeepAlive only on crash,
/// ThrottleInterval between relaunches); these are belt-and-suspenders.
public enum Supervisor {
    /// Acquire an exclusive advisory lock so only one cr-daemon runs. Returns the
    /// open file descriptor (KEEP IT OPEN for the process lifetime — closing it
    /// releases the lock), or nil if another instance already holds it.
    public static func acquireSingleInstanceLock(at url: URL = Paths.lockFile) -> Int32? {
        Paths.ensureDirectories()
        let fd = open(url.path, O_CREAT | O_RDWR, 0o644)
        guard fd >= 0 else { return nil }
        if flock(fd, LOCK_EX | LOCK_NB) != 0 {
            close(fd)
            return nil
        }
        return fd
    }

    private struct CrashRecord: Codable {
        var startups: [Date]
    }

    /// Record a startup and report whether we're in a crash loop. If more than
    /// `threshold` startups happened within `windowSeconds`, the app should enter
    /// safe mode (stop auto-work, show an error) instead of thrashing.
    public static func recordStartupAndDetectCrashLoop(
        at url: URL = Paths.crashLog,
        now: Date = Date(),
        windowSeconds: TimeInterval = 180,
        threshold: Int = 4
    ) -> Bool {
        Paths.ensureDirectories()
        var record = (try? Data(contentsOf: url))
            .flatMap { try? JSONDecoder().decode(CrashRecord.self, from: $0) }
            ?? CrashRecord(startups: [])

        let cutoff = now.addingTimeInterval(-windowSeconds)
        record.startups = record.startups.filter { $0 >= cutoff }
        record.startups.append(now)

        if let data = try? JSONEncoder().encode(record) {
            try? data.write(to: url, options: .atomic)
        }
        return record.startups.count > threshold
    }

    /// Clear the crash counter once we've run healthily for a while.
    public static func clearCrashCounter(at url: URL = Paths.crashLog) {
        try? FileManager.default.removeItem(at: url)
    }

    /// True if a process with this pid is currently alive (signal 0 probe).
    public static func isPidAlive(_ pid: Int32) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }
}
