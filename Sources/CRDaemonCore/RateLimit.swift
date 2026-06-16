import Foundation

/// GitHub maintains independent rate-limit buckets per resource. We track the
/// two we touch separately, because the Search bucket (~30/min) does NOT move
/// the core bucket's `X-RateLimit-Remaining` and vice-versa — watching only one
/// would either throttle needlessly or blow the other.
public enum RateResource: String, Sendable {
    case core
    case search
}

/// A snapshot of one rate-limit bucket, parsed from response headers.
public struct RateBudget: Sendable, Equatable {
    public var limit: Int
    public var remaining: Int
    /// Absolute reset time (GitHub sends this as UTC epoch seconds).
    public var reset: Date
    public var observedAt: Date

    public init(limit: Int, remaining: Int, reset: Date, observedAt: Date) {
        self.limit = limit
        self.remaining = remaining
        self.reset = reset
        self.observedAt = observedAt
    }

    /// Should we hold off issuing another request on this bucket? True when the
    /// remaining count is at/below the floor AND the window hasn't reset yet.
    ///
    /// `reset` is absolute, so this stays correct across a sleep/wake that
    /// crossed the reset boundary — we compare against wall-clock `now`, never a
    /// stored monotonic duration.
    public func shouldThrottle(floor: Int, now: Date) -> Bool {
        if now >= reset { return false }  // window rolled over → treat as replenished
        return remaining <= floor
    }

    /// Seconds until the window resets (never negative).
    public func secondsUntilReset(now: Date) -> TimeInterval {
        max(0, reset.timeIntervalSince(now))
    }
}

/// Pure parsing of GitHub rate-limit / retry headers. Header lookup is
/// case-insensitive.
public enum RateLimitHeaders {
    private static func value(_ headers: [AnyHashable: Any], _ name: String) -> String? {
        if let v = headers[name] as? String { return v }
        for (key, val) in headers {
            if let ks = key as? String, ks.caseInsensitiveCompare(name) == .orderedSame {
                return val as? String
            }
        }
        return nil
    }

    /// Parse `X-RateLimit-*`. `reset` is interpreted as absolute UTC epoch seconds.
    public static func parse(_ headers: [AnyHashable: Any], now: Date)
        -> (resource: RateResource, budget: RateBudget)?
    {
        guard let remStr = value(headers, "x-ratelimit-remaining"), let rem = Int(remStr),
            let resetStr = value(headers, "x-ratelimit-reset"), let resetEpoch = Double(resetStr)
        else { return nil }
        let limit = Int(value(headers, "x-ratelimit-limit") ?? "") ?? 0
        let resource = RateResource(rawValue: value(headers, "x-ratelimit-resource") ?? "core") ?? .core
        let reset = Date(timeIntervalSince1970: resetEpoch)
        return (resource, RateBudget(limit: limit, remaining: rem, reset: reset, observedAt: now))
    }

    /// `Retry-After` in seconds (secondary/abuse rate limits). GitHub may send an
    /// integer-seconds form; we only support that (an HTTP-date form is rare here).
    public static func retryAfterSeconds(_ headers: [AnyHashable: Any]) -> TimeInterval? {
        guard let s = value(headers, "retry-after"), let secs = Double(s) else { return nil }
        return max(0, secs)
    }

    /// Server `Date` header — preferred over the local clock for backoff math
    /// because the local clock can jump on wake.
    public static func serverDate(_ headers: [AnyHashable: Any]) -> Date? {
        guard let s = value(headers, "date") else { return nil }
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = TimeZone(identifier: "GMT")
        fmt.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return fmt.date(from: s)
    }
}

/// Full-jitter exponential backoff. `rand` is injectable so tests are
/// deterministic.
public enum Backoff {
    public static func delay(
        attempt: Int,
        base: TimeInterval = 1,
        cap: TimeInterval = 300,
        rand: (ClosedRange<Double>) -> Double = { Double.random(in: $0) }
    ) -> TimeInterval {
        let exp = min(cap, base * pow(2.0, Double(max(0, attempt))))
        return rand(0...exp)
    }
}
