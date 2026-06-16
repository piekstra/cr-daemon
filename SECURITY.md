# Security Policy

## Reporting a vulnerability

Please **do not open a public issue** for security problems. Instead, open a private
[GitHub Security Advisory](https://github.com/piekstra/cr-daemon/security/advisories/new) on this
repository. You'll get an acknowledgement and a fix timeline.

## Token & credential handling

cr-daemon acts on GitHub as a dedicated reviewer account using a Personal Access Token. The token is
sensitive — it can read and approve PRs. cr-daemon is designed so the token is never exposed:

- **Storage.** The token lives in two places only: the `cr` credential store and a login-Keychain
  item (service `cr-daemon`). It is never written to a config file or committed to the repo.
- **No argv.** The token is never passed on a command line (visible via `ps`). `cr` reads it from its
  own store; the watcher reads it via `/usr/bin/security`; setup reads it from stdin.
- **Redaction.** All logs and the event journal pass through a token-scrubbing filter
  (`Redact.scrub`) as defense-in-depth.

### Recommendations for operators

- Use a **classic PAT scoped to `repo` + `read:org`** — no broader. Set an expiration and rotate it.
- Give the reviewer account access only to the repos you actually request its review on.
- The reviewer account's approvals satisfy branch protection; treat its credentials accordingly.
- If a token is ever exposed, **regenerate it immediately** (this invalidates the old one) and re-run
  `./Scripts/setup-reviewer.sh`.

## Build provenance

Released builds are ad-hoc signed and not notarized; build from source if you require a known
provenance. The app makes outbound requests only to `api.github.com` and shells out only to `cr`,
`security`, `launchctl`, and standard system tools.
