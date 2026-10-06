#!/usr/bin/env bash
# Checks that a pull request title is a Conventional Commit subject: type(scope)!: summary,
# with the scope and ! optional. The pattern matches the org commit-message rulesets, so a
# squash merge that takes the title as its commit subject passes them too.
#   check-pr-title.sh "<title>"
set -euo pipefail
export LC_ALL=C
pattern='^(feat|fix|docs|style|refactor|perf|test|build|ci|chore|revert)(\([a-z0-9._/,-]+\))?!?: .+'
title=${1-}
if [[ $title != *$'\n'* && $title =~ $pattern ]]; then
  echo "pr-title: ok: $title"
  exit 0
fi
cat <<MSG
[FAIL] The pull request title is not a Conventional Commit:
    $title
Expected: type(scope)!: summary, where (scope) and ! are optional, for example
    feat(api): add the export endpoint
    fix: handle an empty basket
    refactor(web,api)!: rename the session cookie
Types: feat fix docs style refactor perf test build ci chore revert.
Scopes: lower-case letters, digits and . _ / , - only.
To fix: edit the title, then re-run this check (or close and reopen the pull request).
Editing the title does not re-run it by itself; a re-run reads the current title.
MSG
exit 1
