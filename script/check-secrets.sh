#!/bin/sh
#
# Refuse to ship a commit that carries a credential.
#
# This service stores other people's SMTP passwords and Telegram bot tokens, and
# the master key unlocks every one of them. A key committed here is a key that
# has to be rotated everywhere, so the check runs on every push.
#
# It scans what git tracks, not the working tree: a local .env is expected and
# gitignored, and only what a commit actually carries can leak.
#
# POSIX sh on purpose — this runs on a bare alpine image with no bash.

set -u

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT" || exit 1

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
LIST="$WORK/files"

status=0
fail() { echo "ERROR: $*" >&2; status=1; }

# Tracked, scannable files. .env.example holds placeholders by design, and this
# script necessarily contains the very patterns it looks for.
git ls-files -z 2>/dev/null \
  | tr '\0' '\n' \
  | grep -vE '^(\.env\.example|script/check-secrets\.sh|node_modules/|vendor/)' \
  | tr '\n' '\0' > "$LIST"

if [ ! -s "$LIST" ]; then
  echo "ERROR: no tracked files to scan — is this a git checkout?" >&2
  exit 1
fi

# grep over the tracked file list. Returns 0 when something matched.
# NUL-delimited and fed on stdin: `xargs -a` is a GNU extension that BSD xargs
# does not have, and silently doing nothing is the worst failure mode for a
# security check.
scan() { xargs -0 grep -nIE "$1" < "$LIST" 2>/dev/null; }

# ── 1. The real .env must never be committed ──
if git ls-files --error-unmatch .env >/dev/null 2>&1; then
  fail ".env is tracked by git — it must stay untracked (see .gitignore)"
else
  echo "ok    .env is not tracked"
fi

# ── 2. Credential assignments whose value looks real ──
# Placeholders in docs (your-master-api-key, <run: ...>, abc123...) are fine;
# 16+ characters of key-shaped entropy is not.
NAMES='MASTER_API_KEY|ENCRYPTION_KEY|DB_PASS|SMTP_PASS|FTP_PASS|BOT_TOKEN|HANDLER_SECRET|AWS_SECRET_ACCESS_KEY'
if scan "($NAMES)[\"']?[[:space:]]*[:=][[:space:]]*[\"']?[A-Za-z0-9+/=_-]{16,}" \
     | grep -viE 'your-|-here|changeme|example|placeholder|xxxx|\.\.\.|securerandom|\$\{|\$[A-Z_]'; then
  fail 'a credential-shaped value is assigned to a secret name above'
else
  echo "ok    no credential-shaped assignments"
fi

# ── 3. A live 64-hex key pasted next to an X-Api-Key header ──
if scan 'X-Api-Key["'"'"':, ]+[0-9a-f]{64}'; then
  fail 'a full 64-hex API key appears next to an X-Api-Key header'
else
  echo "ok    no live API keys in X-Api-Key examples"
fi

# ── 4. Private key blocks ──
if scan '^-+BEGIN [A-Z ]*PRIVATE KEY-+'; then
  fail 'a private key block is committed above'
else
  echo "ok    no private key blocks"
fi

exit "$status"
