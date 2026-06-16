import CRDaemonCore
import Foundation

func runConfigTests() {
    suite.test("validatedClamps") {
        let v = Config(
            searchPollIntervalSeconds: 1, maxConcurrentReviews: 5,
            reviewTimeoutSeconds: 10, perPrAttemptCap: 0, dailyReviewCap: 0
        ).validated()
        suite.expect(v.searchPollIntervalSeconds >= 30)
        suite.expect(v.maxConcurrentReviews == 1)
        suite.expect(v.reviewTimeoutSeconds >= 120)
        suite.expect(v.perPrAttemptCap >= 1)
        suite.expect(v.dailyReviewCap >= 1)
    }

    suite.test("orgAllowlistCaseInsensitive") {
        let c = Config(orgs: ["Piekstra", "Open-CLI-Collective"])
        suite.expect(c.isOrgAllowed("piekstra"))
        suite.expect(c.isOrgAllowed("OPEN-CLI-COLLECTIVE"))
        suite.expect(!c.isOrgAllowed("evilcorp"))
    }

    suite.test("authorAllowlist") {
        suite.expect(Config(authorAllowlist: nil).isAuthorAllowed("anyone"))
        let c = Config(authorAllowlist: ["piekstra"])
        suite.expect(c.isAuthorAllowed("Piekstra"))
        suite.expect(!c.isAuthorAllowed("bob"))
        suite.expect(!c.isAuthorAllowed(nil))
    }

    suite.test("saveLoadRoundTripSnakeCase") {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("cfg-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tmp) }
        var c = Config.default
        c.orgs = ["piekstra"]
        c.searchPollIntervalSeconds = 120
        try c.save(to: tmp)

        let raw = (try? String(contentsOf: tmp, encoding: .utf8)) ?? ""
        suite.expect(raw.contains("search_poll_interval_seconds"), "snake_case key")
        suite.expect(raw.contains("reviewer_login"), "reviewer_login key")

        let loaded = Config.load(from: tmp)
        suite.expect(loaded.searchPollIntervalSeconds == 120)
        suite.expect(loaded.orgs == ["piekstra"])
    }

    suite.test("loadMissingReturnsDefault") {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("nope-\(UUID().uuidString).json")
        suite.expect(Config.load(from: missing) == .default)
    }
}
