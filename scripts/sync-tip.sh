#!/usr/bin/env bash
# Tells a sync pull request apart for the shrink-only config rules of commit-size, file-lengths and
# crate-tokens, which run it from beside their engine. A sync's head comes from this repository (REPO),
# its head ref is the default branch, or <p>/sync/<x> into BASE_REF <p>/staging where BASE has
# projects/<p>/, and in a full clone TIP has origin/<default>'s tip while BASE does not. Only then do
# that tip's own config lines count as old too; anything beyond them still needs the exception label.
#   sync-tip.sh DEFAULT REPO HEAD_REPO BASE_REF HEAD_REF BASE [TIP]
# Without TIP: exit 0 if the refs allow a sync, else 1. With TIP: prints the tip in a sync, else nothing.
set -euo pipefail
[ $# -eq 6 ] || [ $# -eq 7 ] || { echo "usage: sync-tip.sh DEFAULT REPO HEAD_REPO BASE_REF HEAD_REF BASE [TIP]" >&2; exit 2; }
d=$1 h=$5 base=$6
if [[ $4 =~ ^([A-Za-z0-9_-][A-Za-z0-9._-]*)/staging$ ]] && [[ $h == "${BASH_REMATCH[1]}"/sync/?* ]] &&
  [ -n "$base" ] && [ "$(git cat-file -t "$base:projects/${4%/staging}" 2>/dev/null)" = tree ]; then h=$d; fi
if [ -z "$d" ] || [ "$h" != "$d" ] || [ -z "$2" ] || [ "$3" != "$2" ]; then [ $# -eq 7 ] && exit 0; exit 1; fi
[ $# -eq 7 ] || exit 0
t=$(git rev-parse -q --verify "refs/remotes/origin/$d^{commit}") || exit 0
[ "$(git rev-parse --is-shallow-repository)" = false ] && git merge-base --is-ancestor "$t" "$7" || exit 0
[ -n "$base" ] && git merge-base --is-ancestor "$t" "$base" 2>/dev/null && exit 0
echo "$t"
