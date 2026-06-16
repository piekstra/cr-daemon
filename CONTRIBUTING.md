# Contributing to cr-daemon

Thanks for considering a contribution! cr-daemon is a small, focused macOS tool; the bar is
"keep it calm on the GitHub API and robust on a laptop."

## Development setup

You need macOS 13+ and the Xcode **Command Line Tools** (`xcode-select --install`). Full Xcode is
not required.

```bash
git clone https://github.com/piekstra/cr-daemon.git
cd cr-daemon
swift build                 # build the library + app
swift run cr-daemon-tests   # run the test suite
./Scripts/make-app.sh       # assemble a runnable .app for manual testing
```

> There is intentionally **no `swift test`** — the CLT toolchain ships neither XCTest nor
> swift-testing, so the suite is a plain executable (`Sources/cr-daemon-tests`) with a tiny harness.
> Add tests there and register them in `main.swift`.

## Project layout

`Sources/CRDaemonCore/` holds all logic and is unit-tested; `Sources/cr-daemon/` is the thin AppKit
menu-bar shell. See [AGENTS.md](AGENTS.md) for a per-file map and "lanes" (which file to touch for a
given kind of change).

## Lanes & ownership

- `main` is the stable branch; develop on a feature branch (`<your-handle>/<topic>`).
- Keep PRs focused. UI changes go in the shell; behavior changes go in `CRDaemonCore`.
- Don't reformat unrelated code in a feature PR.

## What we care about

1. **Rate-limit safety.** Any new GitHub call must go through `GitHubClient` and respect the
   buckets/floors. No tight loops, no un-jittered polling.
2. **Robustness.** Consider sleep/wake, network loss, crashes, and restarts. State changes should be
   recoverable.
3. **No secrets in logs or argv.** Use `Redact.scrub`; let `cr`/`security` hold tokens.
4. **No private-tooling references.** This project uses only the public `cr` CLI.

## Style & commits

- Match the surrounding Swift style (the repo ships a `.swift-format`).
- Commit messages: `type(scope): summary`, e.g. `feat(menu): show next-poll countdown`.
  Use the body to explain *why* and how you tested it.

## Submitting a PR

1. `swift run cr-daemon-tests` passes and you've added tests for new logic.
2. `./Scripts/make-app.sh` still builds a launchable app.
3. Fill out the PR template, including how you verified the change at runtime.
4. CI (macOS) must be green.

## Reporting bugs / requesting features

Use the issue templates. For security-sensitive reports, see [SECURITY.md](SECURITY.md) instead of a
public issue.

By contributing you agree your contributions are licensed under the [MIT License](LICENSE).
