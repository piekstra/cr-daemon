import CRDaemonCore
import Foundation

private func tempURLs() -> (URL, URL) {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("crq-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return (dir.appendingPathComponent("state.json"), dir.appendingPathComponent("events.jsonl"))
}

private func pr(_ owner: String, _ repo: String, _ n: Int, author: String = "piekstra") -> SearchPR {
    SearchPR(
        key: PRKey(owner: owner, repo: repo, number: n),
        url: "https://github.com/\(owner)/\(repo)/pull/\(n)",
        title: "t", author: author, updatedAt: nil)
}

func runQueueStoreTests() {
    suite.test("upsertNewAndRequeueAfterDone") {
        let (s, e) = tempURLs()
        let store = QueueStore(stateURL: s, eventsURL: e)
        let a = store.upsertDiscovered(pr("piekstra", "govee-cli", 7), org: "piekstra")
        suite.expect(a.state == .pending)
        suite.expect(store.pending().count == 1)

        store.update(a.key) { $0.state = .done }
        suite.expect(store.pending().count == 0)

        let b = store.upsertDiscovered(pr("piekstra", "govee-cli", 7), org: "piekstra")
        suite.expect(b.state == .pending, "re-requested PR re-queued")
        suite.expect(store.pending().count == 1)
    }

    suite.test("markWithdrawnPending") {
        let (s, e) = tempURLs()
        let store = QueueStore(stateURL: s, eventsURL: e)
        _ = store.upsertDiscovered(pr("piekstra", "a", 1), org: "piekstra")
        _ = store.upsertDiscovered(pr("piekstra", "b", 2), org: "piekstra")

        store.markWithdrawnPending(currentKeys: ["piekstra/a#1"])
        let states = Dictionary(
            uniqueKeysWithValues: store.all().map { ($0.key.description, $0.state) })
        suite.expect(states["piekstra/a#1"] == .pending)
        suite.expect(states["piekstra/b#2"] == .skipped)
    }

    suite.test("orphanedReviewing") {
        let (s, e) = tempURLs()
        let store = QueueStore(stateURL: s, eventsURL: e)
        let a = store.upsertDiscovered(pr("piekstra", "a", 1), org: "piekstra")
        store.update(a.key) {
            $0.state = .reviewing
            $0.crPid = 999_999
        }
        suite.expect(store.orphanedReviewing(isPidAlive: { _ in false }).count == 1)
        suite.expect(store.orphanedReviewing(isPidAlive: { _ in true }).count == 0)
    }

    suite.test("dailyCapAccountingExpires") {
        let (s, e) = tempURLs()
        var clock = Date(timeIntervalSince1970: 100_000)
        let store = QueueStore(stateURL: s, eventsURL: e, now: { clock })
        store.recordReviewStart()
        store.recordReviewStart()
        suite.expect(store.reviewStartsInLast24h() == 2)
        clock = clock.addingTimeInterval(25 * 3600)
        suite.expect(store.reviewStartsInLast24h() == 0)
    }

    suite.test("settleWindowSuppressesImmediateRequeue") {
        let (s, e) = tempURLs()
        var clock = Date(timeIntervalSince1970: 1000)
        let store = QueueStore(stateURL: s, eventsURL: e, now: { clock })
        let a = store.upsertDiscovered(pr("piekstra", "a", 1), org: "piekstra")
        store.update(a.key) {
            $0.state = .done
            $0.finishedAt = clock
        }
        clock = clock.addingTimeInterval(30)  // within the 120s settle window
        _ = store.upsertDiscovered(pr("piekstra", "a", 1), org: "piekstra")
        suite.expect(store.get(a.key)?.state == .done, "re-review suppressed during request-clear lag")

        clock = clock.addingTimeInterval(200)  // past the window → genuine re-request
        _ = store.upsertDiscovered(pr("piekstra", "a", 1), org: "piekstra")
        suite.expect(store.get(a.key)?.state == .pending, "re-queued after settle window")
    }

    suite.test("retryEligibleFailuresRespectsBackoff") {
        let (s, e) = tempURLs()
        var clock = Date(timeIntervalSince1970: 1_000_000)
        let store = QueueStore(stateURL: s, eventsURL: e, now: { clock })
        let old = store.upsertDiscovered(pr("piekstra", "old", 1), org: "piekstra")
        let fresh = store.upsertDiscovered(pr("piekstra", "fresh", 2), org: "piekstra")
        // old failed 2h ago; fresh failed just now.
        store.update(old.key) {
            $0.state = .failed
            $0.attempts = 3
            $0.finishedAt = clock.addingTimeInterval(-7200)
            $0.lastError = "boom"
        }
        store.update(fresh.key) {
            $0.state = .failed
            $0.attempts = 3
            $0.finishedAt = clock
            $0.lastError = "boom"
        }

        let n = store.retryEligibleFailures(now: clock, backoff: 3600)
        suite.expect(n == 1, "only the >1h-old failure resets")
        suite.expect(store.get(old.key)?.state == .pending, "old failure re-queued")
        suite.expect(store.get(old.key)?.attempts == 0, "attempts reset")
        suite.expect(store.get(old.key)?.finishedAt == nil, "finishedAt cleared")
        suite.expect(store.get(old.key)?.lastError == "boom", "lastError preserved")
        suite.expect(store.get(fresh.key)?.state == .failed, "recent failure left in backoff")
    }

    suite.test("resetFailedForRetryResetsAll") {
        let (s, e) = tempURLs()
        let store = QueueStore(stateURL: s, eventsURL: e)
        let a = store.upsertDiscovered(pr("piekstra", "a", 1), org: "piekstra")
        let b = store.upsertDiscovered(pr("piekstra", "b", 2), org: "piekstra")
        let c = store.upsertDiscovered(pr("piekstra", "c", 3), org: "piekstra")
        for k in [a.key, b.key] {
            store.update(k) {
                $0.state = .failed
                $0.attempts = 3
                $0.finishedAt = Date()
                $0.lastError = "boom"
            }
        }
        store.update(c.key) { $0.state = .done }

        let n = store.resetFailedForRetry()
        suite.expect(n == 2, "every failed PR reset regardless of age")
        suite.expect(store.get(a.key)?.state == .pending)
        suite.expect(store.get(a.key)?.attempts == 0)
        suite.expect(store.get(b.key)?.state == .pending)
        suite.expect(store.get(c.key)?.state == .done, "non-failed PRs untouched")
    }

    suite.test("persistenceRoundTrip") {
        let (s, e) = tempURLs()
        do {
            let store = QueueStore(stateURL: s, eventsURL: e)
            _ = store.upsertDiscovered(pr("piekstra", "a", 1), org: "piekstra")
        }
        let reopened = QueueStore(stateURL: s, eventsURL: e)
        suite.expect(reopened.all().count == 1)
        suite.expect(reopened.all().first?.key.description == "piekstra/a#1")
    }
}

func runRetryRequeueFlagTests() {
    suite.test("sweepRequeueMarksRetryNotRerequest") {
        let (s, e) = tempURLs()
        let store = QueueStore(stateURL: s, eventsURL: e, now: { Date(timeIntervalSince1970: 2_000_000) })
        let a = store.upsertDiscovered(pr("piekstra", "sweep", 1), org: "piekstra")
        store.update(a.key) { $0.state = .failed; $0.finishedAt = Date(timeIntervalSince1970: 1_000) }
        _ = store.retryEligibleFailures(now: Date(timeIntervalSince1970: 2_000_000), backoff: 3600)
        suite.expect(store.get(a.key)?.retryRequeue == true, "sweep requeue must be marked automatic")

        // A later rediscovery (real re-request) clears the marker: settle the row
        // as done first so upsertDiscovered treats reappearance as a re-request.
        store.update(a.key) { $0.state = .done; $0.finishedAt = Date(timeIntervalSince1970: 1_000) }
        _ = store.upsertDiscovered(pr("piekstra", "sweep", 1), org: "piekstra")
        suite.expect(store.get(a.key)?.state == .pending, "rediscovered done row requeues")
        suite.expect(store.get(a.key)?.retryRequeue == nil, "discovery requeue is a real re-request")
    }

    suite.test("upgradeResetMarksRetryNotRerequest") {
        let (s, e) = tempURLs()
        let store = QueueStore(stateURL: s, eventsURL: e)
        let a = store.upsertDiscovered(pr("piekstra", "upgrade", 2), org: "piekstra")
        store.update(a.key) { $0.state = .failed }
        _ = store.resetFailedForRetry()
        suite.expect(store.get(a.key)?.retryRequeue == true)
    }
}
