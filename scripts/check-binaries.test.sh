#!/usr/bin/env bash
# Tests for check-binaries.sh and the copies embedded in no-binaries.yml. Each case runs in a
# throwaway git repo. Usage: scripts/check-binaries.test.sh
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 GIT_AUTHOR_NAME=t GIT_COMMITTER_NAME=t \
  GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_EMAIL=t@example.com
unset BINARIES_EXCEPTION BINARIES_DEFAULT_BRANCH BINARIES_HEAD_REF BINARIES_HEAD_REPO BINARIES_REPO BINARIES_LISTS
passed=0 failed=0

repo() { # fresh repo on master with one commit
  cd "$work" && rm -rf "$1" && git init -q -b master "$1" && cd "$1"
  printf 'x\n' > README.md && save init
}
cfg() { printf '%s\n' "$@" > .binary-allow; }
save() { git add -A && git commit -q -m "${1:-c}"; }
run() { out=$("$@" 2>&1) && rc=0 || rc=$?; }
check() { run "$here/scripts/check-binaries.sh" "$@"; }
expect() { # expect NAME RC [PATTERN that must appear in the output]
  if [ "$rc" = "$2" ] && { [ -z "${3:-}" ] || printf '%s\n' "$out" | grep -q -e "$3"; }; then
    passed=$((passed + 1))
  else
    failed=$((failed + 1)); echo "not ok: $1 (exit $rc, wanted $2${3:+, /$3/})"; printf '%s\n' "$out" | sed 's/^/    /'
  fi
}

# The basics: a binary fails, a row allows it, a new row needs the label.
repo basic; printf 'a\0b' > blob.dat; save
check HEAD~1; expect "a new binary fails" 1 '^\[FAIL\] blob.dat'
cfg 'allow blob.dat test data'; save; check HEAD~2; expect "a row allows it" 0
check --ci HEAD~1 HEAD; expect "a new row fails in CI" 1 '^\[FAIL\] .binary-allow: new allow row blob.dat$'
BINARIES_EXCEPTION=true check --ci HEAD~1 HEAD; expect "the label allows a new row" 0 'allowed by the binary-exception label'

# A sync (head ref is the default branch in this repository, TIP has the tip of origin/<default>,
# BASE does not) takes the tip's rows as old; any other pull request compares with BASE only.
repo sync; cfg 'allow icons/** app icons'; save; git branch staging
export BINARIES_DEFAULT_BRANCH=master BINARIES_REPO=o/r
cfg 'allow icons/** app icons' 'allow fixtures/** test data'; save; git update-ref refs/remotes/origin/master HEAD
git checkout -q staging; printf 'y\n' > b.txt; save; git checkout -q -b synced; git merge -q --no-edit master
BINARIES_HEAD_REF=master BINARIES_HEAD_REPO=o/r check --ci staging master
expect "a sync takes the default branch's rows" 0 'no-binaries: ok'
BINARIES_HEAD_REF=master BINARIES_HEAD_REPO=fork/r check --ci staging master
expect "a fork's default branch is no sync" 1 'new allow row fixtures/\*\*$'
BINARIES_HEAD_REF=master BINARIES_HEAD_REPO=o/r BINARIES_REPO='' check --ci staging master
expect "no repository named is no sync" 1 'new allow row fixtures/\*\*$'
BINARIES_HEAD_REF=feat BINARIES_HEAD_REPO=o/r check --ci staging synced
expect "a feature branch that merged the default branch tip gets no rows from it" 1 'new allow row fixtures/\*\*$'
export BINARIES_HEAD_REF=master BINARIES_HEAD_REPO=o/r
git checkout -q -b feat staging; cfg 'allow icons/** app icons' 'allow fixtures/** test data'; save
check --ci staging feat; expect "a branch adding the default branch's row without its tip still fails" 1 'new allow row fixtures/\*\*$'
git clone -q --depth 1 --no-local -b master "file://$PWD" ../shallow 2>/dev/null; cd ../shallow
git update-ref refs/remotes/origin/master HEAD; git fetch -q --depth 1 origin staging:refs/check/base
check --ci refs/check/base master; expect "a shallow clone is never a sync" 1 'new allow row fixtures/\*\*$'
unset BINARIES_HEAD_REF BINARIES_HEAD_REPO
# Regrowth: master has a row, staging dropped it; adding it back is not a sync.
repo regrow; cfg 'allow fixtures/** test data'; save; git update-ref refs/remotes/origin/master HEAD
git checkout -q -b staging; cfg '# none'; save; git checkout -q -b pr; cfg 'allow fixtures/** test data'; save
BINARIES_HEAD_REF=pr BINARIES_HEAD_REPO=o/r check --ci staging pr
expect "a row the base dropped cannot come back without the label" 1 'new allow row fixtures/\*\*$'
unset BINARIES_DEFAULT_BRANCH BINARIES_REPO

# The workflow runs on pull requests, tells a sync apart, and embeds this exact engine and lists.
wf="$here/.github/workflows/no-binaries.yml"
# shellcheck disable=SC2016 # literal expressions in the workflow
run grep -c -E 'BINARIES_HEAD_REF: .*head\.ref }}$|BINARIES_HEAD_REPO: .*head\.repo\.full_name }}$|BINARIES_REPO: .*github\.repository }}$|"\+refs/heads/\$DEFAULT_BRANCH:refs/remotes/origin/\$DEFAULT_BRANCH"$' "$wf"
expect "workflow: the engine can tell a sync and has the default branch tip" 0 '^4$'
run awk '/<<.CLONE.$/ { on = 1; next } /^ *CLONE$/ { on = 0; next } !on && /--depth/' "$wf"
expect "workflow: full history outside the embedded clone script, so a sync can be told apart" 0 '^$'
for pair in ENGINE:check-binaries.sh LISTS:lists/no-binaries.txt CLONE:fresh-clone.sh; do
  tag=${pair%%:*} file=${pair#*:}
  run awk -v t="$tag" '$0 ~ "<<." t ".$" { on = 1; next } $0 ~ "^ *" t "$" { on = 0 } on { sub(/^          /, ""); print }' "$wf"
  [ "$out" = "$(cat "$here/scripts/$file")" ] && rc=0 || rc=1
  expect "workflow copy matches scripts/$file (re-embed it)" 0
done

echo "no-binaries tests: $passed passed, $failed failed"
[ "$failed" -eq 0 ]
