#!/usr/bin/env bash
# Tests for check-path-collisions.sh and the copy embedded in its workflow. Each case runs in a
# throwaway git repo on this (case-sensitive) filesystem. Usage: scripts/check-path-collisions.test.sh
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 GIT_AUTHOR_NAME=t GIT_COMMITTER_NAME=t \
  GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_EMAIL=t@example.com
passed=0 failed=0
nfc=$(printf 'caf\303\251') nfd=$(printf 'cafe\314\201') # é precomposed, and e plus a combining acute

repo() { cd "$work" && rm -rf "$1" && git init -q -b master "$1" && cd "$1"; }
touch_all() { local f; for f in "$@"; do mkdir -p "$(dirname "$f")"; echo x > "$f"; done; }
save() { git add -A && git commit -q --no-verify -m c; }
run() { out=$("$@" 2>&1) && rc=0 || rc=$?; }
check() { run "$here/scripts/check-path-collisions.sh" "$@"; }
expect() { # expect NAME RC [PATTERN that must appear in the output]
  if [ "$rc" = "$2" ] && { [ -z "${3:-}" ] || printf '%s\n' "$out" | grep -q -e "$3"; }; then
    passed=$((passed + 1))
  else
    failed=$((failed + 1)); echo "not ok: $1 (exit $rc, wanted $2${3:+, /$3/})"; printf '%s\n' "$out" | sed 's/^/    /'
  fi
}

# A clean tree passes, in the index and at a commit, and from a subdirectory.
repo clean; touch_all README.md src/main.rs src/lib.rs docs/Guide.md "docs/$nfc.md"; save
check; expect "clean index" 0 'ok, no tracked paths collide'
check HEAD; expect "clean commit" 0 'ok'
(cd src && "$here/scripts/check-path-collisions.sh" >/dev/null) && rc=0 || rc=$?; expect "clean, run from a subdirectory" 0

# Two directories differing only in case collide, even with different files inside.
repo dirs; touch_all Foo/x foo/y; save
check; expect "Foo/x and foo/y" 1 '^  Foo/  foo/$'
check HEAD; expect "Foo/x and foo/y at a commit" 1 '^  Foo/  foo/$'

# Only the shallowest collision is listed: Foo/x and foo/x are not listed again.
repo nested; touch_all Foo/x foo/x foo/X; save
check; expect "nested: directories listed" 1 '^  Foo/  foo/$'
[ "$(printf '%s\n' "$out" | grep -c '^  ')" = 1 ] && rc=0 || rc=1; expect "nested: only the shallowest group" 0

# Files in one directory, and a file colliding with a directory.
repo files; touch_all docs/README.md docs/readme.md; save
check; expect "files differing in case" 1 '^  docs/README.md  docs/readme.md$'
repo filedir; touch_all A a/b; save
check; expect "file A and directory a/" 1 '^  A  a/$'

# NFC and NFD spellings of the same name collide, as files and as directories.
repo unicode; touch_all "$nfc.txt" "$nfd.txt"; save
check; expect "NFC and NFD file names" 1 "^  .*$nfc.txt"
printf '%s\n' "$out" | grep -q -F "$nfd.txt" && rc=0 || rc=1; expect "NFC and NFD: both names listed" 0
repo unidir; touch_all "$nfc/a" "$nfd/b"; save
check HEAD; expect "NFC and NFD directory names" 1 "/  .*/\$"
repo unicase; touch_all "$nfc" "$(printf 'CAF\303\211')"; save
check; expect "case and Unicode together" 1 "$nfc"

# Only tracked paths count; the index is read, not the working tree.
repo untracked; touch_all a.txt; save; touch_all A.txt
check; expect "untracked file ignored" 0
git add A.txt; check; expect "staged file counted" 1 '^  A.txt  a.txt$'
check HEAD; expect "the commit is read, not the index" 0

# A head that is fine alone collides with the base in the merge commit, which the workflow reads.
repo merge; touch_all README.md; save; git checkout -q -b topic; touch_all Notes.md; save
git checkout -q master; touch_all notes.md; save; git merge -q --no-edit topic
check topic; expect "head alone passes" 0
check HEAD; expect "merge commit with the base fails" 1 '^  Notes.md  notes.md$'

# Errors exit 2.
check no-such-ref; expect "an unknown ref fails to run" 2 'not a commit or tree'
check a b; expect "too many arguments" 2 usage
run env -C "$work" "$here/scripts/check-path-collisions.sh"; expect "outside a repository" 2 'not in a git repository'

# The workflow embeds this exact script, checks the merge commit, and runs on the org's runner.
wf="$here/.github/workflows/path-collisions.yml"
run awk '/<<.ENGINE.$/ { on = 1; next } /^ *ENGINE$/ { on = 0 } on { sub(/^          /, ""); print }' "$wf"
[ "$out" = "$(cat "$here/scripts/check-path-collisions.sh")" ] && rc=0 || rc=1
expect "workflow copy matches scripts/check-path-collisions.sh (re-embed it)" 0
# shellcheck disable=SC2016 # literal expressions in the workflow
run grep -c -E '^  pull_request:$|PR_MERGE: \$\{\{ github\.sha \}\}$|"\$engine" refs/check/merge|"\+\$PR_MERGE:refs/check/merge"' "$wf"
expect "workflow: pull_request trigger, checks the fetched merge commit" 0 '^4$'
run grep -h 'runs-on:' "$wf" "$here/.github/workflows/file-lengths.yml"
[ "$(printf '%s\n' "$out" | sort -u | wc -l | tr -d ' ')" = 1 ] && rc=0 || rc=1
expect "workflow: same runner as file-lengths" 0

echo "path-collisions tests: $passed passed, $failed failed"
[ "$failed" -eq 0 ]
