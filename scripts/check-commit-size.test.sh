#!/usr/bin/env bash
# Tests for check-commit-size.sh and the copy embedded in the required workflow. Each case
# runs in a throwaway git repo. Usage: scripts/check-commit-size.test.sh
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 GIT_AUTHOR_NAME=t GIT_COMMITTER_NAME=t \
  GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_EMAIL=t@example.com
unset COMMIT_SIZE_EXCEPTION COMMIT_SIZE_DEFAULT_BRANCH
passed=0 failed=0 zero=0000000000000000000000000000000000000000

repo() { # fresh repo with one small commit on master, work continuing on branch pr
  cd "$work" && rm -rf "$1" && git init -q -b master "$1" && cd "$1"
  echo init > README && save init && git checkout -q -b pr
}
body() { awk -v n="$1" -v t="${3:-x}" 'BEGIN { for (i = 1; i <= n; i++) print t i }'; }
lines() { mkdir -p "$(dirname "$2")"; body "$1" "$2" "${3:-x}" > "$2"; }
cfg() { printf '%s\n' "$@" > .commit-size; }
save() { git add -A && git commit -q -m "${1:-c}"; }
run() { out=$("$@" 2>&1) && rc=0 || rc=$?; }
check() { run "$here/scripts/check-commit-size.sh" "$@"; }
expect() { # expect NAME RC [PATTERN that must appear in the output]
  if [ "$rc" = "$2" ] && { [ -z "${3:-}" ] || printf '%s\n' "$out" | grep -q -e "$3"; }; then
    passed=$((passed + 1))
  else
    failed=$((failed + 1)); echo "not ok: $1 (exit $rc, wanted $2${3:+, /$3/})"; printf '%s\n' "$out" | sed 's/^/    /'
  fi
}

# The limit is 1,000 changed lines per commit; over it fails, naming the commit and its size.
repo limit; lines 1000 a.rs; save "feat: exactly at the limit"
check master; expect "1,000 lines pass" 0 '1000 changed lines'
lines 1001 b.rs; save "feat: one line over"
check master; expect "1,001 lines fail" 1 '^\[FAIL\] [0-9a-f]* feat: one line over: 1001 changed lines, limit 1000'
printf '%s\n' "$out" | grep -q 'FAIL.*exactly at the limit' && expect "only the oversized commit is named" x

# Additions plus deletions: rewriting 501 lines is 1,002 changed lines.
repo edits; lines 501 a.rs; save; lines 501 a.rs y; save "refactor: rewrite"
check master; expect "additions plus deletions count" 1 'rewrite: 1002 changed lines'

# Each commit is measured, not the pull request total.
repo slices; lines 600 a.rs; save one; lines 600 b.rs; save two
check master; expect "two 600-line commits pass" 0 '2 commit(s) checked'
repo squash; lines 600 a.rs; lines 600 b.rs; save squashed
check master; expect "the same change squashed fails" 1 'squashed: 1200 changed lines'

# Lockfiles at any depth never count; other files in the same commit still do.
repo locks; for f in Cargo.lock bun.lock package-lock.json pnpm-lock.yaml yarn.lock uv.lock; do
  lines 3000 "web/$f"; done; lines 3000 Cargo.lock; save "chore(deps): bump"
check master; expect "lockfile-only commit passes" 0 '0 changed lines (+21000 exempt)'
lines 3001 Cargo.lock; lines 1001 src.rs; save "feat: code with a lockfile"
check master; expect "lockfiles do not hide code" 1 'code with a lockfile: 1001 changed lines (+'
lines 1001 Cargo.lock.rs; save; check HEAD~1; expect "only the exact lockfile names" 1 '1001 changed lines'

# .commit-size exempts generated or vendored paths; it is read at TIP.
repo exempt; cfg '# generated' 'exempt gen/**' 'exempt api/*.json'; save cfg
lines 5000 gen/deep/x.ts; lines 2000 api/openapi.json; save "chore: regenerate"
check master; expect "exempt paths pass" 0 '0 changed lines (+7000 exempt)'
lines 1001 api/v2/openapi.json; save; check HEAD~1; expect "* stays within one segment" 1 '1001 changed lines'
cfg 'exempt gen/**' 'exempts x'; save; check HEAD~1; expect "malformed line fails" 1 'unknown or malformed line'

