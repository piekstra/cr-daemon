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
