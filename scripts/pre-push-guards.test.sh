#!/usr/bin/env bash
# Tests for the org pre-push release guard (scripts/hooks/pre-push-guards.sh). Each case runs
# in a throwaway git repo, feeding the guard the lines git gives a pre-push hook.
# Usage: scripts/pre-push-guards.test.sh
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
guard="$here/scripts/hooks/pre-push-guards.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 GIT_AUTHOR_NAME=t GIT_COMMITTER_NAME=t \
  GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_EMAIL=t@example.com
passed=0 failed=0 zero=0000000000000000000000000000000000000000 day=0

repo() { # fresh repo with one commit on master, mirrored as origin/master
  cd "$work" && rm -rf "$1" && git init -q -b master "$1" && cd "$1"
  day=0; commits 1; git update-ref refs/remotes/origin/master HEAD
}
commits() { # commits N: N empty commits, each a day after the last
  local i
  for ((i = 0; i < $1; i++)); do
    day=$((day + 1))
    GIT_COMMITTER_DATE="@$((1767225600 + day * 86400)) +0000" git commit -q --allow-empty -m "c$day"
  done
}
cfg() { local f=$1; shift; mkdir -p "$(dirname "$f")"; printf '%s\n' "$@" > "$f"; git add -A; commits 1; }
proj() { mkdir -p "projects/$1" && echo x > "projects/$1/README" && git add -A && commits 1; }
mark() { git update-ref "refs/remotes/origin/$1" HEAD; } # mark REF: origin/REF is at HEAD
push() { # push REF...: run the guard as git would for pushing HEAD to each REF
  local r
  out=$(for r in "$@"; do echo "refs/heads/x $(git rev-parse HEAD) refs/heads/$r $zero"; done |
    bash "$guard" origin url 2>&1) && rc=0 || rc=$?
}
expect() { # expect NAME RC [PATTERN that must appear in the output]
  if [ "$rc" = "$2" ] && { [ -z "${3:-}" ] || grep -q -e "$3" <<<"$out"; }; then
    passed=$((passed + 1))
  else
    failed=$((failed + 1)); echo "not ok: $1 (exit $rc, wanted $2${3:+, /$3/})"; printf '%s\n' "$out" | sed 's/^/    /'
  fi
}
quiet() { [ -z "$out" ] || { rc=output; }; }

# A single-project repository: swarm/run counts commits since origin/staging (its head included).
repo single; mark swarm/run; mark staging; commits 78
push swarm/run; quiet; expect "79 unreleased commits pass silently" 0
commits 1; push swarm/run
expect "80 warn" 0 '^release-guard: 80 unreleased commits on swarm/run: cut a staging release now; GitHub refuses rebase-merge past ~100$'
expect "the warning names the release ref" 0 '^release-guard: counted since origin/staging at '
commits 70; push swarm/run; expect "150 refuse" 1 '^release-guard: push refused at 150 or more; release swarm/run to staging first$'
mark feature/swarm/run; push feature/swarm/run; quiet
expect "<x>/swarm/run without a projects/<x>/ folder is not counted" 0
push feature main staging; quiet; expect "other branches are not counted" 0
out=$(echo "(delete) $zero refs/heads/swarm/run $(git rev-parse HEAD)" | bash "$guard" origin url 2>&1) && rc=0 || rc=$?
quiet; expect "deleting swarm/run is not counted" 0
git update-ref -d refs/remotes/origin/staging; push swarm/run; expect "no staging: counts since the default branch" 1 'counted since origin/master at '
git update-ref -d refs/remotes/origin/swarm/run; push swarm/run; quiet; expect "no origin/swarm/run: not counted" 0

# .release-guard may lower the limits, never raise them.
repo lower; cfg .release-guard 'warn 2' 'refuse 300' '# note'; mark swarm/run; mark staging
push swarm/run; quiet; expect "1 commit under warn 2" 0
commits 1; push swarm/run; expect "warn lowered" 0 '2 unreleased commits on swarm/run'
cfg .release-guard 'warn 2' 'refuse 3' 'bogus 1' 'warn x'; push swarm/run
expect "refuse lowered, bad lines ignored" 1 'push refused at 3 or more'
grep -q 'ignoring .release-guard line: bogus 1' <<<"$out" || expect "bad lines are named" x

