#!/bin/sh
#
# Parse-check every admin-console module and reject unsafe DOM sinks.
#
# The console ships as raw ES modules with no build step, so a syntax error
# reaches production and only surfaces as a blank page in the browser console.
# This is the cheapest gate that catches it.
#
# POSIX sh on purpose — this runs on a bare node image with no bash.

set -u

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
JS_DIR="$ROOT/public/ui/js"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

status=0

# ── Syntax ──
# node --check reads a .js file as CommonJS, where `export` is a syntax error,
# so every module is copied under a .mjs name before being checked.
count=0
for file in $(find "$JS_DIR" -name '*.js' -type f | sort); do
  flat=$(printf '%s' "${file#"$JS_DIR"/}" | tr '/' '_')
  cp "$file" "$WORK/$flat.mjs"
  count=$((count + 1))
done

if [ "$count" -eq 0 ]; then
  echo "ERROR: no modules found under $JS_DIR" >&2
  exit 1
fi

for module in "$WORK"/*.mjs; do
  if ! node --check "$module" >/dev/null; then
    echo "SYNTAX ERROR in $(basename "$module")" >&2
    node --check "$module" || true
    status=1
  fi
done
[ "$status" -eq 0 ] && echo "ok    $count module(s) parse"

# ── Unsafe sinks ──
# Everything the console renders comes from the API. ui.js builds DOM through
# textContent only; an innerHTML introduced later would turn a stored subject
# line or an SMTP error into markup.
if grep -rnE '\.(inner|outer)HTML|document\.write|[^A-Za-z]eval\(|new Function\(' "$JS_DIR" \
     | grep -vE ':[0-9]+:[[:space:]]*(//|\*)'; then
  echo "ERROR: unsafe DOM sink in the console — build nodes with el()/textContent instead" >&2
  status=1
else
  echo "ok    no unsafe DOM sinks"
fi

# ── Assets index.html references must exist ──
missing=0
for asset in $(grep -oE '/ui/(css|js)/[A-Za-z0-9._/-]+' "$ROOT/public/ui/index.html" | sort -u); do
  if [ ! -f "$ROOT/public$asset" ]; then
    echo "ERROR: index.html references a missing asset: $asset" >&2
    missing=1
  fi
done
if [ "$missing" -eq 0 ]; then
  echo "ok    every asset index.html references exists"
else
  status=1
fi

exit "$status"
