import Foundation

/// A PR returned by the Search API (`review-requested:<login>`).
public struct SearchPR: Sendable, Equatable {
    public let key: PRKey
    public let url: String
    public let title: String
    public let author: String?
    public let updatedAt: Date?
    public let labels: [String]

    public init(
        key: PRKey, url: String, title: String, author: String?, updatedAt: Date?,
        labels: [String] = []
    ) {
        self.key = key
        self.url = url
        self.title = title
        self.author = author
        self.updatedAt = updatedAt
        self.labels = labels
    }
}

/// A review-comment thread the reviewer started where a human has replied and
/// the reviewer hasn't responded yet — the trigger for conversational replies.
public struct ReplyThread: Sendable, Equatable {
    public let rootCommentID: Int
    public let path: String?
    public let lastReplyAuthor: String
    public let lastReplyBody: String

    public init(rootCommentID: Int, path: String?, lastReplyAuthor: String, lastReplyBody: String) {
        self.rootCommentID = rootCommentID
        self.path = path
        self.lastReplyAuthor = lastReplyAuthor
        self.lastReplyBody = lastReplyBody
    }
}

/// Detail fetched from the PR endpoint (core bucket).
public struct PullRequestDetail: Sendable, Equatable {
    public let key: PRKey
    public let state: String   // "open" | "closed"
    public let merged: Bool
    public let headSHA: String?
    public let author: String?
}

/// Errors the client surfaces. The watcher decides retry vs. back-off from these.
public enum GitHubError: Error, Sendable {
    case noToken
    case throttled(resource: RateResource, until: Date)
    case secondaryLimit(until: Date)
    case circuitOpen(until: Date)
    case http(status: Int, bodySnippet: String)
    case transport(String)
    case decode(String)
}

