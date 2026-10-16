#!/usr/bin/env bash
# Fails while org-hooks.yml's GUARD_BLOB or this repository's vendored guard differs from
# scripts/hooks/pre-push-guards.sh. Fix: update GUARD_BLOB to the printed id and re-run
# scripts/install-hooks.sh here.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
want=$(git hash-object scripts/hooks/pre-push-guards.sh)
pinned=$(sed -n 's/^ *GUARD_BLOB: *//p' .github/workflows/org-hooks.yml)
status=0
[ "$pinned" = "$want" ] || { echo "org-hooks.yml GUARD_BLOB is $pinned, want $want"; status=1; }
cmp -s scripts/hooks/pre-push-guards.sh .githooks/org/pre-push-guards.sh ||
  { echo ".githooks/org/pre-push-guards.sh differs; run scripts/install-hooks.sh"; status=1; }
[ "$status" -ne 0 ] || echo "org-hooks pin: ok ($want)"
exit "$status"
