#!/usr/bin/env bash
# Tests for check-file-lengths.sh, its git hooks and the copy embedded in the required
# workflow. Each case runs in a throwaway git repo. Usage: scripts/check-file-lengths.test.sh
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 GIT_AUTHOR_NAME=t GIT_COMMITTER_NAME=t \
  GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_EMAIL=t@example.com
unset FILE_LENGTHS_EXCEPTION FILE_LENGTHS_DEFAULT_BRANCH
passed=0 failed=0 zero=0000000000000000000000000000000000000000

repo() { # fresh repo with the check and hooks committed on master
  cd "$work" && rm -rf "$1" "$1.git" && git init -q -b master "$1" && cd "$1"
  mkdir scripts .githooks && cp "$here/scripts/check-file-lengths.sh" scripts/
  cp "$here/.githooks/pre-commit" "$here/.githooks/pre-push" .githooks/
  git config core.hooksPath .githooks && save init
}
remote() { git init -q --bare "../$1.git" && git remote add origin "../$1.git" && git push -q -u origin master >/dev/null 2>&1; }
body() { awk -v n="$1" 'BEGIN { for (i = 1; i <= n; i++) print "x" }'; }
lines() { mkdir -p "$(dirname "$2")"; body "$1" > "$2"; }
cfg() { printf '%s\n' "$@" > .file-lengths; }
save() { git add -A && git commit -q --no-verify -m "${1:-c}"; }
run() { out=$("$@" 2>&1) && rc=0 || rc=$?; }
check() { run scripts/check-file-lengths.sh "$@"; }
expect() { # expect NAME RC [PATTERN that must appear in the output]
  if [ "$rc" = "$2" ] && { [ -z "${3:-}" ] || printf '%s\n' "$out" | grep -q -e "$3"; }; then
    passed=$((passed + 1))
  else
    failed=$((failed + 1)); echo "not ok: $1 (exit $rc, wanted $2${3:+, /$3/})"; printf '%s\n' "$out" | sed 's/^/    /'
  fi
}

# Never skip: no .file-lengths means org limits, nothing exempt, no baseline.
repo noconfig; lines 600 ok.rs; lines 601 big.ts; save
check; expect "missing config, tree" 1 'big.ts: 601 lines, limit 600'
check --ci HEAD~1; expect "missing config, ci" 1 'big.ts: 601'
lines 601 web.svelte; git add web.svelte
check --staged; expect "missing config, staged" 1 'web.svelte: 601'
git rm -q --cached web.svelte; rm web.svelte; git rm -q big.ts; save
lines 251 run.zsh; lines 601 new.mts; git add -A
check --staged; expect "org defaults cover zsh and mts" 1 'new.mts: 601'
printf '%s\n' "$out" | grep -q 'run.zsh: 251' || expect "zsh is limited to 250" x

# Deleting .file-lengths drops every baseline row and exemption with it.
repo deleted; lines 700 big.rs; cfg 'baseline big.rs 700'; save
check; expect "baseline row holds" 0
git rm -q .file-lengths; save
check --ci HEAD~1; expect "deleting the config does not skip" 1 'big.rs: 700 lines, limit 600'

# The org limits cannot be changed or loosened; new file types can be added.
repo orglimit; cfg 'limit 900 rs'; lines 700 a.rs; save
check; expect "org limit cannot be loosened" 1 'limit for .rs is set org-wide to 600'
cfg 'limit 100 .sh bash'; check; expect "org limit cannot be tightened" 1 'limit for .sh is set org-wide'
rm a.rs; cfg 'limit 100 md'; lines 101 doc.md; lines 100 ok.md
check; expect "repo limit for a new file type" 1 'doc.md: 101 lines, limit 100'
cfg 'limits 100 md'; check; expect "unknown directive fails" 1 'unknown or malformed line'

# Extension-less files whose shebang is sh, bash or zsh get the shell limit.
repo shebang; for s in '/bin/sh' '/usr/bin/env bash' '/usr/bin/env -S bash -eu' '/bin/zsh -f'; do
  rm -f tool; { echo "#!$s"; body 250; } > tool
  check; expect "shebang $s" 1 'tool: 251 lines, limit 250'
done
{ echo '#!/usr/bin/env python3'; body 400; } > tool; lines 300 Makefile
check; expect "non-shell shebang and Makefile are not limited" 0

# A final line without a newline counts, in every mode.
repo nonl; lines 600 a.rs; printf 'last' >> a.rs; git add a.rs
check --staged; expect "no trailing newline, staged" 1 'a.rs: 601'
check; expect "no trailing newline, tree" 1 'a.rs: 601'
save; check --range "$(git rev-parse HEAD~1)" HEAD; expect "no trailing newline, range" 1 'a.rs: 601'

