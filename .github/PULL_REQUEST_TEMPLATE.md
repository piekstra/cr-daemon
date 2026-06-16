<!-- type(scope): summary  — e.g. fix(client): honor Retry-After on 429 -->

## What & why

<!-- What does this change and what problem does it solve? -->

## How it was tested

<!-- Commands run + what you observed. Include runtime verification for behavior changes. -->

- [ ] `swift run cr-daemon-tests` passes
- [ ] `./Scripts/make-app.sh` builds a launchable app
- [ ] For runtime changes: launched the app and checked the log shows a healthy `watch.poll`
      heartbeat with no `warn`/`error`

## Checklist

- [ ] New GitHub calls go through `GitHubClient` and respect the rate buckets/floors (no tight loops)
- [ ] Considered sleep/wake, network loss, crash, and restart where relevant
- [ ] No secrets in logs or on argv
- [ ] No references to private/internal tooling (public `cr` CLI only)
- [ ] Added/updated tests for new logic
- [ ] Commit messages use `type(scope): summary`
