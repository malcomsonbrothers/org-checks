#!/usr/bin/env bash
# Tests for current-base.sh and the copies embedded in the required workflows that compare a pull
# request with its base. GitHub's events cannot be replayed here, so this builds what a reopened
# pull request looks like: the event's base.sha is the base branch tip from when it was opened,
# while its merge commit (github.sha) is rebuilt on the current tip, which gained new allow-list
# rows since. Comparing with the stale base.sha blames the pull request for them; comparing with
# the merge's first parent does not. Needs uv for the crate token check.
# Usage: scripts/current-base.test.sh
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 GIT_AUTHOR_NAME=t GIT_COMMITTER_NAME=t \
  GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_EMAIL=t@example.com
unset FRESH_CLONE_TOKEN COMMIT_SIZE_EXCEPTION COMMIT_SIZE_DEFAULT_BRANCH COMMIT_SIZE_BASE_REF \
  COMMIT_SIZE_HEAD_REF COMMIT_SIZE_HEAD_REPO COMMIT_SIZE_REPO FILE_LENGTHS_EXCEPTION \
  FILE_LENGTHS_DEFAULT_BRANCH FILE_LENGTHS_HEAD_REF FILE_LENGTHS_HEAD_REPO FILE_LENGTHS_REPO \
  CRATE_TOKENS_EXCEPTION CRATE_TOKENS_DEFAULT_BRANCH CRATE_TOKENS_HEAD_REF CRATE_TOKENS_HEAD_REPO \
  CRATE_TOKENS_REPO BINARIES_EXCEPTION BINARIES_DEFAULT_BRANCH BINARIES_HEAD_REF BINARIES_HEAD_REPO \
  BINARIES_REPO BINARIES_LISTS
passed=0 failed=0
clone="$here/scripts/fresh-clone.sh" base_of="$here/scripts/current-base.sh"
run() { out=$("$@" 2>&1) && rc=0 || rc=$?; }
expect() { # expect NAME RC [PATTERN that must appear in the output]
  if [ "$rc" = "$2" ] && { [ -z "${3:-}" ] || grep -q -e "$3" <<<"$out"; }; then
    passed=$((passed + 1))
  else
    failed=$((failed + 1)); echo "not ok: $1 (exit $rc, wanted $2${3:+, /$3/})"; printf '%s\n' "$out" | sed 's/^/    /'
  fi
}
save() { git add -A && git commit -q -m "$1"; }
rows() { for f in .file-lengths .crate-tokens .commit-size; do printf 'exempt %s\n' "$@" > "$f"; done
  for g in "$@"; do printf 'allow %s generated\n' "$g"; done > .binary-allow; }

# The remote: the pull request is opened (stale = base.sha), master then gains a row in every
# allow-list, the pull request merges master in, and GitHub rebuilds the merge on the new tip.
cd "$work" && git init -q -b master src && cd src
rows 'vendor/**' && seq 3 > a.rs && save "chore: init"
stale=$(git rev-parse HEAD)
git checkout -q -b pr && seq 5 > b.rs && save "feat: b"
git checkout -q master && rows 'vendor/**' 'gen/**' && save "chore: exempt gen"
current=$(git rev-parse HEAD)
git checkout -q pr && git merge -q --no-edit master && head=$(git rev-parse HEAD)
git checkout -q --detach "$current" && git merge -q --no-ff -m "Merge pr" "$head" && merge=$(git rev-parse HEAD)
git checkout -q master && git branch -q -D pr
git clone -q --bare "$work/src" "$work/remote.git"
git -C "$work/remote.git" update-ref refs/pull/1/head "$head"
git -C "$work/remote.git" update-ref refs/pull/1/merge "$merge"
url="file://$work/remote.git" dflt="+refs/heads/master:refs/remotes/origin/master"

