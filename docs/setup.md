# Setup guide

cr-daemon reviews GitHub PRs as a **dedicated reviewer account** (call it `<reviewer>`), separate
from the PR author, so its approval counts toward branch protection.

## 1. Create the reviewer account + token

- Create a dedicated GitHub account (a machine account is permitted alongside your personal one).
- On that account, create a **classic Personal Access Token** with scopes **`repo`** and
  **`read:org`**. Set an expiration and plan to rotate it.

A classic token (not fine-grained) is recommended: `repo` lets the account read PRs and submit
approving reviews across every owner you grant it, with a single token.

## 2. Grant repo access — **write, not read**

> **Critical:** `<reviewer>` needs **write (push)** access for its approval to *count* toward
> branch protection. Read (or triage) only makes it *requestable* as a reviewer — GitHub silently
> **ignores an approving review from a user without write access**, so the PR stays
> `REVIEW_REQUIRED` even though the review shows as `APPROVED`. This is the most common setup
> mistake. Grant push.

Grant access where you'll use it — incrementally is fine:

- **Org repos** (e.g. an org you own): add `<reviewer>` to a **team with push** (the cleanest way to
  cover a whole org — add every repo to that team), or grant it push per-repo. Org membership with a
  read base permission is **not** enough.
  ```bash
  # add the reviewer to a push-access team, then add a repo to that team:
  gh api -X PUT orgs/<org>/teams/<team>/memberships/<reviewer>
  gh api -X PUT orgs/<org>/teams/<team>/repos/<org>/<repo> -f permission=push
  ```
- **Personal repos** (yours or another account you control): add `<reviewer>` as a collaborator with
  push. With the `gh` CLI:
  ```bash
  gh api -X PUT repos/<owner>/<repo>/collaborators/<reviewer> -f permission=push
  # accept as the reviewer account:
  GH_TOKEN=<reviewer-token> gh api -X PATCH user/repository_invitations/<id>
  ```

Verify it took: `gh api repos/<owner>/<repo>/collaborators/<reviewer>/permission --jq .permission`
should print `write` (or `admin`), not `read`.

> You can only add collaborators to repos where you have **admin**. For an account you don't admin,
> the owner has to add `<reviewer>` (or grant you admin).

## 3. Stage the token

```bash
./Scripts/setup-reviewer.sh
```

This reads the token from stdin (never argv), creates a dedicated `cr` profile
(`cr init --profile reviewer …`), stores a Keychain item for the watcher, and verifies the profile
resolves to `<reviewer>`. Override defaults with `REVIEWER_LOGIN`, `CR_PROFILE`, `REVIEWER_ACCOUNT`.

## 4. Install & run

```bash
./Scripts/install.sh
```

Edit `~/Library/Application Support/cr-daemon/config.json` (or "Edit config…" in the menu) to set the
`orgs` allowlist and `reviewer_login`. Then request `<reviewer>`'s review on a PR and watch the menu.

## Tip: try confirm mode first

Set `"autonomy": "confirm"` to have cr-daemon run `cr review --dry-run` and wait for you to click
**Approve & post** in the menu — a safe way to watch it work before enabling full autonomy.
