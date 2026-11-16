#!/usr/bin/env bash
# Runs check-crate-tokens.py through uv, so the check works as a one-liner with nothing
# cloned. Oversized units must be split; no new allowances are permitted.
# Arguments go to check-crate-tokens.py (--report, --ci BASE, --range BASE TIP UNIT...). The engine
# is the one beside this script, else CRATE_TOKENS_ENGINE, else org-checks master.
set -euo pipefail
url=https://raw.githubusercontent.com/malcomsonbrothers/org-checks/master/scripts/check-crate-tokens.py
command -v uv >/dev/null || {
  echo "crate-tokens: needs uv (https://docs.astral.sh/uv/getting-started/installation/)" >&2
  exit 2
}
engine=${CRATE_TOKENS_ENGINE:-}
here=${BASH_SOURCE[0]:-}
if [ -z "$engine" ] && [ -n "$here" ] && [ -f "$(dirname "$here")/check-crate-tokens.py" ]; then
  engine="$(dirname "$here")/check-crate-tokens.py"
fi
if [ -z "$engine" ]; then
  tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
  engine="$tmp/check-crate-tokens.py"
  curl -fsSL "$url" -o "$engine"
fi
uv run --no-config --quiet --script "$engine" "$@"
