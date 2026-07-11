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
    private let maxConcurrency: Int
    private let log: Logger
    private let childEnv: [String: String]
    private let checkouts: CheckoutManager

    private let lock = NSLock()
    /// All in-flight `cr` processes (reviews now run in parallel across PRs).
    private var running: [(process: Process, key: PRKey?)] = []

    public init(
        crPath: String = ReviewRunner.resolveCRPath(),
        profile: String,
        timeout: TimeInterval,
        maxConcurrency: Int = 4,
        log: Logger = .shared
    ) {
        self.crPath = crPath
        self.profile = profile
        self.timeout = timeout
        self.maxConcurrency = maxConcurrency
        self.log = log
        self.childEnv = ReviewRunner.childEnvironment()
        self.checkouts = CheckoutManager(log: log, environment: self.childEnv)
    }

    /// Environment for `cr` (and the `claude`/`git`/`gh` it shells out to).
    /// launchd starts the daemon with a minimal PATH that omits user tool dirs,
    /// so we prepend the common ones — otherwise `cr`'s LLM adapter can't find
    /// `claude` ("executable file not found in $PATH"). We start from the full
    /// inherited environment and only adjust PATH.
    static func childEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let home = env["HOME"] ?? NSHomeDirectory()
        let prepend = [
            "\(home)/.local/bin",
            "\(home)/.bun/bin",
            "/opt/homebrew/bin",
            "/opt/homebrew/sbin",
            "/usr/local/bin",
            "/usr/bin", "/bin", "/usr/sbin", "/sbin",
        ]
        let existing = (env["PATH"] ?? "").split(separator: ":").map(String.init)
        var seen = Set<String>()
        env["PATH"] = (prepend + existing).filter { seen.insert($0).inserted }.joined(separator: ":")
        return env
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
        return !running.isEmpty
    }

    public var runningKeys: [PRKey] {
        lock.lock(); defer { lock.unlock() }
        return running.compactMap { $0.key }
    }

    /// The login `cr` would post as for the configured profile, or nil if it
    /// can't be resolved. The Coordinator refuses to run reviews unless this
    /// equals the configured reviewer login (so cr never self-reviews as you).
    public func resolvedIdentity(profile: String? = nil) -> String? {
        // Retry a few times. `cr me` resolves identity via a GitHub call, so a
        // transient blip (timeout, 5xx, model/provider hiccup) would otherwise
        // wrongly fail the startup identity guard or tier validation and disable
        // the daemon — or a labeled tier — for the entire session. A genuine
        // misconfiguration still fails after the retries.
        for attempt in 0..<3 {
            let r = Subprocess.run(
                crPath, ["me", "--profile", profile ?? self.profile, "--json"], timeout: 30,
                environment: childEnv)
            if r.succeeded,
                let obj = try? JSONSerialization.jsonObject(with: Data(r.stdout.utf8))
                    as? [String: Any],
                let profiles = obj["profiles"] as? [[String: Any]],
                let first = profiles.first,
                let login = first["login"] as? String
            {
                return login
            }
            if attempt < 2 { Thread.sleep(forTimeInterval: 2) }
        }
        return nil
    }

    /// `cr` version string (for drift detection / logging).
    public func crVersion() -> String {
        Subprocess.run(crPath, ["version"], timeout: 10, environment: childEnv)
            .stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func runReview(
        url: String, profile: String? = nil, dryRun: Bool = false, rerun: Bool = false,
        timeoutOverride: TimeInterval? = nil, onLaunch: (@Sendable (Int32) -> Void)? = nil
    ) async -> RunResult {
        let p = profile ?? self.profile
        var args = ["review", url, "--profile", p, "--json", "--max-concurrency", String(maxConcurrency)]
        // Reuse a per-PR LLM session so each re-review carries context of this
        // PR's prior reviews — the reviewer can resolve its own earlier points
        // instead of waffling (raising A, then later calling A wrong). Skipped for
        // --rerun, which bypasses resume gates, and for dry-runs.
        if !dryRun, !rerun, let key = PRKey.parse(url: url) {
            args.append(contentsOf: ["--session", "\(key.owner)-\(key.repo)-\(key.number)"])
        }
        if dryRun { args.append("--dry-run") }
        if rerun { args.append("--rerun") }
        return await execute(
            args: args, key: PRKey.parse(url: url), timeoutOverride: timeoutOverride,
            onLaunchPid: onLaunch)
    }

    /// Recovery-only: re-post any missing/failed required posts for an existing
    /// run without re-reviewing or re-checking approvals.
    public func retryPosts(url: String, profile: String? = nil) async -> RunResult {
        await execute(
            args: ["review", url, "--profile", profile ?? self.profile, "--json", "--retry-posts"],
            key: PRKey.parse(url: url))
    }

    /// SIGTERM every in-flight `cr` process tree. Used on sleep; the
    /// assignments are re-queued and recovered via `--retry-posts` on wake.
    /// Tree-kill matters: cr's specialist subprocesses must not outlive it.
    public func cancelAll() {
        lock.lock()
        let procs = running.map { $0.process }
        lock.unlock()
        for p in procs {
            log.warn("review.cancel", ["pid": Int(p.processIdentifier)])
            Subprocess.killTree(p.processIdentifier, signal: SIGTERM)
        }
    }

    private func execute(
        args: [String], key: PRKey?, timeoutOverride: TimeInterval? = nil,
        onLaunchPid: (@Sendable (Int32) -> Void)? = nil
    ) async -> RunResult {
        await withCheckedContinuation { (cont: CheckedContinuation<RunResult, Never>) in
            DispatchQueue.global().async { [self] in
                // Checkout-native cr must run from inside a clone of the repo
                // under review; provide (and refresh) the managed clone.
                var cwd: String?
                if let key {
                    cwd = checkouts.ensureCheckout(owner: key.owner, repo: key.repo)
                }
                var launched: Process?
                let r = Subprocess.run(
                    crPath, args, timeout: timeoutOverride ?? timeout, environment: childEnv,
                    currentDirectory: cwd,
                    onLaunch: { proc in
                        self.lock.lock()
                        launched = proc
                        self.running.append((process: proc, key: key))
                        self.lock.unlock()
                        onLaunchPid?(proc.processIdentifier)
                    })
                self.lock.lock()
                if let launched {
                    self.running.removeAll { $0.process === launched }
                }
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