# file-lengths and crate-tokens: the merge and its parents (depth 2), checked out.
run "$clone" "$work/merge" "$url" --depth 2 --checkout "$merge" "+$merge:refs/check/merge" "$dflt"
expect "merge clone at depth 2" 0 fetched
cd "$work/merge"
run "$base_of" "$merge"; expect "the current base is the merge's first parent" 0 "^$current$"
run "$here/scripts/check-file-lengths.sh" --ci "$stale"
expect "file-lengths: the stale base.sha blames the pull request for master's row" 1 'new exempt line gen/\*\*'
run "$here/scripts/check-file-lengths.sh" --ci "$current"; expect "file-lengths: the current base passes" 0
run "$here/scripts/check-crate-tokens.sh" --ci "$stale"
expect "crate-tokens: the stale base.sha blames the pull request for master's row" 1 'new exempt line gen/\*\*'
run "$here/scripts/check-crate-tokens.sh" --ci "$current"; expect "crate-tokens: the current base passes" 0

# commit-size and no-binaries: full history of the head and the merge.
run "$clone" "$work/full" "$url" "+$merge:refs/check/merge" "+$head:refs/check/head" "$dflt"
expect "full clone" 0 fetched
cd "$work/full"
run "$base_of" "$merge"; expect "full clone: the current base is the merge's first parent" 0 "^$current$"
run "$here/scripts/check-commit-size.sh" --ci "$stale" "$head"
expect "commit-size: the stale base.sha blames the pull request for master's row" 1 'new exempt line gen/\*\*'
run "$here/scripts/check-commit-size.sh" --ci "$current" "$head"; expect "commit-size: the current base passes" 0
run "$here/scripts/check-binaries.sh" --ci "$stale" "$head"
expect "no-binaries: the stale base.sha blames the pull request for master's row" 1 'new allow row gen/\*\*'
run "$here/scripts/check-binaries.sh" --ci "$current" "$head"; expect "no-binaries: the current base passes" 0

# Fails closed: parents not fetched, not a merge commit, unknown commit, bad arguments.
run "$clone" "$work/shallow" "$url" --depth 1 "+$merge:refs/check/merge"; expect "depth 1 clone" 0 fetched
cd "$work/shallow" && run "$base_of" "$merge"; expect "parents not fetched fails" 2 'parents were not fetched'
cd "$work/full"
run "$base_of" "$current"; expect "a one-parent commit fails" 2 'not a two-parent merge commit'
run "$base_of" "$(printf '%040d' 1)"; expect "an unknown commit fails" 2 'not a commit'
run "$base_of"; expect "no argument fails" 2 usage

# Each workflow that compares with the base embeds this exact script, fetches the merge, passes
# its first parent to the engine and never reads the event's base.sha.
for name in commit-size file-lengths crate-tokens no-binaries; do
  wf="$here/.github/workflows/$name.yml"
  run awk '/<<.BASE.$/ { on = 1; next } /^ *BASE$/ { on = 0 } on { sub(/^          /, ""); print }' "$wf"
  [ "$out" = "$(cat "$base_of")" ] && rc=0 || rc=1
  expect "$name: workflow copy matches scripts/current-base.sh (re-embed it)" 0
  run grep -c -F -e 'pull_request.base.sha }}' -e 'PR_BASE' -e 'refs/check/base' "$wf"; expect "$name: never the event's base.sha" 1 '^0$'
  # shellcheck disable=SC2016 # literal expressions in the workflow
  run grep -c -F -e 'PR_MERGE: ${{ github.sha }}' -e '"+$PR_MERGE:refs/check/merge"' \
    -e 'base=$(cd "$RUNNER_TEMP/pr" && "$base_of" "$PR_MERGE")' -e 'echo "CURRENT_BASE=$base" >> "$GITHUB_ENV"' \
    -e '--ci "$CURRENT_BASE"' "$wf"
  expect "$name: fetches the merge and checks against its first parent" 0 '^5$'
done
for name in file-lengths crate-tokens; do
  run grep -c -F 'depth=(--depth 2)' "$here/.github/workflows/$name.yml"; expect "$name: fetches the merge's parents" 0 '^1$'
done

echo "current-base tests: $passed passed, $failed failed"
[ "$failed" -eq 0 ]
