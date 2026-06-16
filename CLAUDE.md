# CLAUDE.md

Guidance for AI agents working in this repo lives in **[AGENTS.md](AGENTS.md)** — read it first.

Quick reference:

- Build: `swift build` · Tests: `swift run cr-daemon-tests` · Package: `./Scripts/make-app.sh`
- There is no `swift test` (CLT has no XCTest/swift-testing); tests are a plain executable.
- Logic lives in `Sources/CRDaemonCore/`; the menu bar (`Sources/cr-daemon/`) is a thin shell.
- Preserve the two pillars: **GitHub rate-limit discipline** and **laptop-lifecycle robustness**.
- This project depends only on the public `cr` CLI — keep it that way.
