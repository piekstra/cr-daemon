# Architecture

cr-daemon is a `CRDaemonCore` library (all logic, unit-testable) behind a thin AppKit menu-bar shell.

## Control loop

`Coordinator` is a `@MainActor` engine running a ~2s tick loop. Each tick:

1. If paused / offline / rate-limited / safe-mode → reflect that state and return early.
2. If a poll is due, run one `AssignmentWatcher.pollOnce` (Search API), refresh the rate snapshot,
   log a `watch.poll` heartbeat, and schedule the next poll at `now + interval ± jitter`.
3. Run at most one queued review (`processQueueStep`).

A review `await`s to completion inside the tick, so the watcher naturally **yields to `cr`** — no
polling competes with `cr`'s own API calls on the shared token.

## Assignments & the queue

The **Search API is the source of truth**: `is:open is:pr review-requested:<reviewer>`. Each poll
reconciles the result set into `QueueStore`:

- New PR → `pending`.
- A `done`/`skipped` PR that reappears (re-requested) → re-queued to `pending`.
- A `pending` PR that's gone from the set (withdrawn/closed) → `skipped`.

`QueueStore` persists an atomically-rewritten `state.json` plus an append-only `events.jsonl`. One
writer, small N — JSON beats SQLite here and keeps the build dependency-free.

## Reviewing

`processQueueStep` picks the oldest eligible `pending` PR subject to: identity guard OK, not already
running, under the daily cap, under the per-PR attempt cap (with a retry cooldown), and an
**execution-time allowlist re-check**. `ReviewRunner` then runs
`cr review <url> --profile <reviewer> --json --max-concurrency 1`.

The outcome (approved / commented / changes-requested) is read **authoritatively from the GitHub
reviews endpoint** afterward, independent of `cr`'s JSON schema.

## Identity guard

At startup the Coordinator runs `cr me --profile <reviewer>` and refuses to review unless it resolves
to the configured reviewer login. This prevents the daemon from ever reviewing as the human author.

## Lifecycle & recovery

- **launchd** supervises the process (`KeepAlive = true` — relaunch on any stop: crash, wedge, or
  OS SIGTERM; `ThrottleInterval`; `RunAtLoad` at login). A user **Quit** unloads the agent
  (`launchctl bootout`) rather than exiting, since AppKit gives a user Quit and an OS SIGTERM the
  same clean exit code — launchd can't distinguish them, so survival must not hinge on exit code.
- **flock** guarantees a single instance.
- A **crash-loop guard** trips a visible safe mode after repeated rapid startups.
- **Sleep**: in-flight `cr` is SIGTERM'd; the review is re-queued. **Wake**: wait for the network,
  then poll; **orphan reconciliation** recovers any interrupted review with `cr review --retry-posts`
  (idempotent — `cr` exits early if the PR is already approved).
- Rate-limit resets are absolute epochs, so a sleep across a reset boundary doesn't strand the daemon.

## Resilience & self-update

Beyond launchd supervision, the daemon self-heals from softer failures:

- **Watchdog** — a detached task (independent of the main actor, so a busy loop can't disable it)
  wakes every 60s. If the control loop hasn't polled in over 300s while it *should* be polling
  (online, not paused, not rate-limited, no review running), it `exit(1)`s so launchd relaunches
  into a clean, reconciled state. A loop wedge is therefore never a permanent outage.
- **Failure-retry sweep** — a PR that fails `per_pr_attempt_cap` times is marked `failed`, not
  abandoned. Every ~30min the Coordinator re-queues failed PRs whose last failure is >1h old, so a
  transient/random failure (an overloaded model, a one-off 5xx) eventually succeeds.
- **cr-upgrade recovery** — at startup the daemon compares the installed `cr` version against the
  last one it saw (`cr-version.txt`). If it changed, an upstream fix may have landed, so it resets
  **all** failed PRs to `pending` for a fresh attempt.
- **Update check & one-click upgrade** — every ~6h (and once at startup) it checks the
  `codereview-cli` GitHub releases for a newer `cr`. A newer version surfaces as "↑ cr X.Y.Z
  available" in the menu; **Upgrade cr…** runs `brew update && brew upgrade --cask codereview-cli`
  (detached, safe mid-review) and then re-queues failed PRs. Both checks run detached behind a
  single-flight guard so a slow network call never blocks the loop.

## Modules

| File | Responsibility |
|---|---|
| `GitHubClient` | Actor: requests, dual rate buckets, conditional requests, backoff, breaker |
| `RateLimit` | Pure header parsing + budget math + backoff (the unit-test surface) |
| `AssignmentWatcher` | One poll → filter → reconcile |
| `QueueStore` | Persistence + reconciliation |
| `ReviewRunner` | Serialized `cr` execution + external cancel + identity probe |
| `Coordinator` | The engine + all safety guards |
| `Updater` | cr version check (GitHub releases) + one-click `brew` upgrade |
| `PowerNetworkMonitor` / `Supervisor` | Sleep/wake/network; flock + crash loop |
