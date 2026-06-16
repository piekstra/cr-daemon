# Rate-limit discipline

Being gentle on the GitHub API is a primary design goal. Every call goes through `GitHubClient`,
which layers these protections:

## Two independent buckets

GitHub meters **core** (~5000/hr — PR reads, review reads) and **search** (~30/min) separately, and
the search bucket does **not** move the core `X-RateLimit-Remaining`. cr-daemon tracks both from
response headers (`RateLimitHeaders.parse`) and treats them independently. Watching only one would
either throttle needlessly or overrun the other.

## Proactive floors

Before spending a bucket, the client checks `RateBudget.shouldThrottle(floor:now:)`: if the remaining
count is at/below the configured floor (`core_rate_floor` / `search_rate_floor`) and the window
hasn't reset, it declines and reports when the window resets. The watcher then waits.

## Conditional requests

Search requests carry `If-None-Match` from a stored ETag; an unchanged response is a `304` that does
**not** count against the bucket. On `304` the client returns the cached result set, so reconciliation
is a no-op.

## Absolute reset math

`X-RateLimit-Reset` is an absolute UTC epoch. Waits are computed against wall-clock `now`, never a
stored duration — so sleeping across a reset boundary correctly frees the bucket instead of leaving
the daemon stuck (regression-tested in `RateLimitTests.shouldThrottleAcrossClockJump`).

## Secondary limits & backoff

On `403`/`429` secondary (abuse) limits, the client honors `Retry-After`; absent that, it uses
full-jitter exponential backoff. Repeated failures open a **circuit breaker** that blocks calls until
a backoff window elapses.

## Polling cadence

The Search poll interval is jittered (`base + up to 20%`) so wakes/restarts don't synchronize into a
burst. At the default 90s that's roughly one search request per ~1.5 minutes — a tiny fraction of the
30/min budget.

## Serialized reviews

At most one `cr` runs at a time, invoked with `--max-concurrency 1`, and the watcher yields while it
runs. `cr`'s own GitHub calls and the watcher's never compound on the shared token.
