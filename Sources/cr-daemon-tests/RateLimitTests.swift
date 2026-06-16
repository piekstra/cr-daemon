import CRDaemonCore
import Foundation

func runRateLimitTests() {
    suite.test("parseValidHeaders") {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let headers: [AnyHashable: Any] = [
            "X-RateLimit-Limit": "5000",
            "X-RateLimit-Remaining": "4321",
            "X-RateLimit-Reset": "1000600",
            "X-RateLimit-Resource": "core",
        ]
        let parsed = RateLimitHeaders.parse(headers, now: now)
        suite.expect(parsed?.resource == .core, "resource")
        suite.expect(parsed?.budget.remaining == 4321, "remaining")
        suite.expect(parsed?.budget.limit == 5000, "limit")
        suite.expect(parsed?.budget.reset == Date(timeIntervalSince1970: 1_000_600), "reset")
    }

    suite.test("parseCaseInsensitiveSearch") {
        let parsed = RateLimitHeaders.parse(
            [
                "x-ratelimit-remaining": "5",
                "x-ratelimit-reset": "2000000",
                "x-ratelimit-resource": "search",
            ], now: Date())
        suite.expect(parsed?.resource == .search, "search resource")
        suite.expect(parsed?.budget.remaining == 5, "remaining")
    }

    suite.test("parseMissingReturnsNil") {
        suite.expect(RateLimitHeaders.parse(["foo": "bar"], now: Date()) == nil)
    }

    suite.test("retryAfter") {
        suite.expect(RateLimitHeaders.retryAfterSeconds(["Retry-After": "30"]) == 30)
        suite.expect(RateLimitHeaders.retryAfterSeconds(["nope": "x"]) == nil)
    }

    suite.test("shouldThrottleAcrossClockJump") {
        let reset = Date(timeIntervalSince1970: 2000)
        let budget = RateBudget(
            limit: 5000, remaining: 3, reset: reset,
            observedAt: Date(timeIntervalSince1970: 1900))
        suite.expect(
            budget.shouldThrottle(floor: 10, now: Date(timeIntervalSince1970: 1950)),
            "below floor before reset")
        suite.expect(
            !budget.shouldThrottle(floor: 1, now: Date(timeIntervalSince1970: 1950)),
            "above floor")
        suite.expect(
            !budget.shouldThrottle(floor: 10, now: Date(timeIntervalSince1970: 2500)),
            "woke past reset → replenished")
    }

    suite.test("secondsUntilResetNonNegative") {
        let b = RateBudget(
            limit: 1, remaining: 0, reset: Date(timeIntervalSince1970: 1000),
            observedAt: Date(timeIntervalSince1970: 1000))
        suite.expect(abs(b.secondsUntilReset(now: Date(timeIntervalSince1970: 900)) - 100) < 0.001)
        suite.expect(b.secondsUntilReset(now: Date(timeIntervalSince1970: 2000)) == 0)
    }

    suite.test("backoffDeterministicAndCapped") {
        suite.expect(
            abs(Backoff.delay(attempt: 3, base: 1, cap: 300, rand: { $0.upperBound }) - 8) < 1e-6)
        suite.expect(
            abs(Backoff.delay(attempt: 20, base: 1, cap: 300, rand: { $0.upperBound }) - 300) < 1e-6)
    }
}
