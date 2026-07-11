import Foundation

/// Default action taken when a PR is assigned to the reviewer.
public enum Autonomy: String, Codable, Sendable {
    case auto      // run a live `cr review` automatically; cr's policy decides approve/comment
    case confirm   // run `cr review --dry-run` and wait for the user to post from the menu
}

/// Which events raise a macOS notification.
public struct NotifyOptions: Codable, Equatable, Sendable {
    public var approvals: Bool
    public var findings: Bool
    public var errors: Bool

    public init(approvals: Bool = true, findings: Bool = true, errors: Bool = true) {
        self.approvals = approvals
        self.findings = findings
        self.errors = errors
    }
}

/// User-facing configuration, persisted as snake_case JSON at
/// ~/Library/Application Support/cr-daemon/config.json (hot-reloadable).
public struct Config: Codable, Equatable, Sendable {
    /// GitHub login of the reviewer machine account (e.g. "piekstra-dev").
    public var reviewerLogin: String
    /// Keychain account name for the watcher's token (service is always "cr-daemon").
    public var reviewerKeychainAccount: String
    /// cr profile the daemon invokes (`cr review --profile <crProfile>`).
    public var crProfile: String
    /// Allowlist of orgs/owners whose PRs the daemon will act on (case-insensitive).
    public var orgs: [String]
    /// Default autonomy when an assignment is found.
    public var autonomy: Autonomy

    // Rate-limit + scheduling knobs.
    public var searchPollIntervalSeconds: Int
    public var coreRateFloor: Int        // pause core calls when remaining < this
    public var searchRateFloor: Int      // pause search calls when remaining < this
    public var maxConcurrentReviews: Int // parallel reviews across PRs (1-10, distinct repos)
    public var reviewTimeoutSeconds: Int // wall-clock kill for a single `cr` run
    /// Wall-clock kill for tier-routed runs (a `tierLabelProfiles` label matched,
    /// e.g. `cr:large`). Large-model passes legitimately run longer; never below
    /// `reviewTimeoutSeconds`.
    public var reviewTimeoutLargeSeconds: Int
    /// Post a guidance comment on the PR when a review dies at its timeout, so
    /// the author learns what happened and what to do next (label for the large
    /// tier, split the PR, re-request).
    public var timeoutGuidanceComment: Bool
    public var reviewMaxConcurrency: Int // cr --max-concurrency (parallel specialist reviewers)
    public var perPrAttemptCap: Int      // attempts before quarantining a PR as failed
    public var dailyReviewCap: Int       // global runaway guard

    public var notifyOn: NotifyOptions
    public var paused: Bool
    /// If set, only PRs whose author is in this list are acted on (nil = any).
    public var authorAllowlist: [String]?
    /// PR label → cr profile routing, so a tagged PR reviews at a different model
    /// tier. Default maps `cr:large` to the `reviewer-large` (Opus) profile.
    public var tierLabelProfiles: [String: String]

    public init(
        reviewerLogin: String = "piekstra-dev",
        reviewerKeychainAccount: String = "piekstra-dev",
        crProfile: String = "reviewer",
        orgs: [String] = ["piekstra", "strikeforcezero", "open-cli-collective"],
        autonomy: Autonomy = .auto,
        searchPollIntervalSeconds: Int = 90,
        coreRateFloor: Int = 500,
        searchRateFloor: Int = 5,
        maxConcurrentReviews: Int = 3,
        reviewTimeoutSeconds: Int = 900,
        reviewTimeoutLargeSeconds: Int = 2700,
        timeoutGuidanceComment: Bool = true,
        reviewMaxConcurrency: Int = 4,
        perPrAttemptCap: Int = 3,
        dailyReviewCap: Int = 50,
        notifyOn: NotifyOptions = NotifyOptions(),
        paused: Bool = false,
        authorAllowlist: [String]? = nil,
        tierLabelProfiles: [String: String] = ["cr:large": "reviewer-large"]
    ) {
        self.reviewerLogin = reviewerLogin
        self.reviewerKeychainAccount = reviewerKeychainAccount
        self.crProfile = crProfile
        self.orgs = orgs
        self.autonomy = autonomy
        self.searchPollIntervalSeconds = searchPollIntervalSeconds
        self.coreRateFloor = coreRateFloor
        self.searchRateFloor = searchRateFloor
        self.maxConcurrentReviews = maxConcurrentReviews
        self.reviewTimeoutSeconds = reviewTimeoutSeconds
        self.reviewTimeoutLargeSeconds = reviewTimeoutLargeSeconds
        self.timeoutGuidanceComment = timeoutGuidanceComment
        self.reviewMaxConcurrency = reviewMaxConcurrency
        self.perPrAttemptCap = perPrAttemptCap
        self.dailyReviewCap = dailyReviewCap
        self.notifyOn = notifyOn
        self.paused = paused
        self.authorAllowlist = authorAllowlist
        self.tierLabelProfiles = tierLabelProfiles
    }

