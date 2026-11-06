#!/usr/bin/env bash
# Fails while a required workflow pinned by the org ruleset lags this repository's master: the
# file at the pinned commit differs from master's copy, or the pin is not an ancestor of master.
# The pins come from scripts/lists/ruleset-pins.txt; with --ruleset (the JSON of
# GET /orgs/{org}/rulesets/{id}) it also fails while that list differs from the live ruleset.
# Run in a clone with master's full history. Writes ::error lines, and a table to
# $GITHUB_STEP_SUMMARY when set.
# Usage: scripts/check-ruleset-pins.sh [--manifest FILE] [--ruleset FILE] [--ref REF]
#        [--repo-id ID]
set -euo pipefail
manifest='' ruleset='' ref=master repo_id=1407359561
while [ $# -gt 0 ]; do
  case $1 in
    --manifest) manifest=${2-} ;;
    --ruleset) ruleset=${2-} ;;
    --ref) ref=${2-} ;;
    --repo-id) repo_id=${2-} ;;
    *) echo "usage: $0 [--manifest FILE] [--ruleset FILE] [--ref REF] [--repo-id ID]" >&2; exit 2 ;;
  esac
  shift 2 || { echo "$0: $1 needs a value" >&2; exit 2; }
done
top=$(git rev-parse --show-toplevel)
manifest=${manifest:-$top/scripts/lists/ruleset-pins.txt}
summary=${GITHUB_STEP_SUMMARY:-/dev/null}
git rev-parse -q --verify "$ref^{commit}" >/dev/null || { echo "$0: $ref is not in this clone" >&2; exit 2; }
master=$(git rev-parse "$ref^{commit}")
status=0 rows=()
fail() { # fail TITLE MESSAGE [summary row]
  echo "::error title=$1::$2"; status=1
  [ -z "${3:-}" ] || rows+=("$3")
}

pins=$({ grep -v -e '^[[:space:]]*#' -e '^[[:space:]]*$' "$manifest" || :; } | awk '{ print $1, $2 }' | LC_ALL=C sort)
bad=$(awk 'NF != 2 || $2 !~ /^[0-9a-f]{40}$/' <<<"$pins")
[ -z "$bad" ] || { echo "$0: malformed line(s) in $manifest (want <path> <40-hex sha>):" >&2; printf '%s\n' "$bad" >&2; exit 2; }
[ -n "$pins" ] || { echo "$0: no pins in $manifest" >&2; exit 2; }
dupes=$(awk '{ print $1 }' <<<"$pins" | uniq -d)
[ -z "$dupes" ] || { echo "$0: path(s) listed twice in $manifest: $dupes" >&2; exit 2; }

if [ -n "$ruleset" ]; then
  live=$(jq -r --argjson id "$repo_id" '.rules[] | select(.type == "workflows") | .parameters.workflows[]
    | select(.repository_id == $id) | "\(.path) \(.sha)"' "$ruleset" | LC_ALL=C sort)
  if [ "$live" != "$pins" ]; then
    while read -r p s; do [ -z "$p" ] || fail ruleset-pins "the live ruleset pins $p at $s but the manifest does not; update $(basename "$manifest")" \
      "| \`$p\` | manifest differs from ruleset | \`$s\` (ruleset) | update the manifest |"; done < <(comm -13 <(printf '%s\n' "$pins") <(printf '%s\n' "$live"))
    while read -r p s; do [ -z "$p" ] || fail ruleset-pins "the manifest pins $p at $s but the live ruleset does not; update the ruleset or the manifest" \
      "| \`$p\` | manifest differs from ruleset | \`$s\` (manifest) | update the ruleset or the manifest |"; done < <(comm -23 <(printf '%s\n' "$pins") <(printf '%s\n' "$live"))
  else
    echo "ruleset-pins: the manifest matches the live ruleset"
  fi
fi

while read -r path sha; do
  [ -n "$path" ] || continue
  last=$(git log -1 --format=%H "$master" -- "$path")
  if ! git rev-parse -q --verify "$sha^{commit}" >/dev/null; then
    fail stale-pin "$path is pinned at $sha, which is not in $ref's history; bump the pin to ${last:-a commit on $ref}" \
      "| \`$path\` | pin not in history | \`$sha\` | \`${last:--}\` |"
  elif ! git merge-base --is-ancestor "$sha" "$master"; then
    fail stale-pin "$path is pinned at $sha, which is not an ancestor of $ref; bump the pin to ${last:-a commit on $ref}" \
      "| \`$path\` | pin not on $ref | \`$sha\` | \`${last:--}\` |"
  elif ! git cat-file -e "$master:$path" 2>/dev/null; then
    fail stale-pin "$path does not exist on $ref; drop it from the ruleset and the manifest" \
      "| \`$path\` | missing on $ref | \`$sha\` | remove the pin |"
  elif ! git diff --quiet "$sha" "$master" -- "$path"; then
    fail stale-pin "$path at the pinned $sha differs from $ref; bump the ruleset pin (and the manifest) to $last" \
      "| \`$path\` | differs from $ref | \`$sha\` | \`$last\` |"
  else
    echo "ruleset-pins: $path is current at $sha"
  fi
done <<<"$pins"

if [ "$status" -ne 0 ]; then
  { echo "## Required workflow pins lag $ref"; echo
    echo "| Workflow | Problem | Pinned | Bump to |"; echo "| --- | --- | --- | --- |"
    printf '%s\n' "${rows[@]}"; echo
    echo "Bump each pin in org ruleset 24585672 and in \`scripts/lists/ruleset-pins.txt\`."; } >> "$summary"
else
  echo "ruleset-pins: ok ($(grep -c . <<<"$pins") pins, $ref at $master)"
fi
exit "$status"
