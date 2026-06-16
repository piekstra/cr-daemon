import Foundation

/// On-disk shape of state.json.
private struct StateFile: Codable {
    var version: Int
    var assignments: [Assignment]
    var recentReviewStarts: [Date]
}

/// Durable, single-writer assignment queue.
///
/// Persistence is an atomically-rewritten JSON file (`state.json`) plus an
/// append-only `events.jsonl` forensic log. SQLite would be overkill for one
/// writer and a handful of PRs, and adds a C dependency to the SwiftPM build.
/// All access is serialized through a private queue so the MainActor menu can
/// read synchronously while the watcher mutates.
public final class QueueStore: @unchecked Sendable {
    private let stateURL: URL
    private let eventsURL: URL
    private let now: () -> Date
    private let log: Logger
    private let queue = DispatchQueue(label: "com.piekstra.cr-daemon.store")

    private var byKey: [String: Assignment] = [:]
    private var recentReviewStarts: [Date] = []
    /// A PR can linger in the review-requested set for a poll cycle after we
    /// review it (GitHub clears the request asynchronously). Don't re-queue a PR
    /// we finished reviewing within this window, so the lag doesn't cause a
    /// redundant re-review. A genuine re-request typically comes minutes later.
    private let settleWindow: TimeInterval = 120

    public init(
        stateURL: URL = Paths.stateFile,
        eventsURL: URL = Paths.eventsLog,
        now: @escaping () -> Date = { Date() },
        log: Logger = .shared
    ) {
        self.stateURL = stateURL
        self.eventsURL = eventsURL
        self.now = now
        self.log = log
        loadFromDisk()
    }

    // MARK: - Encoding

