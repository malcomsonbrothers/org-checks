#!/usr/bin/env bash
# Tests for the sync rule of check-crate-tokens.py: in a pull request whose head is this
# repository's own default branch, rows at the default branch tip count as accepted. Usage:
#   scripts/check-crate-tokens-sync.test.sh
set -euo pipefail
. "$(dirname "$0")/crate-tokens-test-helpers.sh"

# A sync (head ref is the default branch in this repository, HEAD has the tip of origin/<default>,
# BASE does not) accepts the tip's lines at that value or lower; anything else compares with BASE only.
export CRATE_TOKENS_DEFAULT_BRANCH=master CRATE_TOKENS_REPO=o/r
synced() { CRATE_TOKENS_HEAD_REF=master CRATE_TOKENS_HEAD_REPO=o/r check "$@"; }
resolve() { cfg "$@"; git commit -q -a --amend --no-edit; } # the sync's merge resolution
repo sync; crate a; small a/src/lib.rs; save; git branch staging
cfg 'baseline a 65000' 'exempt data/**'; save; git update-ref refs/remotes/origin/master HEAD
git checkout -q staging; small b.rs; save; git merge -q --no-edit master
synced --ci HEAD^1; expect "a sync accepts the default branch's rows absent from the base" 0
synced --history-needed HEAD^1; expect "a possible sync with config additions takes full history" 3 'required$'
resolve 'baseline a 64000' 'exempt data/**'; synced --ci HEAD^1; expect "a sync accepts a row below the default branch's" 0
resolve 'baseline a 65001' 'exempt data/**'; synced --ci HEAD^1
expect "a sync cannot raise a row above the default branch's value" 1 'raised from 65000 to 65001$'
resolve 'baseline a 65000' 'exempt data/**' 'baseline x 60000'; synced --ci HEAD^1
expect "a sync cannot add a row the default branch lacks" 1 'new baseline row x 60000$'
resolve 'baseline a 65000' 'exempt data/**' 'exempt more/**'; synced --ci HEAD^1
expect "a sync cannot add an exempt line the default branch lacks" 1 'new exempt line more/\*\*$'
resolve 'baseline a 65000' 'exempt data/**'
CRATE_TOKENS_HEAD_REF=master CRATE_TOKENS_HEAD_REPO=fork/r check --ci HEAD^1
expect "a fork's branch named after the default branch is no sync" 1 'new exempt line data/\*\*$'
CRATE_TOKENS_HEAD_REF=master CRATE_TOKENS_HEAD_REPO='' check --ci HEAD^1
expect "a deleted fork's head is no sync" 1 'new exempt line data/\*\*$'
CRATE_TOKENS_HEAD_REF=feat CRATE_TOKENS_HEAD_REPO=o/r check --ci HEAD^1
expect "a feature branch that merged the default branch tip gets no rows from it" 1 'new baseline row a 65000$'
git checkout -q -b feat HEAD^1; cfg 'baseline a 65000' 'exempt data/**'; save
synced --ci HEAD~1; expect "a branch adding the default branch's rows without its tip still fails" 1 'new baseline row a 65000$'
git init -q "$work/shallow" && cd "$work/shallow"
git fetch -q --depth 2 "file://$work/sync" +staging:refs/check/merge +master:refs/remotes/origin/master
git checkout -q refs/check/merge; synced --ci HEAD^1; expect "a shallow clone is never a sync" 1 'new exempt line data/\*\*$'
# Inside a sync a touched unit with a row must still strictly shrink against the base, even
# when the default branch raised its row.
repo shrink; crate big; big big/src/lib.rs; save; n=$(tokens big); cfg "baseline big $n"; save
git branch staging; big big/src/lib.rs 41000; m=$(tokens big); cfg "baseline big $m"; save
git update-ref refs/remotes/origin/master HEAD; git checkout -q staging; small b.rs; save; git merge -q --no-edit master
synced --ci HEAD^1; expect "a sync still refuses a touched unit that grew" 1 "big: $m tokens must be strictly below measured base $n"
printf '%s\n' "$out" | grep -q 'raised from' && expect "the default branch's raised row itself is accepted" x
# Regrowth: master has 90000, staging lowered it to 70000; raising it back outside a sync is refused.
repo regrow; crate a; small a/src/lib.rs; cfg 'baseline a 90000'; save; git update-ref refs/remotes/origin/master HEAD
git checkout -q -b staging; cfg 'baseline a 70000'; save; git checkout -q -b pr; cfg 'baseline a 90000'; save
CRATE_TOKENS_HEAD_REF=feat check --ci staging; expect "a row regrown to the default branch's value is refused" 1 'raised from 70000 to 90000$'
CRATE_TOKENS_HEAD_REF=feat check --history-needed staging; expect "a raise outside a possible sync needs no history" 0 'not needed$'
synced --history-needed staging; expect "a raise in a possible sync takes full history" 3 'required$'
# A <p>/sync/<x> head into <p>/staging (BASE has projects/<p>/) is a sync too; no other head is.
repo psync; crate a; small a/src/lib.rs; small projects/movopop/README; save; git branch staging
cfg 'baseline a 65000' 'exempt data/**'; save; git update-ref refs/remotes/origin/master HEAD
git checkout -q staging; small b.rs; save; git merge -q --no-edit master
psync() { CRATE_TOKENS_BASE_REF=${3:-movopop/staging} CRATE_TOKENS_HEAD_REF=$1 CRATE_TOKENS_HEAD_REPO=o/r check "${2:---ci}" HEAD^1; }
psync movopop/sync/auto; expect "a project sync branch takes the default branch's rows" 0
psync movopop/sync/auto --history-needed; expect "a possible project sync with config additions takes full history" 3 'required$'
for h in movopop/sync/ other/sync/auto feat; do psync "$h"; expect "head $h into movopop/staging is no sync" 1 'new baseline row a 65000$'; done
psync other/sync/auto --ci other/staging; expect "a sync branch without projects/<p>/ at the base is no sync" 1 'new baseline row a 65000$'
resolve 'baseline a 65000' 'exempt data/**' 'exempt more/**'; psync movopop/sync/auto
expect "a project sync branch cannot add a line beyond the default branch's" 1 'new exempt line more/\*\*$'
# Regrowth through a merge: master has 90000, staging lowered it to 70000; a feature branch that
# merges master and raises it back is refused.
repo regrowmerge; crate a; small a/src/lib.rs; cfg 'baseline a 90000'; save; git branch staging
small m.rs; save; git update-ref refs/remotes/origin/master HEAD
git checkout -q staging; cfg 'baseline a 70000'; save
git checkout -q -b feat; git merge -q --no-edit master; cfg 'baseline a 90000'; save
CRATE_TOKENS_BASE_REF=movopop/staging CRATE_TOKENS_HEAD_REF=feat CRATE_TOKENS_HEAD_REPO=o/r check --ci staging
expect "a feature branch that merged master cannot regrow a row staging lowered" 1 'raised from 70000 to 90000$'
unset CRATE_TOKENS_DEFAULT_BRANCH CRATE_TOKENS_REPO CRATE_TOKENS_BASE_REF CRATE_TOKENS_HEAD_REF CRATE_TOKENS_HEAD_REPO

# The workflow passes the trusted event data the engine tells a sync from.
wf="$here/.github/workflows/crate-tokens.yml"
# shellcheck disable=SC2016 # literal expressions in the workflow
run grep -c -E 'CRATE_TOKENS_HEAD_REF: .*pull_request\.head\.ref }}$|CRATE_TOKENS_HEAD_REPO: .*pull_request\.head\.repo\.full_name }}$|CRATE_TOKENS_REPO: .*github\.repository }}$' "$wf"
expect "workflow: the engine tells a sync from trusted event data" 0 '^3$'

echo "crate-tokens sync tests: $passed passed, $failed failed"
[ "$failed" -eq 0 ]
