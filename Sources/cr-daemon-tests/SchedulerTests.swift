import CRDaemonCore
import Foundation

private func pr(_ owner: String, _ repo: String, _ n: Int, attempts: Int = 0,
                startedAgo: TimeInterval? = nil, confirm: Bool? = nil,
                now: Date = Date()) -> Assignment {
    var a = Assignment(
        key: PRKey(owner: owner, repo: repo, number: n),
        url: "https://github.com/\(owner)/\(repo)/pull/\(n)",
        org: owner,
        discoveredAt: now.addingTimeInterval(TimeInterval(n)),  // stable FIFO order
        updatedAt: now)
    a.attempts = attempts
    if let ago = startedAgo { a.startedAt = now.addingTimeInterval(-ago) }
    a.awaitingConfirm = confirm
    return a
}

func runSchedulerTests() {
    let now = Date()

    suite.test("fillsSlotsOldestFirst") {
        let pending = [pr("a", "x", 1), pr("b", "y", 2), pr("c", "z", 3)]
        let picks = Coordinator.selectCandidates(
            pending: pending, inFlight: [], slots: 2, now: now, attemptCap: 3, cooldown: 300)
        suite.expect(picks.map { $0.key.number } == [1, 2], "first two, in order")
    }

    suite.test("neverTwoOfTheSameRepo") {
        let pending = [pr("a", "x", 1), pr("a", "x", 2), pr("b", "y", 3)]
        let picks = Coordinator.selectCandidates(
            pending: pending, inFlight: [], slots: 3, now: now, attemptCap: 3, cooldown: 300)
        suite.expect(picks.map { $0.key.number } == [1, 3], "second a/x PR held back")
    }

    suite.test("inFlightRepoExcluded") {
        let flying = PRKey(owner: "a", repo: "x", number: 9)
        let pending = [pr("a", "x", 1), pr("b", "y", 2)]
        let picks = Coordinator.selectCandidates(
            pending: pending, inFlight: [flying], slots: 2, now: now, attemptCap: 3, cooldown: 300)
        suite.expect(picks.map { $0.key.number } == [2], "a/x busy; only b/y picked")
    }

    suite.test("inFlightKeyNotRelaunched") {
        let flying = PRKey(owner: "a", repo: "x", number: 1)
        let pending = [pr("a", "x", 1)]
        let picks = Coordinator.selectCandidates(
            pending: pending, inFlight: [flying], slots: 2, now: now, attemptCap: 3, cooldown: 300)
        suite.expect(picks.isEmpty)
    }

    suite.test("respectsCooldownConfirmAndAttemptCap") {
        let pending = [
            pr("a", "x", 1, attempts: 3),                      // at cap
            pr("b", "y", 2, attempts: 1, startedAgo: 60),      // cooling down
            pr("c", "z", 3, confirm: true),                    // parked for confirm
            pr("d", "w", 4, attempts: 1, startedAgo: 600),     // cooldown elapsed
        ]
        let picks = Coordinator.selectCandidates(
            pending: pending, inFlight: [], slots: 4, now: now, attemptCap: 3, cooldown: 300)
        suite.expect(picks.map { $0.key.number } == [4])
    }

    suite.test("zeroSlotsPicksNothing") {
        let picks = Coordinator.selectCandidates(
            pending: [pr("a", "x", 1)], inFlight: [], slots: 0, now: now,
            attemptCap: 3, cooldown: 300)
        suite.expect(picks.isEmpty)
    }
}