    /// Lenient decoder: any missing key falls back to its default, so adding a new
    /// config field never breaks (or silently resets) an existing config.json.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Config.default
        reviewerLogin = try c.decodeIfPresent(String.self, forKey: .reviewerLogin) ?? d.reviewerLogin
        reviewerKeychainAccount =
            try c.decodeIfPresent(String.self, forKey: .reviewerKeychainAccount)
            ?? d.reviewerKeychainAccount
        crProfile = try c.decodeIfPresent(String.self, forKey: .crProfile) ?? d.crProfile
        orgs = try c.decodeIfPresent([String].self, forKey: .orgs) ?? d.orgs
        autonomy = try c.decodeIfPresent(Autonomy.self, forKey: .autonomy) ?? d.autonomy
        searchPollIntervalSeconds =
            try c.decodeIfPresent(Int.self, forKey: .searchPollIntervalSeconds)
            ?? d.searchPollIntervalSeconds
        coreRateFloor = try c.decodeIfPresent(Int.self, forKey: .coreRateFloor) ?? d.coreRateFloor
        searchRateFloor =
            try c.decodeIfPresent(Int.self, forKey: .searchRateFloor) ?? d.searchRateFloor
        maxConcurrentReviews =
            try c.decodeIfPresent(Int.self, forKey: .maxConcurrentReviews) ?? d.maxConcurrentReviews
        reviewTimeoutSeconds =
            try c.decodeIfPresent(Int.self, forKey: .reviewTimeoutSeconds) ?? d.reviewTimeoutSeconds
        reviewTimeoutLargeSeconds =
            try c.decodeIfPresent(Int.self, forKey: .reviewTimeoutLargeSeconds)
            ?? d.reviewTimeoutLargeSeconds
        timeoutGuidanceComment =
            try c.decodeIfPresent(Bool.self, forKey: .timeoutGuidanceComment)
            ?? d.timeoutGuidanceComment
        reviewMaxConcurrency =
            try c.decodeIfPresent(Int.self, forKey: .reviewMaxConcurrency) ?? d.reviewMaxConcurrency
        perPrAttemptCap =
            try c.decodeIfPresent(Int.self, forKey: .perPrAttemptCap) ?? d.perPrAttemptCap
        dailyReviewCap =
            try c.decodeIfPresent(Int.self, forKey: .dailyReviewCap) ?? d.dailyReviewCap
        notifyOn = try c.decodeIfPresent(NotifyOptions.self, forKey: .notifyOn) ?? d.notifyOn
        paused = try c.decodeIfPresent(Bool.self, forKey: .paused) ?? d.paused
        authorAllowlist = try c.decodeIfPresent([String].self, forKey: .authorAllowlist)
        tierLabelProfiles =
            try c.decodeIfPresent([String: String].self, forKey: .tierLabelProfiles)
            ?? d.tierLabelProfiles
    }

    /// The tier label a PR matched (e.g. "cr:large"), or nil when none did.
    /// Deterministic when multiple labels match (sorted).
    public static func matchedTierLabel(labels: [String], tierMap: [String: String]) -> String? {
        let present = Set(labels.map { $0.lowercased() })
        return tierMap.keys.sorted().first { present.contains($0.lowercased()) }
    }

    /// Pick the cr profile for a PR given its labels. Falls back to `fallback`
    /// when no label matches.
    public static func selectProfile(
        labels: [String], tierMap: [String: String], fallback: String
    ) -> String {
        guard let label = matchedTierLabel(labels: labels, tierMap: tierMap) else {
            return fallback
        }
        return tierMap[label] ?? fallback
    }

    public static let `default` = Config()

    public func normalizedOrgs() -> Set<String> { Set(orgs.map { $0.lowercased() }) }

    public func isOrgAllowed(_ org: String) -> Bool {
        normalizedOrgs().contains(org.lowercased())
    }

    public func isAuthorAllowed(_ author: String?) -> Bool {
        guard let allow = authorAllowlist else { return true }
        guard let author else { return false }
        let set = Set(allow.map { $0.lowercased() })
        return set.contains(author.lowercased())
    }

    /// Clamp values into safe ranges. Applied on every load.
    public func validated() -> Config {
        var c = self
        c.searchPollIntervalSeconds = max(30, c.searchPollIntervalSeconds)
        // Reviews parallelize across PRs (same-repo runs are excluded by the
        // scheduler). Capped at 10: each review itself fans out up to
        // reviewMaxConcurrency specialist sessions.
        c.maxConcurrentReviews = min(10, max(1, c.maxConcurrentReviews))
        c.reviewTimeoutSeconds = max(120, c.reviewTimeoutSeconds)
        c.reviewTimeoutLargeSeconds = max(c.reviewTimeoutSeconds, c.reviewTimeoutLargeSeconds)
        c.reviewMaxConcurrency = min(8, max(1, c.reviewMaxConcurrency))
        c.perPrAttemptCap = max(1, c.perPrAttemptCap)
        c.dailyReviewCap = max(1, c.dailyReviewCap)
        c.coreRateFloor = max(0, c.coreRateFloor)
        c.searchRateFloor = max(0, c.searchRateFloor)
        c.orgs = c.orgs.map { $0.lowercased() }
        return c
    }

    private static func makeEncoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.keyEncodingStrategy = .convertToSnakeCase
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }

    private static func makeDecoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }

    /// Load config, returning `.default` (without overwriting) on any error so a
    /// malformed file never silently erases the user's edits.
    public static func load(from url: URL = Paths.configFile) -> Config {
        guard let data = try? Data(contentsOf: url),
            let cfg = try? makeDecoder().decode(Config.self, from: data)
        else { return .default }
        return cfg.validated()
    }

    /// Load, or write a default file if none exists yet.
    public static func loadOrCreateDefault(at url: URL = Paths.configFile) -> Config {
        if FileManager.default.fileExists(atPath: url.path) { return load(from: url) }
        let cfg = Config.default
        try? cfg.save(to: url)
        return cfg
    }

    public func save(to url: URL = Paths.configFile) throws {
        let data = try Self.makeEncoder().encode(self)
        try data.write(to: url, options: .atomic)
    }
}
