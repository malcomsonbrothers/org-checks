#!/usr/bin/env bash
# Tests for check-pr-title.sh and the copy embedded in the pr-title workflow.
# Usage: scripts/check-pr-title.test.sh
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
wf="$here/.github/workflows/pr-title.yml"
code=$(grep -v -E "^ *#" "$wf") # the workflow without its comments
passed=0 failed=0

run() { out=$("$@" 2>&1) && rc=0 || rc=$?; }
title() { run "$here/scripts/check-pr-title.sh" "$@"; }
expect() { # expect NAME RC [PATTERN that must appear in the output]
  if [ "$rc" = "$2" ] && { [ -z "${3:-}" ] || printf '%s\n' "$out" | grep -q -e "$3"; }; then
    passed=$((passed + 1))
  else
    failed=$((failed + 1)); echo "not ok: $1 (exit $rc, wanted $2${3:+, /$3/})"; printf '%s\n' "$out" | sed 's/^/    /'
  fi
}

# Conventional Commit titles pass: every type, optional scope, optional !.
for t in feat fix docs style refactor perf test build ci chore revert; do
  title "$t: do the thing"; expect "type $t" 0 'pr-title: ok'
done
title 'feat(api): add the export endpoint'; expect "scope" 0
title 'feat!: drop the v1 routes'; expect "breaking without scope" 0
title 'refactor(web,api)!: rename the session cookie'; expect "comma scopes and breaking" 0
title 'build(deps): bump serde from 1.0.1 to 1.0.2'; expect "dependabot build(deps) form" 0
title 'chore(org-checks/ci_2.x): pin'; expect "scope characters . _ / -" 0
title 'revert: feat(api): add the export endpoint'; expect "revert: form" 0

# Anything else fails, with the fix-and-re-run instruction.
title 'Add the export endpoint'; expect "plain sentence" 1 'edit the title, then re-run this check (or close and reopen'
title 'Feat: add it'; expect "capitalised type" 1 'not a Conventional Commit'
title 'feature: add it'; expect "unknown type" 1
title 'feat:add it'; expect "no space after the colon" 1
title 'feat: '; expect "empty summary" 1
title 'feat(): add it'; expect "empty scope" 1
title 'feat(API): add it'; expect "upper-case scope" 1
title 'feat(web api): add it'; expect "space in the scope" 1
title '!feat: add it'; expect "leading !" 1
title ' feat: add it'; expect "leading space" 1
title 'Revert "feat: add it"'; expect "git revert subject must be reworded to revert:" 1
title 'fixup! feat: add it'; expect "fixup! never reaches a title" 1
title 'Merge branch main'; expect "merge subject" 1
title "$(printf 'Bad title\nfeat: hidden on a second line')"; expect "a second line cannot satisfy it" 1
title ''; expect "empty title" 1
title 'WIP feat: add it'; expect "prefix before the type" 1 '    WIP feat: add it'

# The workflow: required-workflow events only, self-hosted, live title through the API.
run grep -n -E '^    types: \[opened, synchronize, reopened\]$' "$wf"; expect "opened, synchronize, reopened only" 0
run grep -n -E 'edited|labeled|workflow_call|pull_request_target' <<<"$code"; expect "no ignored or unsafe triggers" 1
run grep -n -E '^  pull-requests: read$|^  contents: read$' "$wf"
[ "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" = 2 ] && rc=0 || rc=1; expect "read-only permissions" 0
run grep -n -E 'write' <<<"$code"; expect "no write permission" 1
run grep -n -E 'runs-on: \[self-hosted, Linux, metal\]$' "$wf"; expect "self-hosted metal runner" 0
run grep -n -F 'gh api "repos/$REPO/pulls/$PR_NUMBER" --jq .title' "$wf"; expect "reads the live title" 0
run grep -n -F 'event.pull_request.title' <<<"$code"; expect "never reads the event title" 1
run grep -n -F 'Edit the title, then re-run this check (or close and reopen the pull request)' "$wf"
expect "annotation tells the author how to re-run" 0

# The workflow embeds this exact script.
run awk '/<<.ENGINE.$/ { on = 1; next } /^ *ENGINE$/ { on = 0 } on { sub(/^          /, ""); print }' "$wf"
[ "$out" = "$(cat "$here/scripts/check-pr-title.sh")" ] && rc=0 || rc=1
expect "workflow copy matches scripts/check-pr-title.sh (re-embed it)" 0

echo "pr-title tests: $passed passed, $failed failed"
[ "$failed" -eq 0 ]
