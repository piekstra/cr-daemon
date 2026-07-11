import CRDaemonCore
import Foundation

func runConfigTests() {
    suite.test("validatedClamps") {
        let v = Config(
            searchPollIntervalSeconds: 1, maxConcurrentReviews: 5,
            reviewTimeoutSeconds: 10, perPrAttemptCap: 0, dailyReviewCap: 0
        ).validated()
        suite.expect(v.searchPollIntervalSeconds >= 30)
        suite.expect(v.maxConcurrentReviews == 5, "parallel reviews allowed")
        suite.expect(v.reviewTimeoutSeconds >= 120)
        suite.expect(v.perPrAttemptCap >= 1)
        suite.expect(v.dailyReviewCap >= 1)
    }

    suite.test("concurrencyClampBounds") {
        suite.expect(Config(maxConcurrentReviews: 0).validated().maxConcurrentReviews == 1)
        suite.expect(Config(maxConcurrentReviews: 99).validated().maxConcurrentReviews == 10)
        suite.expect(Config.default.maxConcurrentReviews == 3, "default parallelism")
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

    suite.test("lenientDecodePreservesAndDefaults") {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("old-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tmp) }
        // Old-schema config: no tier_label_profiles, only a few fields set.
        let json = #"{"reviewer_login":"bot","orgs":["acme"],"search_poll_interval_seconds":120}"#
        try json.write(to: tmp, atomically: true, encoding: .utf8)

        let c = Config.load(from: tmp)
        suite.expect(c.reviewerLogin == "bot", "set field preserved")
        suite.expect(c.orgs == ["acme"], "set field preserved")
        suite.expect(c.searchPollIntervalSeconds == 120, "set field preserved")
        suite.expect(c.crProfile == "reviewer", "missing field defaulted")
        suite.expect(
            c.tierLabelProfiles["cr:large"] == "reviewer-large", "new field defaulted, not reset")
    }

    suite.test("largeTimeoutDefaultsAndClamp") {
        let d = Config.default
        suite.expect(d.reviewTimeoutLargeSeconds == 2700, "large default 45min")
        suite.expect(d.timeoutGuidanceComment, "guidance comment on by default")
        // Large budget can never be below the base budget.
        let v = Config(reviewTimeoutSeconds: 1800, reviewTimeoutLargeSeconds: 600).validated()
        suite.expect(v.reviewTimeoutLargeSeconds == 1800, "large clamped up to base")
    }

    suite.test("largeTimeoutLenientDecode") {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("old2-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let json = #"{"review_timeout_seconds":900}"#
        try json.write(to: tmp, atomically: true, encoding: .utf8)
        let c = Config.load(from: tmp)
        suite.expect(c.reviewTimeoutLargeSeconds == 2700, "missing key gets default")
        suite.expect(c.timeoutGuidanceComment, "missing key gets default")
    }

    suite.test("matchedTierLabel") {
        let map = ["cr:large": "reviewer-large"]
        suite.expect(Config.matchedTierLabel(labels: ["cr:large"], tierMap: map) == "cr:large")
        suite.expect(
            Config.matchedTierLabel(labels: ["CR:Large", "bug"], tierMap: map) == "cr:large",
            "case-insensitive")
        suite.expect(Config.matchedTierLabel(labels: ["bug"], tierMap: map) == nil)
        suite.expect(Config.matchedTierLabel(labels: ["cr:large"], tierMap: [:]) == nil)
    }

    suite.test("selectProfileByLabel") {
        let map = ["cr:large": "reviewer-large"]
        suite.expect(
            Config.selectProfile(labels: ["cr:large"], tierMap: map, fallback: "reviewer")
                == "reviewer-large")
        suite.expect(
            Config.selectProfile(labels: ["CR:LARGE"], tierMap: map, fallback: "reviewer")
                == "reviewer-large", "case-insensitive")
        suite.expect(
            Config.selectProfile(labels: ["bug"], tierMap: map, fallback: "reviewer") == "reviewer")
        suite.expect(
            Config.selectProfile(labels: [], tierMap: map, fallback: "reviewer") == "reviewer")
        suite.expect(
            Config.selectProfile(labels: ["cr:large"], tierMap: [:], fallback: "reviewer")
                == "reviewer", "empty map → fallback")
    }
}
