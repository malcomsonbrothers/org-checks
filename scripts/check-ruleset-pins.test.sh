#!/usr/bin/env bash
# Tests for check-ruleset-pins.sh. Each case runs in a throwaway git repo with a manifest and,
# where it matters, a fixture ruleset JSON. Usage: scripts/check-ruleset-pins.test.sh
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 GIT_AUTHOR_NAME=t GIT_COMMITTER_NAME=t \
  GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_EMAIL=t@example.com
unset GITHUB_STEP_SUMMARY
passed=0 failed=0 a=.github/workflows/a.yml b=.github/workflows/b.yml

repo() { # fresh repo with two workflows on master
  cd "$work" && rm -rf "$1" && git init -q -b master "$1" && cd "$1"
  mkdir -p .github/workflows && echo a1 > "$a" && echo b1 > "$b" && save init
}
save() { git add -A && git commit -q -m "${1:-c}"; }
pin() { printf '%s %s\n' "$@" >> "$work/pins.txt"; }
pins() { printf '# comment\n\n' > "$work/pins.txt"; while [ $# -gt 0 ]; do pin "$1" "$2"; shift 2; done; }
ruleset() { # ruleset PATH SHA ...: a fixture of GET /orgs/{org}/rulesets/{id}, plus another repo's pin
  local rows='{"repository_id": 99, "path": ".github/workflows/x.yml", "sha": "0000000000000000000000000000000000000000"}'
  while [ $# -gt 0 ]; do rows="$rows, {\"repository_id\": 1407359561, \"path\": \"$1\", \"sha\": \"$2\"}"; shift 2; done
  printf '{"rules": [{"type": "pull_request"}, {"type": "workflows", "parameters": {"workflows": [%s]}}]}\n' "$rows" > "$work/ruleset.json"
}
run() { out=$("$@" 2>&1) && rc=0 || rc=$?; }
check() { run "$here/scripts/check-ruleset-pins.sh" --manifest "$work/pins.txt" "$@"; }
expect() { # expect NAME RC [PATTERN that must appear in the output]
  if [ "$rc" = "$2" ] && { [ -z "${3:-}" ] || grep -q -e "$3" <<<"$out"; }; then
    passed=$((passed + 1))
  else
    failed=$((failed + 1)); echo "not ok: $1 (exit $rc, wanted $2${3:+, /$3/})"; printf '%s\n' "$out" | sed 's/^/    /'
  fi
}

# All pins current: pass, even when master has moved on in other files.
repo current; p1=$(git rev-parse HEAD); echo other > README; save "docs: other"
pins "$a" "$p1" "$b" "$p1"; check; expect "pins of unchanged files pass" 0 'ruleset-pins: ok (2 pins'
ruleset "$a" "$p1" "$b" "$p1"; check --ruleset "$work/ruleset.json"
expect "a matching ruleset passes, other repositories' pins ignored" 0 'manifest matches the live ruleset'

# A pinned file changed on master: fail naming the path and the commit to bump to.
echo a2 > "$a"; save "fix(a): change"; p2=$(git rev-parse HEAD); echo more > README; save "docs: more"
check; expect "a changed pinned file fails" 1 "^::error title=stale-pin::$a at the pinned $p1 differs from master; bump .* to $p2$"
grep -q "error.*$b" <<<"$out" && expect "only the changed file is named" x
GITHUB_STEP_SUMMARY=$work/summary.md check; out=$(cat "$work/summary.md") rc=0
expect "the summary lists path, pin and bump" 0 "| \`$a\` | differs from master | \`$p1\` | \`$p2\` |"
pins "$a" "$p2" "$b" "$p1"; check; expect "bumping the pin passes" 0 'ruleset-pins: ok'
git rm -q "$b"; save "chore: drop b"; check; expect "a pinned file gone from master fails" 1 "$b does not exist on master"

# The manifest differs from the ruleset: fail both ways.
repo drift; p1=$(git rev-parse HEAD); echo a2 > "$a"; save; p2=$(git rev-parse HEAD)
pins "$a" "$p2" "$b" "$p1"; ruleset "$a" "$p1" "$b" "$p1"; check --ruleset "$work/ruleset.json"
expect "a ruleset pin the manifest lacks fails" 1 "^::error title=ruleset-pins::the live ruleset pins $a at $p1 but the manifest does not"
grep -q "the manifest pins $a at $p2 but the live ruleset does not" <<<"$out" || expect "and the other way round" x
ruleset "$a" "$p2"; check --ruleset "$work/ruleset.json"; expect "a manifest pin the ruleset lacks fails" 1 "the manifest pins $b at $p1 but the live ruleset does not"
ruleset "$a" "$p2" "$b" "$p1" .github/workflows/c.yml "$p1"; check --ruleset "$work/ruleset.json"; expect "a required workflow absent from the manifest fails" 1 "the live ruleset pins .github/workflows/c.yml"

# A pin that is not an ancestor of master, or not in the clone at all.
repo fork; p1=$(git rev-parse HEAD); git checkout -q -b side; echo side >> "$a"; save side; s=$(git rev-parse HEAD); git checkout -q master
pins "$a" "$s" "$b" "$p1"; check; expect "a pin off master fails" 1 "$a is pinned at $s, which is not an ancestor of master; bump the pin to $p1"
pins "$a" 1111111111111111111111111111111111111111; check; expect "an unknown pin fails" 1 'which is not in master.s history'

# Malformed input fails loudly.
pins "$a" "$p1"; pin "$b" short; check; expect "a short sha is malformed" 2 'malformed line'
pins "$a" "$p1" "$a" "$p1"; check; expect "a path listed twice fails" 2 'listed twice'
check --ref nosuch; expect "an unknown ref fails" 2 'not in this clone'
check --bogus x; expect "an unknown flag fails" 2 'usage'

# The checked-in manifest is well formed and the scheduled workflow runs the script.
run "$here/scripts/check-ruleset-pins.sh" --ref HEAD --manifest /dev/null; expect "an empty manifest fails" 2 "no pins"
run awk 'NF && !/^#/ && (NF != 2 || $2 !~ /^[0-9a-f]+$/ || length($2) != 40)' "$here/scripts/lists/ruleset-pins.txt"
[ -z "$out" ] && rc=0 || rc=1; expect "scripts/lists/ruleset-pins.txt is well formed" 0
wf="$here/.github/workflows/stale-pins.yml"
run grep -c -E '^  schedule:$|^  workflow_dispatch:$|^    runs-on: ubuntu-latest$|fetch-depth: 0$|scripts/check-ruleset-pins.sh' "$wf"
expect "stale-pins.yml: scheduled, hosted, full history, runs the script" 0 '^[5-9]$'

echo ruleset-pins tests: "$passed passed, $failed failed"
[ "$failed" -eq 0 ]
