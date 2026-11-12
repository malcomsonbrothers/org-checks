#!/usr/bin/env bash
# Prints the base a required workflow compares a pull request with: the first parent of the pull
# request's merge commit (github.sha), the base branch tip GitHub built that merge on. Never the
# event's pull_request.base.sha: a reopened pull request keeps the base.sha from when it was
# opened while GitHub rebuilds the merge on the current tip, so comparing with it blames the pull
# request for rows the base branch gained since. Run it in the clone, after fetching the merge
# with its parents (depth 2 or more). Needs only bash and git.
#   current-base.sh MERGE
# Fails (exit 2) unless MERGE is a commit with exactly two parents, the first present with its tree.
set -euo pipefail
fail() { echo "current-base: $*" >&2; exit 2; }
[ $# -eq 1 ] && [ -n "$1" ] || fail "usage: current-base.sh MERGE"
merge=$(git rev-parse --verify --quiet "$1^{commit}") || fail "$1 is not a commit in this clone"
read -r -a ps < <(git rev-list --parents -n 1 "$merge" || :)
[ "${#ps[@]}" -eq 3 ] || fail "$merge is not a two-parent merge commit, or its parents were not fetched"
git cat-file -e "${ps[1]}^{tree}" 2>/dev/null || fail "the first parent ${ps[1]} of $merge was not fetched"
echo "${ps[1]}"
