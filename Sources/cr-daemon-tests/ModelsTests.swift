import CRDaemonCore
import Foundation

func runModelsTests() {
    suite.test("prKeyParse") {
        let k = PRKey.parse(url: "https://github.com/open-cli-collective/codereview-cli/pull/42")
        suite.expect(k == PRKey(owner: "open-cli-collective", repo: "codereview-cli", number: 42))
        suite.expect(k?.slug == "open-cli-collective/codereview-cli")
        suite.expect(k?.description == "open-cli-collective/codereview-cli#42")
        suite.expect(PRKey.parse(url: "https://github.com/piekstra/govee-cli/issues/9") == nil)
        suite.expect(PRKey.parse(url: "https://example.com/a/b/pull/1") == nil)
        suite.expect(PRKey.parse(url: "not a url at all") == nil)
    }

    suite.test("outcomeMapping") {
        suite.expect(ReviewOutcome.from(reviewState: "APPROVED") == .approved)
        suite.expect(ReviewOutcome.from(reviewState: "changes_requested") == .changesRequested)
        suite.expect(ReviewOutcome.from(reviewState: "COMMENTED") == .commented)
        suite.expect(ReviewOutcome.from(reviewState: "DISMISSED") == .unknown)
        suite.expect(ReviewOutcome.from(reviewState: nil) == .unknown)
    }

    suite.test("redactScrubsTokens") {
        let s = "auth ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 trailing"
        let scrubbed = Redact.scrub(s)
        suite.expect(!scrubbed.contains("ghp_ABCDEF"))
        suite.expect(scrubbed.contains("***redacted***"))
        suite.expect(scrubbed.contains("trailing"))
    }
}
