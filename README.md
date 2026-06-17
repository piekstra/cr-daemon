# cr-daemon

A native macOS **menu-bar app** that watches GitHub for pull requests assigned to a
dedicated reviewer account and reviews them automatically with the
[`cr`](https://github.com/open-cli-collective/codereview-cli) CLI — so a separate identity can
approve your PRs and satisfy a branch-protection "require 1 approval" rule without you approving
your own work.

It is built to be **calm on the GitHub API** (you should never see a request flood) and
**robust on a laptop** (survives sleep, lid-close, power changes, and network drops with no
duplicate process and no lost work).

> cr-daemon is a thin companion around the public `cr` CLI. It does not bundle or depend on any
> private tooling — it shells out to `cr review` and talks to the GitHub REST API.

---

## How it works

```
   ┌─────────────┐   review-requested:<reviewer>    ┌──────────────────┐
   │ GitHub      │ ───────────────────────────────▶ │ Search poller    │  (source of truth)
   │ Search API  │   (polled, conditional, jittered) │ in cr-daemon     │
   └─────────────┘                                   └────────┬─────────┘
                                                              │ new assignment
                                                              ▼
                                              ┌───────────────────────────────┐
                                              │ Queue (atomic JSON, crash-safe)│
                                              └───────────────┬───────────────┘
                                                              │ one at a time
                                                              ▼
                                   cr review <url> --profile reviewer --json
                                              │
                                              ▼  posts findings / approval AS the reviewer account
                                     ✅ approval satisfies branch protection
```

- **Discovery is the GitHub Search API** (`is:open is:pr review-requested:<reviewer>`), which
  reflects *current* assignment state and self-heals if anything is missed. Polled on a jittered
  interval with conditional requests.
- **Action is `cr review`**, run under a dedicated `cr` profile whose token belongs to the reviewer
  account. `cr` decides approve vs. comment vs. request-changes — cr-daemon never blanket-approves.
- The reviewer account is a **separate GitHub identity** from the PR author, so its approval counts
  toward branch protection.

## Requirements

- macOS 13 (Ventura) or later.
- The [`cr` CLI](https://github.com/open-cli-collective/codereview-cli)
  (`brew install open-cli-collective/tap/codereview-cli`), configured with a working LLM adapter.
- A **dedicated GitHub account** to review/approve as (a machine account is permitted by GitHub's
  Terms alongside your personal account).
- Xcode Command Line Tools (`xcode-select --install`) to build — full Xcode is **not** required.

## Install

```bash
git clone https://github.com/piekstra/cr-daemon.git
cd cr-daemon
./Scripts/setup-reviewer.sh    # one-time: stage the reviewer token (see below)
./Scripts/install.sh           # build, install to ~/Applications, load the LaunchAgent
```

The icon appears in your menu bar. It's also launchable from Spotlight (⌘-Space → "cr-daemon").

## Reviewer setup

cr-daemon reviews as a **separate account** (referred to here as `<reviewer>`). One-time setup:

1. **Create the account** and a **classic Personal Access Token** on it with scopes
   `repo` and `read:org`. (A classic token is used so the same setup works if you later enable
   notification-based triggers; `repo` is what lets it read PRs and submit approvals.)
2. **Give it _write_ (push) access** to the repos you want it to review: add `<reviewer>` as a
   collaborator (or org member) with **push** — read/triage is *not* enough. GitHub silently
   ignores an approving review from a user without write access, so the PR stays `REVIEW_REQUIRED`
   and branch protection is never satisfied even though the review shows as approved. It only needs
   access where you actually request its review — grant incrementally. See
   [docs/setup.md](docs/setup.md) for the full rationale.
3. **Stage the token**: `./Scripts/setup-reviewer.sh` creates a dedicated `cr` profile and a
   Keychain item from the token (read via stdin — never on the command line). It verifies the
   profile resolves to `<reviewer>`.
4. **Request its review** on a PR. Within a poll interval cr-daemon picks it up and runs `cr`.

cr-daemon **refuses to run reviews** if the configured `cr` profile resolves to anyone other than
the configured reviewer login — a guard against accidentally reviewing as yourself.

## Review agents (recommended)

Review *quality* depends on cr's **trusted review agents** — specialized reviewer personas cr
selects per PR. With none configured, cr does a single generic pass and reports
`Reviewers: unavailable`. Point cr at an agent source; the
[Open CLI Collective set](https://github.com/open-cli-collective/codereview-cli) (shipped in that
repo's `.codereview/agents/`) is a good default:

```bash
# copy a trusted snapshot OUT of the git worktree, then register it
cp -R ~/Dev/codereview-cli/.codereview/agents "$HOME/Library/Application Support/codereview/"
cr config agent-source add "$HOME/Library/Application Support/codereview/agents" --profile reviewer
cr agents list --profile reviewer   # verify (no worktree warning)
```

See **[docs/agents.md](docs/agents.md)** for the trust caveat (use a stable, non-PR-mutable path),
verification, and notes on writing your own agents.

## Configuration

`~/Library/Application Support/cr-daemon/config.json` (hot-reloadable via the menu). Defaults are
conservative.

| Key | Default | Meaning |
|---|---|---|
| `reviewer_login` | `piekstra-dev` | GitHub login the daemon reviews as |
| `reviewer_keychain_account` | `piekstra-dev` | Keychain account holding the watcher token (service `cr-daemon`) |
| `cr_profile` | `reviewer` | cr profile invoked (`cr review --profile …`) |
| `orgs` | `[piekstra, strikeforcezero, open-cli-collective]` | Owner/org allowlist (case-insensitive) |
| `autonomy` | `auto` | `auto` = live review on assignment; `confirm` = dry-run then approve from the menu |
| `search_poll_interval_seconds` | `90` | Base poll interval (jittered) |
| `core_rate_floor` / `search_rate_floor` | `500` / `5` | Stop spending a bucket below this many remaining |
| `review_timeout_seconds` | `1200` | Wall-clock kill for a single `cr` run |
| `per_pr_attempt_cap` | `3` | Attempts before a PR is marked failed — failures are auto-retried (after ~1h, and whenever `cr` upgrades), not permanently quarantined |
| `daily_review_cap` | `50` | Global runaway guard |
| `author_allowlist` | `null` | If set, only act on PRs by these authors |
| `tier_label_profiles` | `{cr:large→reviewer-large}` | PR label → cr profile, to route a tagged PR to a deeper model tier ([docs/agents.md](docs/agents.md#deeper-reviews-on-demand-the-crlarge-label)) |
| `notify_on` | all `true` | macOS notifications for approvals / findings / errors |
| `paused` | `false` | Master pause |

## Being gentle on the GitHub API

This was a first-class design goal. cr-daemon:

- Treats the **Search API as the source of truth** and polls it on a **jittered interval** (never a
  tight loop), with **conditional requests** so unchanged responses are free `304`s.
- Tracks the **core (5000/hr) and search (30/min) buckets independently** and **stops spending**
  either below a configurable floor.
- Honors `Retry-After` on secondary-limit `403`/`429` responses and otherwise backs off with
  **full-jitter exponential backoff**, behind a **circuit breaker**.
- Computes reset waits from the **absolute `X-RateLimit-Reset`** epoch, so a sleep across a reset
  boundary never leaves it stuck throttled.
- **Serializes reviews** (one `cr` at a time) and passes `--max-concurrency 1`, so the watcher and
  `cr` never compound pressure on the shared token.

See [docs/rate-limiting.md](docs/rate-limiting.md).

## Laptop robustness

- A **launchd LaunchAgent** supervises the process: it relaunches only on a crash
  (`KeepAlive = { SuccessfulExit = false, Crashed = true }`), throttles relaunches, and starts at
  login. A clean **Quit** stays quit.
- A **flock single-instance lock** means launching a second copy (e.g. from Spotlight) just re-opens
  the menu — never a duplicate process.
- A **crash-loop guard** drops into a visible "safe mode" instead of thrashing.
- **Sleep/wake + network** are an explicit state machine: on sleep an in-flight review is interrupted
  and re-queued; on wake it waits for the network before polling and recovers any interrupted review
  with `cr review --retry-posts`.
- The queue is an **atomically-rewritten JSON file** plus an append-only event log, so assignments
  and in-flight state survive crashes and restarts.

See [docs/architecture.md](docs/architecture.md).

## Menu

Identity + status, both rate buckets, the live queue (Open / Review now / Skip, or Approve & post in
confirm mode), recent results, Pause/Resume, Poll now, Edit/Reload config, Open logs, Open data
folder, Quit.

## Signing & Gatekeeper

The build is **ad-hoc signed**, not notarized — it's a local, single-user tool. macOS may ask you to
allow it on first launch. Because an ad-hoc signature changes on every rebuild, macOS may re-prompt
for Keychain access after an upgrade; cr-daemon avoids this for its token by reading through
`/usr/bin/security` (a stable, Apple-signed tool) rather than the Keychain APIs directly.

## Uninstall

```bash
./Scripts/uninstall.sh   # removes the LaunchAgent + app; keeps your config/state/logs
```

## FAQ

**Will it approve everything?** No. cr-daemon only *triggers* `cr` on assignment; `cr`'s own review
decides approve / comment / request-changes.

**Does it need to run all the time?** It only acts while running. launchd keeps it alive and restarts
it at login; closing the lid or sleeping is fine.

**Can I see what it did?** Yes — the menu shows recent outcomes, and
`~/Library/Logs/cr-daemon/cr-daemon.log` is a structured (token-redacted) JSONL log.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) and [AGENTS.md](AGENTS.md). Licensed under
[MIT](LICENSE).
