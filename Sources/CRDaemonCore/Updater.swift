import Foundation

/// Keeps the Homebrew-installed `cr` CLI from silently rotting. A stale `cr`
/// once hit a bug fixed upstream and the daemon gave up on the PR; this surfaces
/// "an update is available" and offers a one-click `brew upgrade`. Pure parsing
/// helpers (parseSemver/isNewer) are split out so they're unit-testable without
/// the network.
public final class Updater: @unchecked Sendable {
    /// GitHub releases API for the public cr repo. No auth token: a public repo's
    /// latest-release endpoint is reachable unauthenticated (low rate, plenty for
    /// a 6-hourly check).
    private static let latestReleaseURL =
        "https://api.github.com/repos/open-cli-collective/codereview-cli/releases/latest"

    private let session: URLSession
    private let log: Logger
    private let childEnv: [String: String]

    public init(log: Logger = .shared) {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 15
        cfg.timeoutIntervalForResource = 15
        cfg.waitsForConnectivity = false
        self.session = URLSession(configuration: cfg)
        self.log = log
        self.childEnv = Updater.upgradeEnvironment()
    }

    // MARK: - Pure version helpers (unit-tested)

    /// Extract a `MAJOR.MINOR.PATCH` semver from a `cr version` string
    /// (`"cr 0.4.161 (<sha>, <date>)"`) or a release tag (`"v0.4.161"`). Returns
    /// nil when no dotted numeric version is present.
    public static func parseSemver(_ raw: String) -> String? {
        // First dotted run of digits, e.g. 0.4.161 (also matches 1.2 → "1.2").
        guard
            let re = try? NSRegularExpression(pattern: #"\d+(?:\.\d+)+"#),
            let m = re.firstMatch(
                in: raw, range: NSRange(raw.startIndex..., in: raw)),
            let r = Range(m.range, in: raw)
        else { return nil }
        return String(raw[r])
    }

    /// Numeric dotted comparison: is `a` a newer version than `b`? Compares each
    /// component as an integer (so 0.4.10 > 0.4.9), padding the shorter with 0s.
    public static func isNewer(_ a: String, than b: String) -> Bool {
        let lhs = a.split(separator: ".").map { Int($0) ?? 0 }
        let rhs = b.split(separator: ".").map { Int($0) ?? 0 }
        let n = max(lhs.count, rhs.count)
        for i in 0..<n {
            let x = i < lhs.count ? lhs[i] : 0
            let y = i < rhs.count ? rhs[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    // MARK: - Latest release lookup

    /// GET the cr repo's latest release and return its parsed semver, or nil on
    /// any error (network, non-200, missing/garbled `tag_name`). Never throws —
    /// an update check must never crash or block the daemon.
    public func latestReleaseVersion() async -> String? {
        guard let url = URL(string: Self.latestReleaseURL) else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("cr-daemon", forHTTPHeaderField: "User-Agent")
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        do {
            let (data, resp) = try await session.data(for: req)
            guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                return nil
            }
            guard
                let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                let tag = obj["tag_name"] as? String
            else { return nil }
            return Self.parseSemver(tag)
        } catch {
            log.warn("updater.latest_failed", ["error": String(describing: error)])
            return nil
        }
    }

    // MARK: - Upgrade

    /// `brew update` then `brew upgrade --cask codereview-cli`. Long-running
    /// (minutes); the Coordinator runs it detached. Returns overall success plus
    /// the tail of combined output for the menu/log.
    public func upgradeCR() async -> (ok: Bool, output: String) {
        await withCheckedContinuation { (cont: CheckedContinuation<(ok: Bool, output: String), Never>) in
            DispatchQueue.global().async { [self] in
                let brew = Updater.resolveBrewPath()
                let update = Subprocess.run(brew, ["update"], timeout: 300, environment: childEnv)
                let upgrade = Subprocess.run(
                    brew, ["upgrade", "--cask", "codereview-cli"], timeout: 1800,
                    environment: childEnv)
                let combined = [
                    "$ brew update", update.stdout, update.stderr,
                    "$ brew upgrade --cask codereview-cli", upgrade.stdout, upgrade.stderr,
                ].joined(separator: "\n")
                let tail = Redact.scrub(String(combined.suffix(1200)))
                cont.resume(returning: (ok: upgrade.succeeded, output: tail))
            }
        }
    }

    /// Locate `brew`. Apple Silicon installs to /opt/homebrew/bin; fall back to
    /// the legacy Intel path.
    static func resolveBrewPath() -> String {
        for p in ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"] {
            if FileManager.default.isExecutableFile(atPath: p) { return p }
        }
        return "/opt/homebrew/bin/brew"
    }

    /// Environment for `brew`: launchd hands us a minimal PATH, so prepend the
    /// Homebrew bin dirs (brew lives at /opt/homebrew/bin). Mirrors
    /// ReviewRunner.childEnvironment — kept independent so a PATH change in one
    /// can't silently break the other.
    static func upgradeEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let prepend = [
            "/opt/homebrew/bin", "/opt/homebrew/sbin",
            "/usr/local/bin",
            "/usr/bin", "/bin", "/usr/sbin", "/sbin",
        ]
        let existing = (env["PATH"] ?? "").split(separator: ":").map(String.init)
        var seen = Set<String>()
        env["PATH"] = (prepend + existing).filter { seen.insert($0).inserted }.joined(separator: ":")
        return env
    }
}
