#!/usr/bin/env bash
# Tests for fresh-clone.sh and the copies embedded in the required workflows. It replays the
# failure that made it: another job leaves the shared runner's workspace as a blob-less clone,
# actions/checkout reuses that .git, and the check then needs a blob it cannot fetch.
# Usage: scripts/fresh-clone.test.sh
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 GIT_AUTHOR_NAME=t GIT_COMMITTER_NAME=t \
  GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_EMAIL=t@example.com
unset FRESH_CLONE_TOKEN COMMIT_SIZE_EXCEPTION COMMIT_SIZE_DEFAULT_BRANCH COMMIT_SIZE_BASE_REF \
  COMMIT_SIZE_HEAD_REF COMMIT_SIZE_HEAD_REPO COMMIT_SIZE_REPO FILE_LENGTHS_EXCEPTION FILE_LENGTHS_DEFAULT_BRANCH
passed=0 failed=0
clone="$here/scripts/fresh-clone.sh"
run() { out=$("$@" 2>&1) && rc=0 || rc=$?; }
expect() { # expect NAME RC [PATTERN that must appear in the output]
  if [ "$rc" = "$2" ] && { [ -z "${3:-}" ] || grep -q -e "$3" <<<"$out"; }; then
    passed=$((passed + 1))
  else
    failed=$((failed + 1)); echo "not ok: $1 (exit $rc, wanted $2${3:+, /$3/})"; printf '%s\n' "$out" | sed 's/^/    /'
  fi
}
save() { git add -A && git commit -q -m "$1"; }

# The remote: master, a pull request whose second commit rewrites a file (so the first version's
# blob is in no checkout), its head only under refs/pull/1/head like a fork's, and a merge ref.
cd "$work" && git init -q -b master src && cd src
echo 'exempt vendor/**' > .file-lengths && seq 3 > a.rs && save "chore: init"
base=$(git rev-parse HEAD)
git checkout -q -b pr && seq 10 > b.rs && save "feat: b" && seq 5 20 > b.rs && save "feat: rewrite b"
head=$(git rev-parse HEAD)
git checkout -q --detach master && git merge -q --no-ff -m "Merge pr" "$head" && merge=$(git rev-parse HEAD)
git checkout -q master && git branch -q -D pr
git clone -q --bare "$work/src" "$work/remote.git" && cd "$work/remote.git"
git update-ref refs/pull/1/head "$head" && git update-ref refs/pull/1/merge "$merge"
git config uploadpack.allowFilter true && git config uploadpack.allowReachableSHA1InWant true
url="file://$work/remote.git"

# The old way: a blob-less workspace left by another job, reused, then the remote unreachable
# (the job's credentials are gone). The rewritten blob is missing, and the check fails.
cd "$work" && git clone -q --filter=blob:none --no-checkout "$url" workspace && cd workspace
git fetch -q --no-tags origin '+refs/heads/*:refs/remotes/origin/*' "+$merge:refs/remotes/pull/1/merge"
git checkout -q --detach "$merge"
git config remote.origin.url "file://$work/unreachable.git"
run "$here/scripts/check-commit-size.sh" --ci "$base" "$head"
expect "old: a reused blob-less workspace fails the commit size check" 2 'promisor remote'

# The new way: a full clone in a new directory, which needs nothing from the remote afterwards.
offline() { mv "$work/remote.git" "$work/offline.git"; "$@"; mv "$work/offline.git" "$work/remote.git"; }
cd "$work" && cp -R workspace dest # DEST may hold a partial clone too: it is replaced
run "$clone" "$work/dest" "$url" "+$base:refs/check/base" "+$head:refs/check/head" \
  "+refs/heads/master:refs/remotes/origin/master"
expect "commit-size clone: full history, no filter" 0 'fetched'
run git -C "$work/dest" config --get-regexp 'promisor|partialclonefilter|partialclone'; expect "no promisor config" 1
run git -C "$work/dest" rev-parse --is-shallow-repository; expect "not shallow" 0 '^false$'
run git -C "$work/dest" rev-list --objects --missing=print --all; expect "every object present" 0
grep -q '^?' <<<"$out" && expect "no missing object" x
cd "$work/dest"
offline run "$here/scripts/check-commit-size.sh" --ci "$base" "$head"
expect "commit-size passes offline in the fresh clone" 0 '2 commit(s) checked'

# file-lengths and crate-tokens: the merge commit checked out and the base, one commit each.
run "$clone" "$work/merge" "$url" --depth 1 --checkout "$merge" "+$merge:refs/check/merge" "+$base:refs/check/base"
expect "file-lengths clone: depth 1 and checkout" 0 "checked out $merge"
[ "$(git -C "$work/merge" rev-parse HEAD)" = "$merge" ] && [ -f "$work/merge/b.rs" ] && rc=0 || rc=1
expect "HEAD is the merge commit, with its files" 0
cd "$work/merge"
offline run "$here/scripts/check-file-lengths.sh" --ci "$base"
expect "file-lengths passes offline, reading the base's .file-lengths" 0

# The token goes in an environment-only header, masked, and never into .git/config.
cd "$work"
FRESH_CLONE_TOKEN=secret-token run "$clone" "$work/tok" "$url" "+$head:refs/check/head"
expect "a token is masked in base64" 0 "^::add-mask::$(printf 'x-access-token:secret-token' | base64)$"
run grep -r -l -e secret-token -e "$(printf 'x-access-token:secret-token' | base64)" "$work/tok/.git"
expect "no token written to the clone" 1

# Failures: an unknown commit, bad arguments.
run "$clone" "$work/bad" "$url" "+$(printf '%040d' 1):refs/check/head"; expect "an unknown commit fails" 2 'could not fetch'
run "$clone" "$work/bad" "$url"; expect "no refspec fails" 2 usage
run "$clone" "$work/bad" "$url" --depth 0 HEAD; expect "a bad depth fails" 2 'positive number'
run "$clone" "$work/bad" "$url" --bogus HEAD; expect "an unknown flag fails" 2 usage

# Each required workflow fetches through this exact script, runs its check in the clone, and
# never uses actions/checkout (which reuses the workspace's .git) or a filter.
for name in commit-size file-lengths crate-tokens; do
  wf="$here/.github/workflows/$name.yml"
  run grep -n -E '^ *(- )?uses: actions/checkout|^ *(filter|fetch-depth):' "$wf"; expect "$name: no actions/checkout or filter" 1
  # shellcheck disable=SC2016 # literal expressions in the workflow
  run grep -c -E '^        working-directory: \$\{\{ runner\.temp \}\}/pr$|FRESH_CLONE_TOKEN: \$\{\{ github\.token \}\}$|"\$clone" "\$RUNNER_TEMP/pr" "\$GITHUB_SERVER_URL/\$GITHUB_REPOSITORY"' "$wf"
  expect "$name: fresh clone with the job token, check runs in it" 0 '^3$'
  run awk '/<<.CLONE.$/ { on = 1; next } /^ *CLONE$/ { on = 0 } on { sub(/^          /, ""); print }' "$wf"
  [ "$out" = "$(cat "$clone")" ] && rc=0 || rc=1
  expect "$name: workflow copy matches scripts/fresh-clone.sh (re-embed it)" 0
done

echo "fresh-clone tests: $passed passed, $failed failed"
[ "$failed" -eq 0 ]
