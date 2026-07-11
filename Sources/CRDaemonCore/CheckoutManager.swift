import Foundation

/// Maintains local clones of reviewed repositories.
///
/// cr >= 0.10.243 is checkout-native: `cr review` must run from inside a Git
/// worktree of the repo under review (it resolves the base remote from that
/// clone and prepares its own pinned workbench from it). The daemon has no
/// natural working copy, so this manager keeps one blobless clone per repo
/// under Application Support and hands its path to ReviewRunner as the child
/// process working directory.
public final class CheckoutManager: @unchecked Sendable {
    private let log: Logger
    private let env: [String: String]
    private let lock = NSLock()

    public init(log: Logger = .shared, environment: [String: String]) {
        self.log = log
        // Never let git block a headless daemon on a credential prompt.
        var env = environment
        env["GIT_TERMINAL_PROMPT"] = "0"
        self.env = env
    }

    public static var checkoutsDir: URL {
        Paths.appSupportDir.appendingPathComponent("checkouts", isDirectory: true)
    }

    /// Directory for one repo's clone, e.g. `checkouts/piekstra__utiman`.
    static func dir(owner: String, repo: String) -> URL {
        checkoutsDir.appendingPathComponent("\(owner)__\(repo)", isDirectory: true)
    }

    /// Ensure a usable clone of `owner/repo` exists and is fresh enough for a
    /// review, returning its path — or nil when cloning fails (the review then
    /// runs without a working directory and fails with cr's own diagnostic).
    /// Serialized: the Coordinator only runs one review at a time, and clone
    /// vs fetch on the same directory must not interleave regardless.
    public func ensureCheckout(owner: String, repo: String) -> String? {
        lock.lock()
        defer { lock.unlock() }

        let fm = FileManager.default
        let dir = Self.dir(owner: owner, repo: repo)
        let gitDir = dir.appendingPathComponent(".git")

        if fm.fileExists(atPath: gitDir.path) {
            // Refresh best-effort; a stale clone is still a valid worktree and
            // cr does its own pinned fetches for the commits it reviews.
            let r = Subprocess.run(
                "/usr/bin/git", ["-C", dir.path, "fetch", "--prune", "origin"],
                timeout: 120, environment: env)
            if !r.succeeded {
                log.warn(
                    "checkout.fetch_failed",
                    ["repo": "\(owner)/\(repo)", "stderr": String(r.stderr.prefix(300))])
            }
            return dir.path
        }

        try? fm.createDirectory(at: Self.checkoutsDir, withIntermediateDirectories: true)
        // Blobless partial clone: full history/trees for ref math, blobs on
        // demand — keeps per-repo disk cost small.
        let r = Subprocess.run(
            "/usr/bin/git",
            [
                "clone", "--filter=blob:none",
                "https://github.com/\(owner)/\(repo).git", dir.path,
            ],
            timeout: 300, environment: env)
        if !r.succeeded {
            log.error(
                "checkout.clone_failed",
                ["repo": "\(owner)/\(repo)", "stderr": String(r.stderr.prefix(300))])
            try? fm.removeItem(at: dir)
            return nil
        }
        log.info("checkout.cloned", ["repo": "\(owner)/\(repo)"])
        return dir.path
    }
}