/// Rate-limit-disciplined GitHub REST client. An actor so its bucket/ETag/
/// circuit-breaker state is serialized without locks.
///
/// Layered protections (all here so callers can't bypass them):
///  - two independent buckets (core + search) tracked from response headers;
///  - refuse to spend a bucket below its configured floor (proactive);
///  - conditional requests (If-None-Match) so unchanged responses are free 304s;
///  - honor Retry-After on 403/429 secondary limits;
///  - circuit breaker after consecutive failures, with full-jitter backoff;
///  - single in-flight request per endpoint key (coalesced).
public actor GitHubClient {
    public struct Response: Sendable {
        public let status: Int
        public let data: Data
        public let notModified: Bool
    }

    private let session: URLSession
    private let tokenProvider: @Sendable () -> String?
    private let now: @Sendable () -> Date
    private let log: Logger

    private var coreFloor: Int
    private var searchFloor: Int
    private let maxConsecutiveFailures: Int

    private var core: RateBudget?
    private var search: RateBudget?
    private var etags: [String: String] = [:]
    private var inFlight: [String: Task<Response, Error>] = [:]
    private var lastSearchResults: [SearchPR] = []
    private var consecutiveFailures = 0
    private var circuitOpenUntil: Date?

    public init(
        session: URLSession? = nil,
        tokenProvider: @escaping @Sendable () -> String?,
        coreFloor: Int = 500,
        searchFloor: Int = 5,
        maxConsecutiveFailures: Int = 5,
        now: @escaping @Sendable () -> Date = { Date() },
        log: Logger = .shared
    ) {
        self.session = session ?? GitHubClient.makeSession()
        self.tokenProvider = tokenProvider
        self.coreFloor = coreFloor
        self.searchFloor = searchFloor
        self.maxConsecutiveFailures = maxConsecutiveFailures
        self.now = now
        self.log = log
    }

    /// A URLSession with bounded timeouts so no request can hang the control
    /// loop. `.shared` carries a 7-day `timeoutIntervalForResource`, which let a
    /// stalled GitHub connection (e.g. a reply-thread GraphQL fetch) wedge the
    /// daemon's poll loop indefinitely.
    private static func makeSession() -> URLSession {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 30
        cfg.timeoutIntervalForResource = 90
        cfg.waitsForConnectivity = false
        return URLSession(configuration: cfg)
    }

    public func updateFloors(core: Int, search: Int) {
        coreFloor = core
        searchFloor = search
    }

    /// (core, search, circuitOpenUntil) for the menu bar.
    public func snapshot() -> (core: RateBudget?, search: RateBudget?, circuitOpenUntil: Date?) {
        (core, search, circuitOpenUntil)
    }

    // MARK: - High-level operations

    /// All open PRs where `login` is currently a requested reviewer. This is the
    /// source of truth for assignments (self-healing — reflects current state).
    public func searchOpenReviewRequested(login: String) async throws -> [SearchPR] {
        let q = "is:open is:pr review-requested:\(login)"
        let resp = try await request(
            path: "/search/issues",
            query: [
                URLQueryItem(name: "q", value: q),
                URLQueryItem(name: "per_page", value: "100"),
            ],
            resource: .search,
            useConditional: true)
        if resp.notModified { return lastSearchResults }
        guard let parsed = Self.parseSearchItems(resp.data) else {
            throw GitHubError.decode("search body missing items")
        }
        lastSearchResults = parsed
        return parsed
    }

    /// Current detail for a PR (state/merged/head SHA/author). Core bucket.
    public func pullRequest(_ key: PRKey) async throws -> PullRequestDetail? {
        let resp = try await request(
            path: "/repos/\(key.owner)/\(key.repo)/pulls/\(key.number)",
            query: [], resource: .core, useConditional: false)
        guard let obj = try? JSONSerialization.jsonObject(with: resp.data) as? [String: Any]
        else { throw GitHubError.decode("pull request body not an object") }
        let state = obj["state"] as? String ?? "unknown"
        let merged = obj["merged"] as? Bool ?? false
        let head = obj["head"] as? [String: Any]
        let sha = head?["sha"] as? String
        let author = (obj["user"] as? [String: Any])?["login"] as? String
        return PullRequestDetail(
            key: key, state: state, merged: merged, headSHA: sha, author: author)
    }

    /// The most recent review state submitted by `login` on a PR
    /// (APPROVED / CHANGES_REQUESTED / COMMENTED / DISMISSED), or nil if none.
    /// Authoritative way to learn what `cr` actually did, independent of its
    /// JSON output schema. Core bucket.
    public func latestReviewState(_ key: PRKey, by login: String) async throws -> String? {
        let resp = try await request(
            path: "/repos/\(key.owner)/\(key.repo)/pulls/\(key.number)/reviews",
            query: [URLQueryItem(name: "per_page", value: "100")],
            resource: .core, useConditional: false)
        guard let arr = try? JSONSerialization.jsonObject(with: resp.data) as? [[String: Any]]
        else { throw GitHubError.decode("reviews body not an array") }
        let mine = arr.filter {
            (($0["user"] as? [String: Any])?["login"] as? String)?.caseInsensitiveCompare(login)
                == .orderedSame
        }
        return mine.last?["state"] as? String
    }

    /// Latest review by `login` with the commit it was submitted against.
    /// The commit matters: a review at an old head must never satisfy a check
    /// for the current head (force-pushes replace the reviewed commits while a
    /// locally-stamped "reviewed SHA" can be poisoned by failed attempts that
    /// stamp before reviewing). Core bucket.
    public func latestReview(_ key: PRKey, by login: String) async throws
        -> (state: String, commitSHA: String?)?
    {
        let resp = try await request(
            path: "/repos/\(key.owner)/\(key.repo)/pulls/\(key.number)/reviews",
            query: [URLQueryItem(name: "per_page", value: "100")],
            resource: .core, useConditional: false)
        guard let arr = try? JSONSerialization.jsonObject(with: resp.data) as? [[String: Any]]
        else { throw GitHubError.decode("reviews body not an array") }
        let mine = arr.filter {
            (($0["user"] as? [String: Any])?["login"] as? String)?.caseInsensitiveCompare(login)
                == .orderedSame
        }
        guard let last = mine.last, let state = last["state"] as? String else { return nil }
        return (state: state, commitSHA: last["commit_id"] as? String)
    }

    /// Cheap identity probe used to re-validate the token after wake.
    @discardableResult
    public func currentUserLogin() async throws -> String? {
        let resp = try await request(path: "/user", query: [], resource: .core, useConditional: false)
        let obj = try? JSONSerialization.jsonObject(with: resp.data) as? [String: Any]
        return obj?["login"] as? String
    }

    /// Post an issue comment on a PR. Core bucket. Deliberately bypasses the
    /// GET request path: mutations must never be coalesced with an identical
    /// in-flight call or served from a conditional cache.
    public func postIssueComment(_ key: PRKey, body: String) async throws {
        let current = now()
        if let until = circuitOpenUntil, current < until {
            throw GitHubError.circuitOpen(until: until)
        }
        if let core, core.shouldThrottle(floor: coreFloor, now: current) {
            throw GitHubError.throttled(resource: .core, until: core.reset)
        }
        guard let token = tokenProvider() else { throw GitHubError.noToken }
        guard
            let url = URL(
                string:
                    "https://api.github.com/repos/\(key.owner)/\(key.repo)/issues/\(key.number)/comments"
            )
        else { throw GitHubError.transport("bad url for comment on \(key)") }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        req.setValue("cr-daemon/\(crDaemonVersion)", forHTTPHeaderField: "User-Agent")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["body": body])

        let data: Data
        let http: HTTPURLResponse
        do {
            let (d, resp) = try await session.data(for: req)
            data = d
            guard let h = resp as? HTTPURLResponse else {
                throw GitHubError.transport("non-HTTP response")
            }
            http = h
        } catch let e as GitHubError {
            throw e
        } catch {
            registerFailure()
            throw GitHubError.transport(String(describing: error))
        }
        if let (res, parsed) = RateLimitHeaders.parse(http.allHeaderFields, now: current) {
            if res == .core { core = parsed } else { search = parsed }
        }
        switch http.statusCode {
        case 200..<300:
            registerSuccess()
        case 403, 429:
            let wait = RateLimitHeaders.retryAfterSeconds(http.allHeaderFields)
                ?? Backoff.delay(attempt: consecutiveFailures, base: 60, cap: 600)
            circuitOpenUntil = current.addingTimeInterval(wait)
            registerFailure()
            throw GitHubError.secondaryLimit(until: current.addingTimeInterval(wait))
        default:
            registerFailure()
            let snippet = Redact.scrub(String(data: data.prefix(300), encoding: .utf8) ?? "")
            throw GitHubError.http(status: http.statusCode, bodySnippet: snippet)
        }
    }

    // MARK: - Core request path

    private func request(
        path: String, query: [URLQueryItem], resource: RateResource, useConditional: Bool
    ) async throws -> Response {
        let key = resource.rawValue + " " + path + "?" + query.map { "\($0.name)=\($0.value ?? "")" }
            .joined(separator: "&")

        // Coalesce identical concurrent requests.
        if let existing = inFlight[key] {
            return try await existing.value
        }
        let task = Task { () throws -> Response in
            try await self.perform(path: path, query: query, resource: resource,
                useConditional: useConditional, key: key)
        }
        inFlight[key] = task
        defer { inFlight[key] = nil }
        return try await task.value
    }

    private func perform(
        path: String, query: [URLQueryItem], resource: RateResource,
        useConditional: Bool, key: String
    ) async throws -> Response {
        let current = now()

        // Circuit breaker.
        if let until = circuitOpenUntil, current < until {
            throw GitHubError.circuitOpen(until: until)
        }

        // Proactive floor check on the relevant bucket.
        let budget = (resource == .core) ? core : search
        let floor = (resource == .core) ? coreFloor : searchFloor
        if let budget, budget.shouldThrottle(floor: floor, now: current) {
            throw GitHubError.throttled(resource: resource, until: budget.reset)
        }

        guard let token = tokenProvider() else { throw GitHubError.noToken }

        var comps = URLComponents()
        comps.scheme = "https"
        comps.host = "api.github.com"
        comps.path = path
        if !query.isEmpty { comps.queryItems = query }
        guard let url = comps.url else { throw GitHubError.transport("bad url for \(path)") }

        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        req.setValue("cr-daemon/\(crDaemonVersion)", forHTTPHeaderField: "User-Agent")
        if useConditional, let etag = etags[key] {
            req.setValue(etag, forHTTPHeaderField: "If-None-Match")
        }

        let data: Data
        let http: HTTPURLResponse
        do {
            let (d, resp) = try await session.data(for: req)
            data = d
            guard let h = resp as? HTTPURLResponse else {
                throw GitHubError.transport("non-HTTP response")
            }
            http = h
        } catch let e as GitHubError {
            throw e
        } catch {
            registerFailure()
            throw GitHubError.transport(String(describing: error))
        }

        // Update the bucket from headers regardless of status.
        if let (res, parsed) = RateLimitHeaders.parse(http.allHeaderFields, now: current) {
            if res == .core { core = parsed } else { search = parsed }
        }

        switch http.statusCode {
        case 304:
            registerSuccess()
            return Response(status: 304, data: Data(), notModified: true)
        case 200..<300:
            if useConditional, let etag = http.value(forHTTPHeaderField: "ETag") {
                etags[key] = etag
            }
            registerSuccess()
            return Response(status: http.statusCode, data: data, notModified: false)
        case 403, 429:
            // Secondary / abuse rate limit. Honor Retry-After, else jittered backoff.
            let wait = RateLimitHeaders.retryAfterSeconds(http.allHeaderFields)
                ?? Backoff.delay(attempt: consecutiveFailures, base: 60, cap: 600)
            let until = current.addingTimeInterval(wait)
            circuitOpenUntil = until
            registerFailure()
            log.warn("github.secondary_limit", ["resource": resource.rawValue, "wait_s": Int(wait)])
            throw GitHubError.secondaryLimit(until: until)
        default:
            registerFailure()
            let snippet = Redact.scrub(String(data: data.prefix(300), encoding: .utf8) ?? "")
            throw GitHubError.http(status: http.statusCode, bodySnippet: snippet)
        }
    }

    private func registerSuccess() {
        consecutiveFailures = 0
        circuitOpenUntil = nil
    }

    private func registerFailure() {
        consecutiveFailures += 1
        if consecutiveFailures >= maxConsecutiveFailures {
            let wait = Backoff.delay(attempt: consecutiveFailures, base: 30, cap: 600)
            circuitOpenUntil = now().addingTimeInterval(wait)
            log.warn("github.circuit_open", ["failures": consecutiveFailures, "wait_s": Int(wait)])
        }
    }

    // MARK: - Parsing

    /// Parse a GitHub `/search/issues` response into PRs. Pure + static so it can
    /// be unit-tested against fixtures. Returns nil if the body has no `items`
    /// array; skips non-PR issues and unparseable URLs.
    public static func parseSearchItems(_ data: Data) -> [SearchPR]? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let items = obj["items"] as? [[String: Any]]
        else { return nil }

        let iso = ISO8601DateFormatter()
        var out: [SearchPR] = []
        for item in items {
            guard item["pull_request"] != nil else { continue }
            guard let html = item["html_url"] as? String, let key = PRKey.parse(url: html)
            else { continue }
            let title = item["title"] as? String ?? ""
            let author = (item["user"] as? [String: Any])?["login"] as? String
            let updated = (item["updated_at"] as? String).flatMap { iso.date(from: $0) }
            let labels = (item["labels"] as? [[String: Any]])?
                .compactMap { $0["name"] as? String } ?? []
            out.append(
                SearchPR(
                    key: key, url: html, title: title, author: author, updatedAt: updated,
                    labels: labels))
        }
        return out
    }

    /// Open review-comment threads on a PR that `reviewerLogin` started and a
    /// human last replied to (the reviewer hasn't answered). Core bucket.
    public func unansweredReplyThreads(_ key: PRKey, reviewerLogin: String) async throws
        -> [ReplyThread]
    {
        let resp = try await request(
            path: "/repos/\(key.owner)/\(key.repo)/pulls/\(key.number)/comments",
            query: [URLQueryItem(name: "per_page", value: "100")],
            resource: .core, useConditional: false)
        return Self.parseUnansweredReplyThreads(resp.data, reviewerLogin: reviewerLogin)
    }

    /// Parse PR review comments into threads where `reviewerLogin` started the
    /// thread and the most recent comment is from someone else. Pure + static.
    public static func parseUnansweredReplyThreads(_ data: Data, reviewerLogin: String)
        -> [ReplyThread]
    {
        guard let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }
        // Group comments by thread root (in_reply_to_id, or the comment's own id).
        var threads: [Int: [[String: Any]]] = [:]
        for c in arr {
            guard let id = c["id"] as? Int else { continue }
            let root = (c["in_reply_to_id"] as? Int) ?? id
            threads[root, default: []].append(c)
        }
        let iso = ISO8601DateFormatter()
        func date(_ c: [String: Any]) -> Date {
            (c["created_at"] as? String).flatMap { iso.date(from: $0) } ?? .distantPast
        }
        func login(_ c: [String: Any]) -> String {
            (c["user"] as? [String: Any])?["login"] as? String ?? ""
        }
        var out: [ReplyThread] = []
        for (rootID, comments) in threads {
            let sorted = comments.sorted { date($0) < date($1) }
            guard let root = sorted.first(where: { ($0["id"] as? Int) == rootID }) ?? sorted.first
            else { continue }
            guard login(root).caseInsensitiveCompare(reviewerLogin) == .orderedSame else { continue }
            guard let last = sorted.last else { continue }
            if login(last).caseInsensitiveCompare(reviewerLogin) != .orderedSame {
                out.append(
                    ReplyThread(
                        rootCommentID: rootID, path: root["path"] as? String,
                        lastReplyAuthor: login(last),
                        lastReplyBody: (last["body"] as? String) ?? ""))
            }
        }
        return out.sorted { $0.rootCommentID < $1.rootCommentID }
    }
}
