#!/usr/bin/env bash
# Installs the org pre-push guards in the git repository around the current directory:
#   curl -fsSL https://raw.githubusercontent.com/malcomsonbrothers/org-checks/master/scripts/install-hooks.sh | bash
# Vendors scripts/hooks/pre-push-guards.sh to .githooks/org/ (from this script's own clone when
# run from a file, else from org-checks at ORG_CHECKS_REF, default master) and makes sure an
# executable .githooks/pre-push calls it, inserting a marked block after an existing hook's
# shebang (the block replays the hook's stdin) or creating a minimal hook. Idempotent.
set -euo pipefail

ref=${ORG_CHECKS_REF:-master}
guard=.githooks/org/pre-push-guards.sh
hook=.githooks/pre-push
begin='# >>> org-checks pre-push guards >>>'

cd "$(git rev-parse --show-toplevel)"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
src=${BASH_SOURCE[0]:-}
if [ -n "$src" ] && [ -f "$(dirname "$src")/hooks/pre-push-guards.sh" ]; then
  cp "$(dirname "$src")/hooks/pre-push-guards.sh" "$tmp/guard"
else
  curl -fsSL "https://raw.githubusercontent.com/malcomsonbrothers/org-checks/$ref/scripts/hooks/pre-push-guards.sh" -o "$tmp/guard"
fi
mkdir -p .githooks/org
cp "$tmp/guard" "$guard" && chmod 755 "$guard"

cat > "$tmp/block" <<'BLOCK'
# >>> org-checks pre-push guards >>>
# Added by org-checks scripts/install-hooks.sh; re-run it to update .githooks/org/.
org_refs=$(mktemp) || exit 1
cat > "$org_refs"
bash "$(git rev-parse --show-toplevel)/.githooks/org/pre-push-guards.sh" "$@" < "$org_refs" || { rm -f "$org_refs"; exit 1; }
exec < "$org_refs"
rm -f "$org_refs"
# <<< org-checks pre-push guards <<<
BLOCK

if [ ! -e "$hook" ]; then
  { echo '#!/bin/sh'; cat "$tmp/block"; } > "$hook"
  echo "install-hooks: created $hook"
elif grep -qF "$begin" "$hook"; then
  echo "install-hooks: $hook already calls $guard"
else
  first=$(head -n 1 "$hook")
  case $first in
    '#!'*sh|'#!'*'sh '*) awk -v b="$tmp/block" 'NR == 1 { print; while ((getline l < b) > 0) print l; next } { print }' "$hook" > "$tmp/hook" ;;
    '#!'*) echo "install-hooks: $hook is not a shell script ($first); call $guard from it by hand" >&2; exit 1 ;;
    *) cat "$tmp/block" "$hook" > "$tmp/hook" ;;
  esac
  cat "$tmp/hook" > "$hook"
  echo "install-hooks: added the guard call to $hook"
fi
chmod 755 "$hook"
echo "install-hooks: installed $guard. Once per clone, run: git config core.hooksPath .githooks"