# Pre-commit reads .file-lengths and file contents from the index.
repo index; lines 700 c.rs; git add c.rs; cfg 'baseline c.rs 700'
check --staged; expect "unstaged baseline row is ignored" 1 'c.rs: 700 lines, limit 600'
rm .file-lengths; git reset -q; lines 10 d.rs; git add d.rs; lines 700 d.rs
check --staged; expect "working copy of a staged file is ignored" 0
lines 700 d.rs; git add d.rs; lines 10 d.rs
check --staged; expect "staged content is measured" 1 'd.rs: 700'

# Exempt globs: other characters are literal, * is one segment, ** is any depth.
repo exempt; lines 700 'web/src/routes/[id]/+page.svelte'; lines 700 'web/src/(app)/x.ts'
lines 700 gen/a.rs; lines 700 gen/sub/b.rs; lines 700 aXb/c.rs
cfg 'exempt web/src/routes/[id]/**' 'exempt web/src/(app)/*.ts' 'exempt gen/*.rs' 'exempt a.b/*'
check; expect "SvelteKit paths are exempt" 1 'gen/sub/b.rs: 700'
printf '%s\n' "$out" | grep -q -e '\[id\]' -e '(app)' -e 'gen/a.rs' && expect "metacharacters are literal" x
printf '%s\n' "$out" | grep -q 'aXb/c.rs' || expect "a dot in a glob is literal" x
cfg 'exempt **/sub/**' 'exempt **/[id]/**' 'exempt **/(app)/*' 'exempt **/*.rs'; check
expect "** crosses folders" 0

# Only regular files are measured: symlinks and submodules are skipped.
repo links; lines 700 big.txt; ln -s big.txt link.rs; git add -A
git update-index --add --cacheinfo "160000,$(git rev-parse HEAD),sub.rs"
check --staged; expect "symlink and submodule, staged" 0
check; expect "symlink, tree" 0

# Baseline rows equal reality; pre-commit lowers and drops them as files shrink.
repo ratchet; lines 700 big.rs; lines 800 other.rs; lines 650 gone.rs
cfg '# grandfathered' 'baseline big.rs 700' 'baseline other.rs 800' 'baseline gone.rs 650'; save
lines 701 big.rs; check; expect "a baselined file may not grow" 1 'big.rs: 701 lines, baseline 700'
lines 650 big.rs; check; expect "tree mode wants the row lowered" 1 'lower its baseline row from 700 to 650'
git add big.rs; run git commit -q -m shrink; expect "pre-commit lowers a row" 0 'lowered the baseline row for big.rs to 650'
git show HEAD:.file-lengths | grep -q '^baseline big.rs 650$' || expect "lowered row is committed" x
grep -q '^# grandfathered$' .file-lengths || expect "comments survive the rewrite" x
lines 500 other.rs; git rm -q gone.rs; git add -A; run git commit -q -m split
expect "pre-commit drops rows" 0 'dropped the baseline row for other.rs'
[ "$(git show HEAD:.file-lengths)" = "$(printf '# grandfathered\nbaseline big.rs 650')" ] ||
  expect "rows for small and deleted files are gone" x
check; expect "ratchet ends clean" 0
lines 601 x.ts; git add x.ts; run git commit -q -m big; expect "pre-commit blocks a new big file" 1 'x.ts: 601'
git rm -q --cached x.ts; rm x.ts; cfg 'baseline nope.rs 900'; check; expect "row for a missing file" 1 'missing file nope.rs'

# CI: .file-lengths may only shrink, even when the base has no rows or no file.
repo ci; cfg '# no rows yet'; save
lines 900 big.rs; cfg 'baseline big.rs 900'; save
check --ci HEAD~1; expect "first baseline row is new" 1 'new baseline row big.rs 900'
FILE_LENGTHS_EXCEPTION=true check --ci HEAD~1; expect "exception label allows it" 0 'allowed by the file-lengths-exception label'
check --ci HEAD~2; expect "base without .file-lengths" 1 'new baseline row big.rs'
cfg 'baseline big.rs 901'; lines 901 big.rs; save
check --ci HEAD~1; expect "raised row" 1 'raised from 900 to 901'
cfg 'baseline big.rs 901' 'exempt gen/**'; save
check --ci HEAD~1; expect "new exempt line" 1 'new exempt line gen/\*\*'
cfg 'baseline big.rs 901' 'exempt gen/**' 'limit 300 md'; save
check --ci HEAD~1; expect "new repo limit" 1 'new limit 300 for .md'
cfg 'baseline big.rs 901' 'exempt gen/**' 'limit 400 md'; save
check --ci HEAD~1; expect "raised repo limit" 1 'limit for .md raised from 300 to 400'
cfg 'limit 200 md'; lines 600 big.rs; save
check --ci HEAD~1; expect "shrinking and removing lines passes" 0

