import CRDaemonCore
import Foundation

func runSearchParsingTests() {
    suite.test("parseFixtureFiltersNonPRs") {
        let url = try suite.require(
            Bundle.module.url(
                forResource: "search_review_requested", withExtension: "json",
                subdirectory: "Fixtures"), "fixture missing")
        let data = try Data(contentsOf: url)
        let prs = try suite.require(GitHubClient.parseSearchItems(data), "parse returned nil")

        suite.expect(prs.count == 2, "2 PRs (issue filtered)")
        let keys = Set(prs.map { $0.key.description })
        suite.expect(keys.contains("open-cli-collective/codereview-cli#42"))
        suite.expect(keys.contains("piekstra/govee-cli#7"))

        let bob = prs.first { $0.key.description == "piekstra/govee-cli#7" }
        suite.expect(bob?.author == "contributor-bob")

        let tagged = prs.first { $0.key.description == "open-cli-collective/codereview-cli#42" }
        suite.expect(tagged?.labels.contains("cr:large") == true, "labels parsed")
        suite.expect(bob?.labels.isEmpty == true, "no labels → empty")
    }

    suite.test("parseEmptyReturnsNil") {
        suite.expect(GitHubClient.parseSearchItems(Data("{}".utf8)) == nil)
    }
}