# --ci: .commit-size may only shrink against BASE unless the label is set.
repo shrink; cfg 'exempt gen/**'; save cfg; git branch -q base
check --ci base HEAD; expect "unchanged config passes" 0
cfg 'exempt gen/**' 'exempt vendor/**'; lines 1500 vendor/x.js; save "chore: vendor"
check --ci base HEAD; expect "new exempt line fails" 1 'FAIL\] .commit-size: new exempt line vendor/\*\*'
COMMIT_SIZE_EXCEPTION=true check --ci base HEAD; expect "the label allows a new exempt line" 0 'allowed by the commit-size-exception label: new exempt line'
cfg; save "chore: drop exemptions"; check --ci HEAD~1 HEAD; expect "removing lines passes" 0

# The label allows oversized commits too.
repo label; lines 1500 a.rs; save big
COMMIT_SIZE_EXCEPTION=true check --ci master HEAD; expect "label allows an oversized commit" 0 'allowed by the commit-size-exception label: [0-9a-f]* big'
COMMIT_SIZE_EXCEPTION=false check --ci master HEAD; expect "only true counts" 1 'commit-size-exception label on the pull request, then closing and reopening'

# Merge commits are skipped; renames count only their edits; binaries count nothing.
repo merges; git checkout -q master; lines 900 m1.rs; save; lines 900 m2.rs; save; git checkout -q pr
lines 10 p.rs; save; git merge -q --no-edit master; check master~2 HEAD
expect "merge commit skipped" 0 '3 commit(s) checked'
repo renames; lines 2000 a.rs; git add -A && git commit -q -m add; git mv a.rs b.rs; save "refactor: move"
check HEAD~1; expect "a pure rename is 0 lines" 0 '0 changed lines: refactor: move'
head -c 300000 /dev/urandom > blob.bin; save bin; check HEAD~1; expect "binary changes count 0" 0 '0 changed lines: bin'

# BASE: zero falls back to the merge-base with the default branch; a root commit is measured.
repo fallback; lines 1001 a.rs; save big; git update-ref refs/remotes/origin/master master
check "$zero" HEAD; expect "zero base uses the merge-base" 1 '1 commit(s) checked'
COMMIT_SIZE_DEFAULT_BRANCH=master check "$zero"; expect "default branch override" 1 'big: 1001'
cd "$work" && rm -rf root && git init -q -b master root && cd root && lines 1001 a.rs && save root
check; expect "root commit, no base" 1 'root: 1001 changed lines'
check nosuchcommit; expect "unknown base fails" 2 'not in this clone'
check --bogus; expect "unknown flag fails" 2 'usage'

# The required workflow always enforces, on pull requests, from self-hosted runners.
wf="$here/.github/workflows/commit-size.yml"
run grep -n -E '^  pull_request:$|^    types: \[opened, synchronize, reopened\]$|runs-on: \[self-hosted, Linux, metal\]$|fetch-depth: 0$|--ci "\$PR_BASE" "\$PR_HEAD"' "$wf"
[ "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" = 5 ] && rc=0 || rc=1
expect "required workflow: pull_request trigger, full history, self-hosted runner, --ci BASE HEAD" 0
run grep -n -E 'runs-on:.*(ubuntu|windows|macos)-' "$wf"; expect "no GitHub-hosted runner" 1

# The required workflow embeds this exact script.
run awk '/<<.ENGINE.$/ { on = 1; next } /^ *ENGINE$/ { on = 0 } on { sub(/^          /, ""); print }' "$wf"
[ "$out" = "$(cat "$here/scripts/check-commit-size.sh")" ] && rc=0 || rc=1
expect "workflow copy matches scripts/check-commit-size.sh (re-embed it)" 0

echo "commit-size tests: $passed passed, $failed failed"
[ "$failed" -eq 0 ]
