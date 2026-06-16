# Configuring review agents

cr-daemon runs `cr review`, and the *quality* of a review depends on cr's **trusted review
agents** — specialized reviewer personas cr selects per PR. With **no agent source configured**,
cr falls back to a single generic pass and its summary shows `Reviewers: unavailable`. Configuring
agents is what makes reviews thorough.

## Suggested defaults: the Open CLI Collective set

The [`codereview-cli`](https://github.com/open-cli-collective/codereview-cli) repo ships a starter
set under `.codereview/agents/`:

| Agent | Reviews |
|---|---|
| `documentation:docs` | Documentation accuracy, examples, durable repo knowledge |
| `structure:repo-health` | Structural risks that compound across future changes |
| `policies:conventions` | CLI/repo changes against shared + repo-local conventions |
| `go:implementation-tests` | Idiomatic Go + tests that prove the change |
| `automation:ci-release` | CI, release, packaging, build-support changes |

cr selects the relevant subset per PR (e.g. `documentation:docs` for a docs-only PR), so unrelated
agents (like `go:*` on a Swift PR) simply don't fire.

## Setup

> **Trust matters.** An agent source steers what the reviewer looks for, so it must live somewhere a
> PR author **cannot modify**. cr warns if you point it at a path inside a git worktree (a malicious
> PR could rewrite the agents). Copy a pinned snapshot to a stable location instead.

```bash
# 1. Get the agents (clone the repo, or use an existing checkout)
git clone https://github.com/open-cli-collective/codereview-cli.git ~/Dev/codereview-cli

# 2. Copy a trusted snapshot OUT of the worktree
cp -R ~/Dev/codereview-cli/.codereview/agents "$HOME/Library/Application Support/codereview/"

# 3. Register the source on the profile cr-daemon uses (default: "reviewer")
cr config agent-source add "$HOME/Library/Application Support/codereview/agents" --profile reviewer

# 4. Verify — you should see the agents listed with no worktree warning
cr agents list --profile reviewer
```

cr-daemon needs **no restart** — it re-invokes `cr` per review, and `cr` re-reads its config each run.

## Verify it works

```bash
# Which agents cr would consider for a specific PR:
cr agents list "https://github.com/OWNER/REPO/pull/N" --profile reviewer

# Plan a full review without posting (shows the selected Reviewers + findings):
cr review --dry-run --profile reviewer "https://github.com/OWNER/REPO/pull/N"
```

A healthy dry-run shows `Reviewers | <selected agents>` instead of `unavailable`.

## Notes

- To use agents for your **own** manual `cr review` too, also register the source on your `default`
  profile: `cr config agent-source add <dir> --profile default`.
- The snapshot is pinned — refresh it deliberately (`cp -R` again) when you want upstream updates.
- **Writing your own agents** (e.g. for your stack — Rust, Swift/AppKit, Tauri): agents are just
  `index.yaml` + `prompt.md` directories. See the format and contribution guidance in the
  [`codereview-cli`](https://github.com/open-cli-collective/codereview-cli) repo.

## Deeper reviews on demand: the `cr:large` label

Reviews run at the cr profile's model tier (Sonnet by default). To run a **specific** PR at the
**large tier (Opus)** — for a tricky or high-stakes change — add the **`cr:large`** label when you
request the review:

```bash
gh pr edit <PR> --add-label cr:large    # then request the reviewer as usual
```

cr-daemon reads each PR's labels from the Search results (no extra API call) and routes a tagged PR
to a dedicated **`reviewer-large`** cr profile. The mapping lives in `config.json` and is
extensible (e.g. add `cr:medium`):

```json
"tier_label_profiles": { "cr:large": "reviewer-large" }
```

Set the profile up once — it can reuse the same credential and agent source:

```bash
cr init --profile reviewer-large --replace-profile --non-interactive \
  --git-host github.com --git-auth-mode pat --git-credential-ref codereview/reviewer \
  --llm-adapter claude_cli --llm-auth subscription --llm-reviewer-model-tier large
cr config agent-source add "$HOME/Library/Application Support/codereview/agents" --profile reviewer-large
```

The daemon **validates each tier profile at startup** (it must resolve to the reviewer login); a
missing or wrong-identity profile is dropped and the PR falls back to the default profile. Because
`cr config show` shows `large → claude-opus-4-8`, `cr:large` reviews run on Opus. They cost more and
take longer, so keep the label opt-in for the PRs that warrant it.
