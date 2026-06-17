import CRDaemonCore
import Foundation

func runFailureClassifyTests() {
    typealias Kind = Coordinator.FailureKind

    suite.test("classifyGitHub502IsUpstream") {
        // The exact failure that was misread as a "model usage limit": a GitHub
        // 502 on the PR fetch, surfaced by cr as exit 5 (exitUpstream).
        let err = "GetPR: gitprovider: retryable upstream error: github: status 502 (response body redacted)\n"
        let r = Coordinator.classifyFailure(exit: 5, error: err)
        suite.expect(r.kind == .upstream, "github 5xx is an upstream/transient failure")
        suite.expect(
            r.summary.contains("status 502"), "summary names the cause, not just exit 5")
        suite.expect(!r.summary.contains("\n"), "summary is a single compact line")
    }

    suite.test("classifyExit5IsUpstreamEvenWithoutMarkers") {
        // exit 5 alone means an upstream dependency aborted the run.
        let r = Coordinator.classifyFailure(exit: 5, error: "review aborted")
        suite.expect(r.kind == .upstream)
    }

    suite.test("classifyModelOverloadAndRateLimit") {
        suite.expect(
            Coordinator.classifyFailure(exit: 1, error: "model is overloaded_error").kind == .upstream)
        suite.expect(
            Coordinator.classifyFailure(exit: 1, error: "rate limit exceeded").kind == .upstream)
        suite.expect(
            Coordinator.classifyFailure(exit: 1, error: "github: status 503").kind == .upstream)
    }

    suite.test("classifyTimeout") {
        suite.expect(Coordinator.classifyFailure(exit: -1, error: "timed out").kind == .timeout)
    }

    suite.test("classifyAuth") {
        suite.expect(
            Coordinator.classifyFailure(exit: 1, error: "github: status 403 forbidden").kind == .auth)
        suite.expect(
            Coordinator.classifyFailure(exit: 1, error: "bad credential").kind == .auth)
    }

    suite.test("classifyUnknownIsOther") {
        let r = Coordinator.classifyFailure(exit: 1, error: "some unrecognized failure")
        suite.expect(r.kind == .other)
        suite.expect(r.summary == "some unrecognized failure", "summary preserves a one-line tail")
    }

    suite.test("classifySummaryTakesLastNonEmptyLine") {
        let r = Coordinator.classifyFailure(
            exit: 5, error: "early noise\nmiddle\nGetPR: github: status 502\n")
        suite.expect(r.summary == "GetPR: github: status 502", "uses the last meaningful line")
    }
}