# A project's <p>/swarm/run counts since origin/<p>/staging; projects/<p>/.release-guard lowers it.
repo mono; proj movopop; mark movopop/swarm/run; mark movopop/staging; mark swarm/run; commits 79; mark staging
push movopop/swarm/run; expect "<p>/swarm/run counts since <p>/staging" 0 '80 unreleased commits on movopop/swarm/run'
expect "and names it" 0 'counted since origin/movopop/staging at '
push swarm/run; quiet; expect "swarm/run still counts since staging" 0
commits 70; push movopop/swarm/run; expect "<p>/swarm/run refuses at 150" 1 'release movopop/swarm/run to movopop/staging first$'
git update-ref -d refs/remotes/origin/movopop/staging; mark staging; push movopop/swarm/run
expect "no <p>/staging: counts since the default branch, not staging" 1 'counted since origin/master at '
repo pcfg; proj movopop; proj other; mark movopop/swarm/run; mark movopop/staging; mark swarm/run; mark staging
mark other/swarm/run; mark other/staging; cfg projects/movopop/.release-guard 'warn 2' 'refuse 2'
push movopop/swarm/run; expect "projects/<p>/.release-guard lowers its project" 1 'push refused at 2 or more; release movopop/swarm/run'
push swarm/run other/swarm/run; quiet; expect "and no other branch" 0
cfg .release-guard 'warn 3' 'refuse 3'; push other/swarm/run; expect "the root .release-guard lowers every project" 1 'refused at 3 or more; release other/swarm/run'
mark a/b/swarm/run; mark a/b/staging; push a/b/swarm/run new/swarm/run; quiet
expect "nested or untracked <p>/swarm/run is not counted" 0

# A sync merge of the default branch into staging is not a release: count from the newest
# non-merge commit on staging's first-parent chain (for a project, touching projects/<p>/).
repo sync; proj movopop; mark movopop/swarm/run; mark swarm/run; mark staging; mark movopop/staging
git checkout -q -b side; commits 1; git checkout -q master; commits 78; git checkout -q -b st origin/staging
commits 1; day=$((day + 1)); GIT_COMMITTER_DATE="@$((1767225600 + day * 86400)) +0000" git merge -q --no-ff -m sync side
mark movopop/staging; mark staging; git checkout -q master; commits 1; push movopop/swarm/run
expect "a sync merge on <p>/staging is not a release" 0 '80 unreleased commits on movopop/swarm/run'
expect "nor are commits outside projects/<p>/" 0 'counted since origin/movopop/staging at 2026-01-03T'
push swarm/run; quiet; expect "staging counts from its newest non-merge commit" 0

# The org-hooks workflow runs on the default branch, staging and <p>/staging only. It accepts
# this guard, and the previous copy only in a repository without projects/.
wf="$here/.github/workflows/org-hooks.yml"
step() { # step NAME: the run block of the workflow step named NAME
  awk -v n="$1" 'index($0, "- name: " n) { f = 1 } f && /^      - / && !index($0, n) { exit }
    f && /^        run: \|$/ { on = 1; next } on { sub(/^          /, ""); print }' "$wf"
}
step 'Only pull requests into' > "$work/gate.sh"; step 'Check the org pre-push guards' > "$work/org-hooks.sh"
for b in main staging movopop/staging a/b/staging feature main-staging; do
  : > "$work/gate.out"; BASE_REF=$b DEFAULT_BRANCH=main GITHUB_OUTPUT="$work/gate.out" bash "$work/gate.sh" >/dev/null
  printf '%s=%s ' "$b" "$(cat "$work/gate.out")"
done > "$work/gates"
[ "$(cat "$work/gates")" = "main=run=true staging=run=true movopop/staging=run=true a/b/staging= feature= main-staging= " ] && rc=0 || rc=1
out=$(cat "$work/gates"); expect "org-hooks runs into the default branch, staging and one-segment <p>/staging" 0
blob() { sed -n "s/^ *$1: *//p" "$wf"; }
previous="$here/scripts/fixtures/pre-push-guards.previous.sh"
[ "$(git hash-object "$previous")" = "$(blob GUARD_BLOB_PREVIOUS)" ] && rc=0 || rc=1; out=""
expect "the fixture is the previous guard org-hooks accepts" 0
hooks() { # hooks GUARD-FILE [PROJECT]: run the workflow step on a repo shipping it
  cd "$work" && rm -rf hooks && git init -q hooks && cd hooks && mkdir -p .githooks/org
  cp "$1" .githooks/org/pre-push-guards.sh && cp "$here/.githooks/pre-push" .githooks/
  if [ -n "${2:-}" ]; then mkdir -p "projects/$2" && echo x > "projects/$2/README"; fi; git add -A && commits 1
  out=$(GUARD_BLOB=$(blob GUARD_BLOB) GUARD_BLOB_PREVIOUS=$(blob GUARD_BLOB_PREVIOUS) GITHUB_STEP_SUMMARY=/dev/null \
    bash "$work/org-hooks.sh" 2>&1) && rc=0 || rc=$?
}
hooks "$guard"; expect "org-hooks accepts this guard" 0 'org-hooks: ok'
hooks "$previous"; expect "org-hooks accepts the previous guard in a single-project repository" 0 'org-hooks: ok'
hooks "$previous" movopop; expect "but not in a repository with projects/" 1 'differs from the org-checks copy'
hooks "$guard" movopop; expect "where this guard passes" 0 'org-hooks: ok'
{ cat "$guard"; echo '# edited'; } > "$work/edited.sh"
hooks "$work/edited.sh"; expect "org-hooks refuses an edited guard" 1 'differs from the org-checks copy'

echo "pre-push-guards tests: $passed passed, $failed failed"
[ "$failed" -eq 0 ]
