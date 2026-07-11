import CRDaemonCore
import Foundation

func runTimeoutNoticeTests() {
    suite.test("timeoutNoticeSuggestsLargeLabelOnDefaultTier") {
        let body = TimeoutNotice.body(minutes: 15, usedLargeTier: false, largeLabel: "cr:large")
        suite.expect(body.contains(TimeoutNotice.marker), "carries the marker")
        suite.expect(body.contains("15 minutes"), "names the budget")
        suite.expect(body.contains("`cr:large`"), "suggests the tier label")
        suite.expect(body.contains("smaller, focused PRs"), "suggests splitting")
        suite.expect(body.contains("Re-request"), "suggests retrying")
    }

    suite.test("timeoutNoticeOmitsLabelWhenAlreadyLarge") {
        let body = TimeoutNotice.body(minutes: 45, usedLargeTier: true, largeLabel: "cr:large")
        suite.expect(!body.contains("Add the `cr:large`"), "no label suggestion on large tier")
        suite.expect(body.contains("even on the large tier"), "split advice acknowledges the tier")
    }

    suite.test("timeoutNoticeOmitsLabelWhenNoTierConfigured") {
        let body = TimeoutNotice.body(minutes: 15, usedLargeTier: false, largeLabel: nil)
        suite.expect(!body.contains("Add the"), "no label bullet without tier routing")
        suite.expect(body.contains("smaller, focused PRs"))
    }

    suite.test("timeoutNoticeSingularMinute") {
        let body = TimeoutNotice.body(minutes: 1, usedLargeTier: false, largeLabel: nil)
        suite.expect(body.contains("1 minute,"), "singular unit")
    }
}