# A missing or all-zero base falls back to the merge-base with the default branch.
repo firstpush; remote firstpush-remote; git checkout -q -b feature
lines 900 big.rs; cfg 'baseline big.rs 900'; save
check --ci "$zero"; expect "zero base uses the merge-base" 1 'new baseline row big.rs'
check --ci; expect "missing base uses the merge-base" 1 'new baseline row big.rs'

# Pre-push checks only what is pushed, and new branches against the default branch.
repo push; remote push-remote
lines 10 a.rs; save; lines 900 scratch.rs
run git push -q origin master; expect "untracked files do not block a push" 0; rm scratch.rs
lines 601 a.rs; save; run git push -q origin master; expect "a pushed big file blocks" 1 'a.rs: 601'
lines 10 a.rs; save; run git push -q origin master; expect "only the pushed tip is read" 0
git checkout -q -b topic; lines 601 b.ts; save; lines 10 c.ts; save
run git push -q origin topic; expect "new branch is checked since its merge-base" 1 'b.ts: 601'
git rm -q b.ts; save; run git push -q origin topic; expect "new branch passes once fixed" 0
check --range "$(git rev-parse HEAD)" HEAD; expect "empty range passes" 0
check --range 1111111111111111111111111111111111111111 HEAD; expect "unknown remote commit" 2 'git fetch'

# --print-baseline grandfathers every oversized, non-exempt file in one command.
repo adopt; lines 700 a.rs; lines 251 b.sh; lines 600 ok.rs; lines 700 gen/c.rs; lines 900 doc.md
cfg 'exempt gen/**'; check --print-baseline; expect "print-baseline rows" 0 '^baseline a.rs 700$'
[ "$(printf '%s\n' "$out" | sort)" = "$(printf 'baseline a.rs 700\nbaseline b.sh 251')" ] ||
  expect "print-baseline prints only oversized, non-exempt files" x
scripts/check-file-lengths.sh --print-baseline >> .file-lengths; check; expect "appending the rows makes the tree pass" 0
save; FILE_LENGTHS_EXCEPTION=true check --ci HEAD~1; expect "the label allows the appended rows" 0 'allowed by'
lines 701 a.rs; rm b.sh; check --print-baseline; expect "baselined files print at their current length" 0 '^baseline a.rs 701$'
printf '%s\n' "$out" | grep -q -e b.sh -e ok && expect "print-baseline ignores stale rows and prints no status" x
cfg 'limits 1 md'; check --print-baseline; expect "config errors fail print-baseline" 1 'unknown or malformed'
scripts/check-file-lengths.sh --print-baseline 2>/dev/null | grep -q . && expect "config errors print nothing to stdout" x
repo adoptclean; lines 10 a.rs; check --print-baseline; expect "nothing oversized prints nothing" 0
[ -z "$out" ] || expect "print-baseline output is empty" x

# The required workflow always enforces, on pull requests, from self-hosted runners.
wf="$here/.github/workflows/file-lengths.yml"
run grep -n -E 'inputs\.mode|\$MODE|report|workflow_call' "$wf"; expect "no report mode or workflow_call in the required workflow" 1
run grep -n -E '^  pull_request:$|runs-on: \[self-hosted, Linux, metal\]$|--ci "\$PR_BASE"' "$wf"
[ "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" = 3 ] && rc=0 || rc=1
expect "required workflow: pull_request trigger, self-hosted runner, --ci against the base" 0
run grep -n -E 'runs-on:.*(ubuntu|windows|macos)-' "$here"/.github/workflows/*.yml
expect "no workflow uses a GitHub-hosted runner" 1

# The required workflow embeds this exact script.
run awk '/<<.ENGINE.$/ { on = 1; next } /^ *ENGINE$/ { on = 0 } on { sub(/^          /, ""); print }' \
  "$here/.github/workflows/file-lengths.yml"
[ "$out" = "$(cat "$here/scripts/check-file-lengths.sh")" ] && rc=0 || rc=1
expect "workflow copy matches scripts/check-file-lengths.sh (re-embed it)" 0

echo "file-lengths tests: $passed passed, $failed failed"
[ "$failed" -eq 0 ]
