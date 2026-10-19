#!/usr/bin/env bash
# Tests for check-commit-size.sh and the copy embedded in the required workflow. Each case
# runs in a throwaway git repo. Usage: scripts/check-commit-size.test.sh
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 GIT_AUTHOR_NAME=t GIT_COMMITTER_NAME=t \
  GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_EMAIL=t@example.com
unset COMMIT_SIZE_EXCEPTION COMMIT_SIZE_DEFAULT_BRANCH COMMIT_SIZE_BASE_REF COMMIT_SIZE_HEAD_REF \
  COMMIT_SIZE_HEAD_REPO COMMIT_SIZE_REPO
passed=0 failed=0 zero=0000000000000000000000000000000000000000

repo() { # fresh repo with one small commit on master, work continuing on branch pr
  cd "$work" && rm -rf "$1" && git init -q -b master "$1" && cd "$1"
  echo init > README && save init && git checkout -q -b pr
}
body() { awk -v n="$1" -v t="${2:-x}" 'BEGIN { for (i = 1; i <= n; i++) print t i }'; }
lines() { mkdir -p "$(dirname "$2")"; body "$1" "${3:-x}" > "$2"; }
cfg() { printf '%s\n' "$@" > .commit-size; }
save() { git add -A && git commit -q -m "${1:-c}"; }
run() { out=$("$@" 2>&1) && rc=0 || rc=$?; }
check() { run "$here/scripts/check-commit-size.sh" "$@"; }
expect() { # expect NAME RC [PATTERN that must appear in the output]
  if [ "$rc" = "$2" ] && { [ -z "${3:-}" ] || grep -q -e "$3" <<<"$out"; }; then
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

# Lockfiles beside their manifest never count; other files in the same commit still do.
repo locks; mkdir web && touch Cargo.toml web/Cargo.toml web/package.json web/pyproject.toml; for f in Cargo.lock bun.lock package-lock.json pnpm-lock.yaml yarn.lock uv.lock; do
  lines 3000 "web/$f"; done; lines 3000 Cargo.lock; save "chore(deps): bump"
check master; expect "lockfile-only commit passes" 0 '0 changed lines (+21000 exempt)'
lines 3001 Cargo.lock; lines 1001 src.rs; save "feat: code with a lockfile"
check master; expect "lockfiles do not hide code" 1 'code with a lockfile: 1001 changed lines (+'
lines 1001 Cargo.lock.rs; save; check HEAD~1; expect "only the exact lockfile names" 1 '1001 changed lines'
lines 1001 src/gen/Cargo.lock; save "feat: hidden lock"; check HEAD~1
expect "a lockfile without its manifest counts" 1 'hidden lock: 1001 changed lines'
git rm -q -r src Cargo.lock.rs; save; git rm -q web/yarn.lock; save "chore: drop yarn"; check HEAD~1
expect "deleting a lockfile beside its manifest is exempt" 0 '0 changed lines (+3000 exempt): chore: drop yarn'
cfg 'exempt gen/**'; lines 1500 gen/x.rs; save; mkdir lib && git mv gen/x.rs lib/Cargo.lock; save "feat: move to lock"
check HEAD~1; expect "renamed out of an exempt path into a bare lockfile counts in full" 1 'move to lock: 1500 changed lines'

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
check --ci base HEAD; expect "new exempt line fails" 1 '^\[FAIL\] .commit-size: new exempt line vendor/\*\*$'
COMMIT_SIZE_EXCEPTION=true check --ci base HEAD; expect "the label allows a new exempt line" 0 'allowed by the commit-size-exception label: new exempt line'
cfg; save "chore: drop exemptions"; check --ci HEAD~1 HEAD; expect "removing lines passes" 0

# The label allows oversized commits too.
repo label; lines 1500 a.rs; save big
COMMIT_SIZE_EXCEPTION=true check --ci master HEAD; expect "label allows an oversized commit" 0 'allowed by the commit-size-exception label: [0-9a-f]* big'
COMMIT_SIZE_EXCEPTION=false check --ci master HEAD; expect "only true counts" 1 'commit-size-exception label on the pull request, then closing and reopening'

# Each projects/<p>/.commit-size exempts paths relative to its folder only, and may only shrink.
pcfg() { local d=$1; shift; mkdir -p "projects/$d"; printf '%s\n' "$@" > "projects/$d/.commit-size"; }
repo mono; pcfg a 'exempt gen/**'; save cfg; git branch -q base; lines 3000 projects/a/gen/x.ts; save "chore: gen a"
check base; expect "a folder's exempt line applies in its folder" 0 '0 changed lines (+3000 exempt)'
lines 1001 projects/b/gen/x.ts; save "chore: gen b"; check HEAD~1; expect "and nowhere else" 1 'gen b: 1001 changed lines'
git reset -q --hard HEAD~1; pcfg a/deep 'exempt **'; lines 1001 projects/a/deep/x.ts; mkdir -p other && echo 'exempt **' > other/.commit-size
save "feat: deep"; check HEAD~1; expect "only projects/<p>/.commit-size is read" 1 'deep: 1003 changed lines'
git reset -q --hard HEAD~1; pcfg b 'exempt gen/**'; save "chore: b cfg"
check --ci base HEAD; expect "a new folder file may only shrink" 1 '^\[FAIL\] projects/b/.commit-size: new exempt line gen/\*\*$'
COMMIT_SIZE_EXCEPTION=true check --ci base HEAD; expect "the label allows a folder line" 0 'label: new exempt line gen/\*\*$'
pcfg b 'exempts x'; save; check HEAD~1; expect "a malformed folder line names its file" 1 ':projects/b/.commit-size:1: unknown or malformed line'
git rm -q -r projects/b; cfg 'exempt projects/a/gen/**'; pcfg a; save "chore: move to root"
check --ci HEAD~1 HEAD; expect "moving a line to the root is new there" 1 '^\[FAIL\] .commit-size: new exempt line projects/a/gen/\*\*$'

repo dotdir; pcfg .hid 'exempt **'; lines 1001 projects/.hid/x.ts; save "feat: hidden"
check master; expect "a dot-folder config is not read" 1 'hidden: 1002 changed lines'

# Merges count only what they add beyond an automatic merge; a clean one counts nothing.
repo merges; git checkout -q master; lines 900 m1.rs; save; lines 900 m2.rs; save; git checkout -q pr
lines 10 p.rs; save; git merge -q --no-edit master; check master~2 HEAD
expect "clean merge counts nothing" 0 '4 commit(s) checked'
git reset -q --hard HEAD~1; git merge -q --no-commit master >/dev/null; lines 1001 evil.rs; save "merge evil"
check master~2 HEAD; expect "evil merge measured" 1 'merge evil: 1001 changed lines'
git checkout -q -b o1 master~2; lines 3 o1.rs; save; git checkout -q -b o2 master~2; lines 3 o2.rs; save
git checkout -q -b o3 master~2; lines 3 o3.rs; save; git merge -q --no-edit o1 o2 >/dev/null; check master~2 HEAD
expect "an octopus merge fails plainly" 1 'octopus merges are not supported'
git checkout -q -b back master; git merge -q --no-edit -s ours pr; check pr HEAD
expect "merge with a parent's tree counts nothing" 0 '0 changed lines'

# Renames count only their edits, unless they leave an exempt path (fix 1).
repo renames; lines 2000 a.rs; git add -A && git commit -q -m add; git mv a.rs b.rs; save "refactor: move"
check HEAD~1; expect "a pure rename is 0 lines" 0 '0 changed lines: refactor: move'
repo unlock; lines 5000 src/Cargo.lock; cfg 'exempt gen/**'; lines 3000 gen/x.rs; save; git branch -q base
git mv src/Cargo.lock src/main.rs; git mv gen/x.rs lib.rs; save "feat: launder"
check base; expect "rename out of an exempt path counts the whole file" 1 'launder: 8000 changed lines'
git reset -q --hard base; git mv src/Cargo.lock gen/Cargo.lock; git mv gen/x.rs gen/y.rs; save "chore: move generated"
check base; expect "rename within exempt paths stays exempt" 0 '0 changed lines: chore: move generated'

# Binaries (fix 2): .gitattributes and NUL bytes cannot hide text; real binaries count by size
# unless they are a listed format.
repo binary; printf '* -diff\n' > .gitattributes; lines 1001 a.rs; save "feat: hidden"
check master; expect ".gitattributes -diff cannot hide lines" 1 'hidden: 1002 changed lines'
repo nul; { printf '\0'; body 1001 x; } > a.rs; save "feat: nul"
check master; expect "a NUL byte cannot hide lines" 1 'nul: 1001 changed lines'
head -c 300000 /dev/urandom > blob.bin; save "chore: blob"; check HEAD~1
expect "a real unlisted binary counts a line per 40 bytes" 1 'blob: 7500 changed lines'
git mv blob.bin moved.bin; save "chore: move blob"; check HEAD~1
expect "an unchanged binary rename counts 0" 0 '0 changed lines: chore: move blob'
git mv moved.bin again.bin; head -c 10 /dev/urandom >> again.bin; save "chore: move and edit"; check HEAD~1
expect "a binary renamed with edits counts" 1 'move and edit: 7501 changed lines'
{ printf 'PK\0'; head -c 300000 /dev/urandom; } > bundle.zip; save "chore: zip"; check HEAD~1
expect "zip is a listed format" 0 '(+7501 exempt): chore: zip'
{ printf '\211PNG\0'; head -c 300000 /dev/urandom; } > logo.png; save "chore: logo"; check HEAD~1
expect "a real binary of a listed format is exempt" 0 '0 changed lines (+7501 exempt): chore: logo'
lines 1001 fake.png; save "feat: fake png"; check HEAD~1
expect "a listed extension with text content counts" 1 'fake png: 1001 changed lines'

# Paths with a newline or tab fail (fix 3): they could steal a lockfile's exemption.
repo newline; lines 5 "$(printf 'a\nCargo.lock')"; lines 1001 b.rs; save "feat: newline"
check master; expect "a path with a newline fails" 1 'newline: a changed path contains a newline'
repo tab; lines 5 "$(printf 'a\tb.rs')"; save "feat: tab"
check master; expect "a path with a tab fails" 1 'tab: 1 changed path(s) contain a tab'

# Promotions into the default branch skip commits already on origin/staging (fix 5).
repo promo; lines 1001 a.rs; save "feat: big on staging"; git update-ref refs/remotes/origin/staging HEAD
lines 10 b.rs; save "feat: new"
export COMMIT_SIZE_DEFAULT_BRANCH=master COMMIT_SIZE_REPO=o/r
COMMIT_SIZE_BASE_REF=master COMMIT_SIZE_HEAD_REF=staging COMMIT_SIZE_HEAD_REPO=o/r check --ci master HEAD
expect "promotion skips commits on staging" 0 '1 commit(s) checked'
COMMIT_SIZE_BASE_REF=master COMMIT_SIZE_HEAD_REF=feature COMMIT_SIZE_HEAD_REPO=o/r check --ci master HEAD
expect "only a head branch named staging skips" 1 'big on staging: 1001'
COMMIT_SIZE_BASE_REF=master COMMIT_SIZE_HEAD_REF=staging COMMIT_SIZE_HEAD_REPO=fork/r check --ci master HEAD
expect "a fork's staging branch does not skip" 1 'big on staging: 1001'
COMMIT_SIZE_BASE_REF=staging COMMIT_SIZE_HEAD_REF=staging COMMIT_SIZE_HEAD_REPO=o/r check --ci master HEAD
expect "only promotions into the default branch skip" 1 'big on staging: 1001'
# A project's <p>/staging promotes like staging; only one folder segment, only into the default branch.
repo evil; lines 3000 a.rs; save "feat: big on evil staging"; git update-ref refs/remotes/origin/evil/staging HEAD
COMMIT_SIZE_BASE_REF=master COMMIT_SIZE_HEAD_REF=evil/staging COMMIT_SIZE_HEAD_REPO=o/r check --ci master HEAD
expect "<x>/staging without projects/<x>/ at the base is checked in full" 1 'big on evil staging: 3000 changed lines'
grep -q 'skipped' <<<"$out" && expect "nothing is skipped for evil/staging" x
lines 1 projects/evil/README; save; check --ci master HEAD
COMMIT_SIZE_BASE_REF=master COMMIT_SIZE_HEAD_REF=evil/staging COMMIT_SIZE_HEAD_REPO=o/r check --ci master HEAD
expect "a projects/<x>/ folder only on the head does not count" 1 '2 commit(s) checked'
repo ppromo; lines 1 projects/movopop/README; save; git branch -f -q master HEAD
lines 1001 a.rs; save "feat: big on movopop staging"; git update-ref refs/remotes/origin/movopop/staging HEAD
git update-ref refs/remotes/origin/a/b/staging HEAD; lines 10 b.rs; save "feat: new"
COMMIT_SIZE_BASE_REF=master COMMIT_SIZE_HEAD_REF=movopop/staging COMMIT_SIZE_HEAD_REPO=o/r check --ci master HEAD
expect "promotion from <p>/staging skips its commits" 0 'commits already on origin/movopop/staging are skipped'
for h in a/b/staging movopop/stagingx movopop-staging; do
  COMMIT_SIZE_BASE_REF=master COMMIT_SIZE_HEAD_REF=$h COMMIT_SIZE_HEAD_REPO=o/r check --ci master HEAD
  expect "head $h does not skip" 1 'big on movopop staging: 1001'
done
COMMIT_SIZE_BASE_REF=master COMMIT_SIZE_HEAD_REF=other/staging COMMIT_SIZE_HEAD_REPO=o/r check --ci master HEAD
expect "a <p>/staging the clone lacks skips nothing" 1 'big on movopop staging: 1001'
COMMIT_SIZE_BASE_REF=master COMMIT_SIZE_HEAD_REF=movopop/staging COMMIT_SIZE_HEAD_REPO=fork/r check --ci master HEAD
expect "a fork's <p>/staging does not skip" 1 'big on movopop staging: 1001'
COMMIT_SIZE_BASE_REF=movopop/staging COMMIT_SIZE_HEAD_REF=movopop/staging COMMIT_SIZE_HEAD_REPO=o/r check --ci master HEAD
expect "<p>/staging into itself does not skip" 1 'big on movopop staging: 1001'
unset COMMIT_SIZE_DEFAULT_BRANCH COMMIT_SIZE_REPO

# BASE: zero falls back to the merge-base with the default branch; a root commit is measured.
repo fallback; lines 1001 a.rs; save big; git update-ref refs/remotes/origin/master master
check "$zero" HEAD; expect "zero base uses the merge-base" 1 '1 commit(s) checked'
COMMIT_SIZE_DEFAULT_BRANCH=master check "$zero"; expect "default branch override" 1 'big: 1001'
cd "$work" && rm -rf root && git init -q -b master root && cd root && lines 1001 a.rs && save root
check; expect "root commit, no base" 1 'root: 1001 changed lines'
check nosuchcommit; expect "unknown base fails" 2 'not in this clone'
check --bogus; expect "unknown flag fails" 2 'usage'

# The runner every required check uses: GitHub-hosted for public repositories, the light
# self-hosted pool on metal-02 for private ones.
hybrid=$(cat <<'RUNNER'
    runs-on: ${{ fromJSON(github.event.repository.visibility == 'public' && '["ubuntu-latest"]' || '["self-hosted", "Linux", "light"]') }}
RUNNER
)

# The required workflow always enforces, on pull requests, on that runner.
wf="$here/.github/workflows/commit-size.yml"
# shellcheck disable=SC2016 # literal $PR_BASE and $PR_HEAD in the workflow
run grep -n -E '^  pull_request:$|^    types: \[opened, synchronize, reopened\]$|"\$clone" "\$RUNNER_TEMP/pr" "\$GITHUB_SERVER_URL/\$GITHUB_REPOSITORY" "\$\{refs\[@\]\}"$|COMMIT_SIZE_HEAD_REF: .*head\.ref }}$|COMMIT_SIZE_HEAD_REPO: .*head\.repo\.full_name }}$|COMMIT_SIZE_REPO: .*github\.repository }}$|timeout-minutes: 15$|--ci "\$PR_BASE" "\$PR_HEAD"' "$wf"
[ "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" = 8 ] && rc=0 || rc=1
expect "required workflow: pull_request trigger, full fresh clone, --ci BASE HEAD" 0
run grep -n -E 'runs-on:' "$wf"; [ -n "$out" ] && [ "$out" = "$(grep -n -x -F "$hybrid" "$wf")" ] && rc=0 || rc=1
expect "one runner: public repositories GitHub-hosted, private ones self-hosted" 0
run grep -n -E 'filter:' "$wf"; expect "no partial clone, which would need the job token" 1

# shellcheck disable=SC2016 # literal $HEAD_REF in the workflow
run grep -c -F -e '[[ $HEAD_REF =~ ^([^/]+/)?staging$ ]]' -e 'refs+=("+refs/heads/$HEAD_REF:refs/remotes/origin/$HEAD_REF")' "$wf"
[ "$out" = 2 ] && rc=0 || rc=1; expect "a promotion from staging or <p>/staging fetches its head branch" 0

# commit-count counts only pull requests into the default branch, staging and one-segment <p>/staging.
cc="$here/.github/workflows/commit-count.yml"
awk '/^        run: \|$/ { on = 1; next } on { sub(/^          /, ""); print }' "$cc" > "$work/count.sh"
for b in main staging movopop/staging a/b/staging feature/x; do
  run env COMMITS=200 EXCEPTION=false BASE_REF=$b DEFAULT_BRANCH=main GITHUB_STEP_SUMMARY=/dev/null bash "$work/count.sh"
  printf '%s=%s ' "$b" "$rc"
done > "$work/counts"
out=$(cat "$work/counts"); [ "$out" = "main=1 staging=1 movopop/staging=1 a/b/staging=0 feature/x=0 " ] && rc=0 || rc=1
expect "commit-count gates on the base branch" 0

# The required workflow embeds this exact script.
run awk '/<<.ENGINE.$/ { on = 1; next } /^ *ENGINE$/ { on = 0 } on { sub(/^          /, ""); print }' "$wf"
[ "$out" = "$(cat "$here/scripts/check-commit-size.sh")" ] && rc=0 || rc=1
expect "workflow copy matches scripts/check-commit-size.sh (re-embed it)" 0

echo "commit-size tests: $passed passed, $failed failed"
[ "$failed" -eq 0 ]
