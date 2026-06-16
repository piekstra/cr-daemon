#!/bin/bash
set -euo pipefail

# Guided, one-time setup of the reviewer identity cr-daemon posts approvals as.
# Stages a classic GitHub PAT (scopes: repo, read:org) into BOTH:
#   1. a dedicated cr profile (so `cr review --profile <p>` acts as that account)
#   2. a login-Keychain item the watcher reads (service "cr-daemon")
# The token is read from stdin and never appears in argv or the terminal.
#
# Env overrides: CR_PROFILE (default "reviewer"), REVIEWER_LOGIN (default
# "piekstra-dev"), REVIEWER_ACCOUNT (default = REVIEWER_LOGIN).

PROFILE="${CR_PROFILE:-reviewer}"
LOGIN="${REVIEWER_LOGIN:-piekstra-dev}"
ACCOUNT="${REVIEWER_ACCOUNT:-$LOGIN}"

command -v cr >/dev/null || { echo "error: cr CLI not found on PATH"; exit 1; }

echo "Reviewer setup — login=$LOGIN  cr-profile=$PROFILE"
echo "Create a CLASSIC PAT on the $LOGIN account with scopes: repo, read:org"
echo "Paste it below, then press Ctrl-D:"
TOKEN="$(cat)"
[ -n "$TOKEN" ] || { echo "error: no token provided"; exit 1; }

echo "==> creating cr profile '$PROFILE' and staging credential"
printf '%s' "$TOKEN" | cr init --profile "$PROFILE" --replace-profile --non-interactive \
    --git-host github.com --git-auth-mode pat --git-credential-ref "codereview/$PROFILE" \
    --git-token-stdin \
    --llm-adapter claude_cli --llm-auth subscription --llm-provider anthropic >/dev/null

echo "==> storing watcher token in Keychain (service=cr-daemon account=$ACCOUNT)"
security add-generic-password -U -s "cr-daemon" -a "$ACCOUNT" -D "GitHub PAT" \
    -j "cr-daemon reviewer token" -w "$TOKEN"

echo "==> verifying identity"
RESOLVED="$(cr me --profile "$PROFILE" --json 2>/dev/null \
    | /usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin)["profiles"][0]["login"])' 2>/dev/null || true)"
if [ "$RESOLVED" = "$LOGIN" ]; then
    echo "OK — cr profile '$PROFILE' resolves to '$RESOLVED'. Reviews will post as $LOGIN."
else
    echo "WARNING — resolved '$RESOLVED', expected '$LOGIN'. Check the token/account."
    exit 1
fi