    private static func makeEncoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.keyEncodingStrategy = .convertToSnakeCase
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }

    private static func makeDecoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        d.dateDecodingStrategy = .iso8601
        return d
    }

    private func loadFromDisk() {
        guard let data = try? Data(contentsOf: stateURL) else { return }
        guard let file = try? Self.makeDecoder().decode(StateFile.self, from: data) else {
            // Corrupt: preserve it for forensics rather than silently losing data.
            let backup = stateURL.appendingPathExtension("corrupt")
            try? FileManager.default.removeItem(at: backup)
            try? FileManager.default.moveItem(at: stateURL, to: backup)
            log.error("store.corrupt_state", ["backup": backup.lastPathComponent])
            return
        }
        byKey = Dictionary(uniqueKeysWithValues: file.assignments.map { ($0.key.description, $0) })
        recentReviewStarts = file.recentReviewStarts
    }

    /// Atomic persist: encode → temp file → rename (via Data's .atomic).
    private func persistLocked() {
        let file = StateFile(
            version: 1,
            assignments: Array(byKey.values).sorted { $0.key.description < $1.key.description },
            recentReviewStarts: recentReviewStarts)
        guard let data = try? Self.makeEncoder().encode(file) else {
            log.error("store.encode_failed", [:])
            return
        }
        do {
            try data.write(to: stateURL, options: .atomic)
        } catch {
            log.error("store.write_failed", ["error": String(describing: error)])
        }
    }

    // MARK: - Queries

    public func all() -> [Assignment] {
        queue.sync { Array(byKey.values) }
    }

    public func get(_ key: PRKey) -> Assignment? {
        queue.sync { byKey[key.description] }
    }

    public func pending() -> [Assignment] {
        queue.sync { byKey.values.filter { $0.state == .pending } }
            .sorted { $0.discoveredAt < $1.discoveredAt }
    }

    /// pending + reviewing, oldest first — the live work queue for the menu.
    public func active() -> [Assignment] {
        queue.sync { byKey.values.filter { $0.state == .pending || $0.state == .reviewing } }
            .sorted { $0.discoveredAt < $1.discoveredAt }
    }

    public func recent(limit: Int = 10) -> [Assignment] {
        queue.sync { byKey.values.filter { $0.state == .done || $0.state == .failed } }
            .sorted { ($0.finishedAt ?? .distantPast) > ($1.finishedAt ?? .distantPast) }
            .prefix(limit)
            .map { $0 }
    }

    // MARK: - Mutations (each persists + logs)

    /// Insert a freshly-discovered PR, or refresh an existing one. A previously
    /// done/skipped PR reappearing in the search set means it was re-requested →
    /// re-queue it. failed PRs stay quarantined (manual retry only).
    @discardableResult
    public func upsertDiscovered(_ pr: SearchPR, org: String) -> Assignment {
        queue.sync {
            let id = pr.key.description
            if var existing = byKey[id] {
                existing.url = pr.url
                existing.title = pr.title
                existing.author = pr.author
                existing.org = org
                existing.labels = pr.labels
                existing.updatedAt = now()
                let recentlyReviewed =
                    existing.state == .done
                    && (existing.finishedAt.map { now().timeIntervalSince($0) < settleWindow }
                        ?? false)
                if (existing.state == .done || existing.state == .skipped) && !recentlyReviewed {
                    existing.state = .pending
                    existing.lastError = nil
                    existing.attempts = 0  // a re-request is fresh work
                    existing.startedAt = nil  // clear the retry cooldown
                    appendEventLocked("assignment.requeued", ["pr": id])
                }
                byKey[id] = existing
                persistLocked()
                return existing
            }
            let a = Assignment(
                key: pr.key, url: pr.url, org: org, title: pr.title, author: pr.author,
                state: .pending, labels: pr.labels, discoveredAt: now(), updatedAt: now())
            byKey[id] = a
            appendEventLocked("assignment.discovered", ["pr": id, "author": pr.author ?? ""])
            persistLocked()
            return a
        }
    }

    /// Apply a mutation to an assignment and persist.
    public func update(_ key: PRKey, _ mutate: (inout Assignment) -> Void) {
        queue.sync {
            guard var a = byKey[key.description] else { return }
            mutate(&a)
            a.updatedAt = now()
            byKey[key.description] = a
            persistLocked()
        }
    }

    public func remove(_ key: PRKey) {
        queue.sync {
            byKey[key.description] = nil
            persistLocked()
        }
    }

    /// Reconcile against the Search source of truth: any *pending* assignment no
    /// longer in the current requested set is withdrawn/closed → skip it.
    /// reviewing rows are left alone (a review in flight may have just cleared
    /// the request by approving).
    public func markWithdrawnPending(currentKeys: Set<String>) {
        queue.sync {
            for (id, a) in byKey where a.state == .pending && !currentKeys.contains(id) {
                var x = a
                x.state = .skipped
                x.lastError = "no longer a requested reviewer"
                x.updatedAt = now()
                byKey[id] = x
                appendEventLocked("assignment.withdrawn", ["pr": id])
            }
            persistLocked()
        }
    }

    // MARK: - Reconciliation helpers (crash recovery)

    /// reviewing rows whose `cr` process is gone — candidates for recovery.
    public func orphanedReviewing(isPidAlive: (Int32) -> Bool) -> [Assignment] {
        queue.sync {
            byKey.values.filter { a in
                guard a.state == .reviewing else { return false }
                guard let pid = a.crPid else { return true }
                return !isPidAlive(pid)
            }
        }
    }

    // MARK: - Daily cap accounting

    public func recordReviewStart() {
        queue.sync {
            recentReviewStarts.append(now())
            pruneStartsLocked()
            persistLocked()
        }
    }

    public func reviewStartsInLast24h() -> Int {
        queue.sync {
            let cutoff = now().addingTimeInterval(-24 * 3600)
            return recentReviewStarts.filter { $0 >= cutoff }.count
        }
    }

    private func pruneStartsLocked() {
        let cutoff = now().addingTimeInterval(-24 * 3600)
        recentReviewStarts = recentReviewStarts.filter { $0 >= cutoff }
    }

    // MARK: - Events

    public func appendEvent(_ event: String, _ fields: [String: Any] = [:]) {
        queue.sync { appendEventLocked(event, fields) }
    }

    private func appendEventLocked(_ event: String, _ fields: [String: Any]) {
        var obj: [String: Any] = [
            "ts": ISO8601DateFormatter().string(from: now()), "event": event,
        ]
        for (k, v) in fields { obj[k] = v }
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]),
            let raw = String(data: data, encoding: .utf8)
        else { return }
        let line = Redact.scrub(raw) + "\n"
        let bytes = Data(line.utf8)
        let fm = FileManager.default
        if !fm.fileExists(atPath: eventsURL.path) {
            try? bytes.write(to: eventsURL)
            return
        }
        guard let fh = try? FileHandle(forWritingTo: eventsURL) else { return }
        defer { try? fh.close() }
        _ = try? fh.seekToEnd()
        try? fh.write(contentsOf: bytes)
    }
}
