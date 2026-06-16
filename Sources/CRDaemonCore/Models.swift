import Foundation

/// Identifies a pull request as `owner/repo#number`.
public struct PRKey: Hashable, Codable, CustomStringConvertible, Sendable {
    public let owner: String
    public let repo: String
    public let number: Int

    public init(owner: String, repo: String, number: Int) {
        self.owner = owner
        self.repo = repo
        self.number = number
    }

    /// `owner/repo`
    public var slug: String { "\(owner)/\(repo)" }
    public var description: String { "\(owner)/\(repo)#\(number)" }

    /// Web URL for the PR.
    public var webURL: String { "https://github.com/\(owner)/\(repo)/pull/\(number)" }

    /// Parse `https://github.com/OWNER/REPO/pull/NUMBER` (host must be github.com).
    public static func parse(url: String) -> PRKey? {
        guard let comps = URLComponents(string: url),
            let host = comps.host, host == "github.com" || host.hasSuffix(".github.com")
        else { return nil }
        let parts = comps.path.split(separator: "/").map(String.init)
        guard parts.count >= 4, parts[2] == "pull", let number = Int(parts[3]) else { return nil }
        return PRKey(owner: parts[0], repo: parts[1], number: number)
    }
}

/// Lifecycle of a single assignment in the queue.
public enum AssignmentState: String, Codable, Sendable {
    case pending      // discovered, awaiting review
    case reviewing    // a `cr` process is (or was) running
    case done         // reviewed; see lastOutcome
    case failed       // terminal failure after attempt cap
    case skipped      // no longer applicable (closed/merged/unassigned/not-allowlisted)
}

/// What a completed `cr review` did to the PR.
public enum ReviewOutcome: String, Codable, Sendable {
    case approved
    case commented
    case changesRequested
    case skippedAlreadyApproved
    case failed
    case unknown
}

/// One tracked PR. Persisted in state.json (single-writer).
public struct Assignment: Codable, Equatable, Sendable {
    public var key: PRKey
    public var url: String
    public var org: String
    public var title: String?
    public var author: String?
    public var state: AssignmentState

    public var headShaSeen: String?       // head SHA when discovered/queued
    public var headShaReviewed: String?   // head SHA `cr` was launched against
    public var crPid: Int32?              // pid of the in-flight `cr` process
    public var runToken: String?          // unique per launch; detect orphans across restarts

    public var attempts: Int
    public var lastError: String?
    public var lastExitCode: Int32?
    public var lastOutcome: ReviewOutcome?
    /// Confirm-mode: a dry-run plan is ready and awaiting the user's "Post".
    public var awaitingConfirm: Bool?
    /// Short human-facing summary of the last run (dry-run plan or result tail).
    public var lastSummary: String?

    public var discoveredAt: Date
    public var startedAt: Date?
    public var finishedAt: Date?
    public var updatedAt: Date

    public init(
        key: PRKey, url: String, org: String, title: String? = nil, author: String? = nil,
        state: AssignmentState = .pending, headShaSeen: String? = nil,
        headShaReviewed: String? = nil, crPid: Int32? = nil, runToken: String? = nil,
        attempts: Int = 0, lastError: String? = nil, lastExitCode: Int32? = nil,
        lastOutcome: ReviewOutcome? = nil, awaitingConfirm: Bool? = nil, lastSummary: String? = nil,
        discoveredAt: Date, startedAt: Date? = nil,
        finishedAt: Date? = nil, updatedAt: Date
    ) {
        self.key = key
        self.url = url
        self.org = org
        self.title = title
        self.author = author
        self.state = state
        self.headShaSeen = headShaSeen
        self.headShaReviewed = headShaReviewed
        self.crPid = crPid
        self.runToken = runToken
        self.attempts = attempts
        self.lastError = lastError
        self.lastExitCode = lastExitCode
        self.lastOutcome = lastOutcome
        self.awaitingConfirm = awaitingConfirm
        self.lastSummary = lastSummary
        self.discoveredAt = discoveredAt
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.updatedAt = updatedAt
    }
}

/// High-level runtime status surfaced to the menu bar. Only `paused` persists
/// (in Config); the rest are transient.
public enum RuntimeState: Equatable, Sendable {
    case starting
    case active                      // watching normally
    case reviewing(PRKey)            // a review is in flight
    case paused                      // user paused
    case offline                     // no network
    case rateLimited(until: Date)    // backing off a GitHub bucket
    case backingOff(until: Date)     // circuit breaker open
    case safeMode(reason: String)    // crash-loop guard tripped
    case error(String)               // terminal config/auth problem
}
