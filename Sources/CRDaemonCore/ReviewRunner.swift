import Foundation

/// Runs `cr review` for a single PR. One review at a time (the Coordinator
/// serializes), but this class holds the live process handle so a review can be
/// cancelled externally — e.g. SIGTERM'd on sleep, then recovered with
/// `--retry-posts` on wake. Never puts a token on argv: `cr` reads its
/// credential from its own store via the configured profile.
public final class ReviewRunner: @unchecked Sendable {
    public struct RunResult: Sendable {
        public let exitCode: Int32
        public let timedOut: Bool
        public let stdout: String
        public let stderr: String
        public var succeeded: Bool { exitCode == 0 && !timedOut }
    }

    private let crPath: String
    private let profile: String
    private let timeout: TimeInterval
    private let log: Logger

    private let lock = NSLock()
    private var currentProcess: Process?
    private var currentKey: PRKey?

    public init(
        crPath: String = ReviewRunner.resolveCRPath(),
        profile: String,
        timeout: TimeInterval,
        log: Logger = .shared
    ) {
        self.crPath = crPath
        self.profile = profile
        self.timeout = timeout
        self.log = log
    }

    /// Locate the `cr` binary. Homebrew installs to /opt/homebrew/bin on Apple
    /// Silicon; fall back to a PATH lookup.
    public static func resolveCRPath() -> String {
        for p in ["/opt/homebrew/bin/cr", "/usr/local/bin/cr"] {
            if FileManager.default.isExecutableFile(atPath: p) { return p }
        }
        let r = Subprocess.run("/usr/bin/which", ["cr"], timeout: 5)
        let path = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? "/opt/homebrew/bin/cr" : path
    }

    public var crBinaryPath: String { crPath }

    public var isRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        return currentProcess != nil
    }

    public var runningKey: PRKey? {
        lock.lock(); defer { lock.unlock() }
        return currentKey
    }

    /// The login `cr` would post as for the configured profile, or nil if it
    /// can't be resolved. The Coordinator refuses to run reviews unless this
    /// equals the configured reviewer login (so cr never self-reviews as you).
    public func resolvedIdentity() -> String? {
        let r = Subprocess.run(crPath, ["me", "--profile", profile, "--json"], timeout: 30)
        guard r.succeeded,
            let obj = try? JSONSerialization.jsonObject(with: Data(r.stdout.utf8)) as? [String: Any],
            let profiles = obj["profiles"] as? [[String: Any]],
            let first = profiles.first
        else { return nil }
        return first["login"] as? String
    }

    /// `cr` version string (for drift detection / logging).
    public func crVersion() -> String {
        Subprocess.run(crPath, ["version"], timeout: 10)
            .stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func runReview(url: String, dryRun: Bool = false, rerun: Bool = false) async -> RunResult {
        var args = ["review", url, "--profile", profile, "--json", "--max-concurrency", "1"]
        if dryRun { args.append("--dry-run") }
        if rerun { args.append("--rerun") }
        return await execute(args: args, key: PRKey.parse(url: url))
    }

    /// Recovery-only: re-post any missing/failed required posts for an existing
    /// run without re-reviewing or re-checking approvals.
    public func retryPosts(url: String) async -> RunResult {
        await execute(
            args: ["review", url, "--profile", profile, "--json", "--retry-posts"],
            key: PRKey.parse(url: url))
    }

    /// SIGTERM the in-flight `cr` process. Used on sleep; the assignment is
    /// re-queued and recovered via `--retry-posts` on wake.
    public func cancelCurrent() {
        lock.lock()
        let p = currentProcess
        lock.unlock()
        if let p {
            log.warn("review.cancel", ["pid": Int(p.processIdentifier)])
            p.terminate()
        }
    }

    private func execute(args: [String], key: PRKey?) async -> RunResult {
        await withCheckedContinuation { (cont: CheckedContinuation<RunResult, Never>) in
            DispatchQueue.global().async { [self] in
                let r = Subprocess.run(
                    crPath, args, timeout: timeout,
                    onLaunch: { proc in
                        self.lock.lock()
                        self.currentProcess = proc
                        self.currentKey = key
                        self.lock.unlock()
                    })
                self.lock.lock()
                self.currentProcess = nil
                self.currentKey = nil
                self.lock.unlock()
                cont.resume(
                    returning: RunResult(
                        exitCode: r.exitCode, timedOut: r.timedOut,
                        stdout: r.stdout, stderr: r.stderr))
            }
        }
    }
}

extension ReviewOutcome {
    /// Map a GitHub review `state` string to our outcome enum.
    public static func from(reviewState: String?) -> ReviewOutcome {
        switch reviewState?.uppercased() {
        case "APPROVED": return .approved
        case "CHANGES_REQUESTED": return .changesRequested
        case "COMMENTED": return .commented
        default: return .unknown
        }
    }
}
