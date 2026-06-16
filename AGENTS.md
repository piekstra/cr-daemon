# AGENTS.md — guidance for AI coding agents

This file orients an AI agent (or a new human) working in **cr-daemon**. Read it before editing.
Be procedural and specific; cite `file:line`; assume competence.

## What this project is

A macOS menu-bar app + watcher that finds PRs assigned to a reviewer account and runs the public
`cr` CLI on them. The interesting, load-bearing concerns are **GitHub rate-limit discipline** and
**laptop-lifecycle robustness** — preserve them.

**Hard rule:** this repository depends only on the public `cr` CLI and the GitHub REST API. Do not
add references to, or assumptions about, any private/internal review tooling. Keep it generic.

## Build / test / run

```bash
swift build                       # debug build of the library + app
swift run cr-daemon-tests         # run the full test suite (see "Tests" below)
./Scripts/make-app.sh             # release build + assemble the .app bundle
./Scripts/install.sh              # install to ~/Applications + load the LaunchAgent
swift build -c release            # release build only
```

There is **no `swift test`**: the Command Line Tools toolchain ships neither XCTest nor
swift-testing, so tests are a plain executable (`Sources/cr-daemon-tests`) with a tiny harness
(`Harness.swift`). Add a test by writing a `func runXTests()` that calls `suite.test(...)` /
`suite.expect(...)`, and registering it in `Sources/cr-daemon-tests/main.swift`. Tests use only the
**public** API of `CRDaemonCore` (no `@testable`).

## Project map

- `Sources/CRDaemonCore/` — all logic, AppKit-free where possible, unit-testable:
  - `GitHubClient.swift` — actor; dual rate buckets, conditional requests, backoff, circuit breaker.
  - `RateLimit.swift` — **pure** header parsing + budget math + backoff (test here, not in the actor).
  - `AssignmentWatcher.swift` — one Search poll → allowlist/author filter → reconcile into the queue.
  - `QueueStore.swift` — atomic JSON state + JSONL event log + startup reconciliation.
  - `ReviewRunner.swift` — serialized `cr` invocation, identity probe, external cancellation.
  - `Coordinator.swift` — `@MainActor` engine: the tick loop, all safety guards, sleep/wake handling.
  - `PowerNetworkMonitor.swift`, `Supervisor.swift` — lifecycle (sleep/wake/network, flock, crash loop).
  - `Config.swift`, `Models.swift`, `Logger.swift`, `Secrets.swift`, `Paths.swift`, `Subprocess.swift`.
- `Sources/cr-daemon/` — thin AppKit shell: `main.swift`, `AppDelegate.swift`, `MenuBarController.swift`.
- `Scripts/` — packaging, install/uninstall, reviewer setup, the LaunchAgent plist template.
- `docs/` — architecture and rate-limiting notes.

## Lanes (what to touch for a given change)

- **Rate-limit behavior** → `RateLimit.swift` (pure) + `GitHubClient.swift`. Add a pure function and
  test it in `RateLimitTests` rather than reaching into the actor from a test.
- **What counts as an assignment / filtering** → `AssignmentWatcher.swift` + `Config.swift`.
- **Review decisions, guards, scheduling, sleep/wake** → `Coordinator.swift`.
- **Persistence / recovery** → `QueueStore.swift`.
- **UI only** → `MenuBarController.swift` / `AppDelegate.swift`. Keep logic out of the shell.

## Conventions

- Swift 5 language mode (see `Package.swift`); classes with internal locks are `@unchecked Sendable`.
- Keep `CRDaemonCore` UI-agnostic; the menu bar is a presentation layer over Coordinator state.
- Never log secrets. `Logger` and the event log run through `Redact.scrub`; never bypass them.
- Never put a token on a command line (argv is world-visible via `ps`). `cr` reads its token from its
  own store; the watcher reads via `/usr/bin/security`.
- Commit messages: `type(scope): summary` (e.g. `fix(client): honor Retry-After on 429`). Explain the
  motivation and the test plan in the body.

## Common traps

- **Don't tighten a poll into a loop.** Every GitHub call goes through `GitHubClient`, respects the
  buckets/floors, and the watcher interval is jittered. Adding an un-throttled call is a bug.
- **Don't block the actor while a review runs and expect cancellation to work** — `ReviewRunner` holds
  the `Process` and is cancelled out-of-band; keep it that way.
- **Don't store relative durations across sleep.** Rate-limit resets are absolute epochs on purpose.
- **Don't make the daemon review as the human.** The identity guard in `Coordinator.start()` is a
  safety boundary; keep it and the execution-time allowlist re-check intact.
- **Don't reintroduce XCTest/swift-testing** — they don't exist on a CLT-only toolchain (see "Tests").

## Verifying a change

1. `swift run cr-daemon-tests` is green.
2. `./Scripts/make-app.sh` produces a launchable bundle.
3. For runtime changes, launch the app and confirm `~/Library/Logs/cr-daemon/cr-daemon.log` shows a
   `watch.poll` heartbeat with sane `search_remaining`, and no `warn`/`error` lines.

## Question routing

| Question | Look at |
|---|---|
| "Is this within rate limits?" | `RateLimit.swift`, `GitHubClient.perform`, docs/rate-limiting.md |
| "When does a review actually run?" | `Coordinator.processQueueStep` / `runReview` |
| "What happens on sleep/wake?" | `Coordinator.handleSleep/handleWake`, `PowerNetworkMonitor` |
| "How is state recovered after a crash?" | `QueueStore` + `Coordinator.reconcileOrphans` |
