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
            // Advance the checked-out default branch to origin's: cr reads
            // repo-local trusted review agents (.codereview/) from this
            // working tree, so a fetch-only refresh pins agents (and their
            // prompts) to whenever the clone happened. reset --hard is safe —
            // this clone is daemon-owned, never hand-edited — and unlike a
            // ff-only pull it also follows force-pushed branches.
            let branch = Subprocess.run(
                "/usr/bin/git", ["-C", dir.path, "rev-parse", "--abbrev-ref", "HEAD"],
                timeout: 10, environment: env
            ).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            if !branch.isEmpty, branch != "HEAD" {
                let rr = Subprocess.run(
                    "/usr/bin/git", ["-C", dir.path, "reset", "--hard", "origin/\(branch)"],
                    timeout: 60, environment: env)
                if !rr.succeeded {
                    log.warn(
                        "checkout.advance_failed",
                        ["repo": "\(owner)/\(repo)", "stderr": String(rr.stderr.prefix(300))])
                }
            }
            return dir.path
        }

        try? fm.createDirectory(at: Self.checkoutsDir, withIntermediateDirectories: true)
        // Full clone, not --filter=blob:none: cr prepares its workbench by
        // locally cloning THIS repo, and a clone of a partial/promisor repo
        // is left with missing blobs that make its pinned checkout look dirty
        // ("pipeline: workbench has local changes").
        let r = Subprocess.run(
            "/usr/bin/git",
            ["clone", "https://github.com/\(owner)/\(repo).git", dir.path],
            timeout: 600, environment: env)
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
