#!/usr/bin/env bash
# Tests for the sync rule of check-commit-size.sh (see scripts/sync-tip.sh): the default branch's
# commits are skipped, and in a sync its .commit-size lines count as old. Usage:
#   scripts/check-commit-size-sync.test.sh
set -euo pipefail
. "$(dirname "$0")/commit-size-test-helpers.sh"

# Any pull request skips commits on the default branch; a sync (head ref is the default branch in
# this repository, TIP has its tip, BASE does not) also takes its .commit-size lines as old.
repo sync; git branch -q staging master; git checkout -q master
cfg 'exempt gen/**'; lines 1500 big.rs; save "feat: labelled on master"; git update-ref refs/remotes/origin/master HEAD
export COMMIT_SIZE_DEFAULT_BRANCH=master COMMIT_SIZE_REPO=o/r
COMMIT_SIZE_HEAD_REF=master COMMIT_SIZE_HEAD_REPO=o/r check --ci staging master; expect "a sync skips the default branch's commits and lines" 0 '0 commit(s) checked'
COMMIT_SIZE_HEAD_REF=master COMMIT_SIZE_HEAD_REPO=fork/r check --ci staging master; expect "a fork's default branch is no sync" 1 'new exempt line gen/\*\*$'
git checkout -q staging; git merge -q master; cfg; save "chore: staging drops it"
git checkout -q -b regrow; cfg 'exempt gen/**'; save "chore: regrow"
COMMIT_SIZE_HEAD_REF=master COMMIT_SIZE_HEAD_REPO=o/r check --ci staging HEAD; expect "a line the base dropped is new again" 1 'new exempt line gen/\*\*$'
# A <p>/sync/<x> head into <p>/staging (BASE has projects/<p>/) is a sync too; no other head is.
repo psync; git checkout -q master; lines 1 projects/movopop/README; save; git branch -q staging
cfg 'exempt gen/**'; save "chore: exempt on master"; git update-ref refs/remotes/origin/master HEAD
git checkout -q staging; lines 1 s.rs; save; git merge -q --no-edit refs/remotes/origin/master
psync() { COMMIT_SIZE_BASE_REF=${2:-movopop/staging} COMMIT_SIZE_HEAD_REF=$1 COMMIT_SIZE_HEAD_REPO=o/r check --ci staging~1 HEAD; }
psync movopop/sync/auto; expect "a project sync branch takes the default branch's lines" 0 'commit-size: ok'
for h in movopop/sync/ other/sync/auto feat; do psync "$h"; expect "head $h into movopop/staging is no sync" 1 'new exempt line gen/\*\*$'; done
psync other/sync/auto other/staging; expect "a sync branch without projects/<p>/ at the base is no sync" 1 'new exempt line gen/\*\*$'
cfg 'exempt gen/**' 'exempt more/**'; save "chore: sneak a line in"
psync movopop/sync/auto; expect "a project sync branch cannot add a line beyond the default branch's" 1 'new exempt line more/\*\*$'
unset COMMIT_SIZE_DEFAULT_BRANCH COMMIT_SIZE_REPO

echo "commit-size sync tests: $passed passed, $failed failed"
[ "$failed" -eq 0 ]
