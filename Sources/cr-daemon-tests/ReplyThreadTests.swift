import CRDaemonCore
import Foundation

func runReplyThreadTests() {
    suite.test("parseUnansweredReplyThreads") {
        let url = try suite.require(
            Bundle.module.url(
                forResource: "pr_review_comments", withExtension: "json", subdirectory: "Fixtures"),
            "fixture missing")
        let data = try Data(contentsOf: url)
        let threads = GitHubClient.parseUnansweredReplyThreads(data, reviewerLogin: "piekstra-dev")

        // Thread #1: reviewer started, human (piekstra) replied last → unanswered.
        // Thread #3: reviewer started but reviewer replied last → answered, excluded.
        // Thread #5: reviewer didn't start → excluded.
        suite.expect(threads.count == 1, "only the unanswered human-reply thread")
        suite.expect(threads.first?.rootCommentID == 1)
        suite.expect(threads.first?.lastReplyAuthor == "piekstra")
        suite.expect(threads.first?.lastReplyBody == "why?")
    }

    suite.test("parseRepliesEmpty") {
        suite.expect(
            GitHubClient.parseUnansweredReplyThreads(Data("[]".utf8), reviewerLogin: "x").isEmpty)
    }
}
