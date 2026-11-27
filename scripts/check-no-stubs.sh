#!/usr/bin/env bash
# Org-wide refusal of implementation stubs. Needs only bash, git, grep, awk and xargs. Never skips: without
# .no-stubs nothing is exempt.
#   check-no-stubs.sh             tracked and untracked files in the working tree
#   check-no-stubs.sh --ci BASE   the working tree, and .no-stubs may only shrink (see CI below)
# A stub is a Rust todo!() or unimplemented!() call in a .rs file, or the stub marker in any text file but
# Markdown (md, markdown, mdx), where docs describe it. The marker is TODO and STUB joined by a hyphen; this
# file spells it in two parts so it never carries it. A Rust match after // or /* on its line is a comment
# that only names the macro, so it passes. A zero or missing BASE: the merge-base with
# NO_STUBS_DEFAULT_BRANCH, origin/HEAD, main or master. In a sync (see sync-tip.sh, beside this engine)
# the default branch's .no-stubs lines count as old too. NO_STUBS_EXCEPTION=true (the PR label) allows new lines.
# .no-stubs lines (# starts a comment):   exempt <glob>
# Globs: * is one path segment, ** any depth, others literal. projects/<p>/.no-stubs paths are folder-relative.
set -euo pipefail
export LC_ALL=C

# What counts as a stub, fixed org-wide: no repository can change it.
marker='TODO''-STUB'
rust='(^|[^A-Za-z0-9_])(todo|unimplemented)![ '$'\t'']*[({[]'
docs="md markdown mdx"

cd "$(git rev-parse --show-toplevel)"
config=.no-stubs
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
fail() { echo "no-stubs: $*" >&2; exit 2; }
is_zero() { case ${1:-0} in *[!0]*) return 1 ;; *) return 0 ;; esac; }
ext='function ext(p) { sub(/.*\//, "", p); sub(/^\.+/, "", p); if (p !~ /\.[^.]+$/) return ""; sub(/.*\./, "", p); return tolower(p) }'

# Prints the merge-base of TIP with the default branch, or nothing.
fallback_base() {
  local b d=${NO_STUBS_DEFAULT_BRANCH:-}
  for b in ${d:+"origin/$d" "$d"} "$(git symbolic-ref -q --short refs/remotes/origin/HEAD || :)" origin/main origin/master; do
    if [ -n "$b" ] && git rev-parse -q --verify "$b^{commit}" >/dev/null; then git merge-base "$1" "$b" 2>/dev/null || :; return; fi
  done
}

# Turns a .no-stubs text (stdin) at path CFG, with globs relative to folder PRE, into rule records:
#   E regex glob config (repo exempt) | X error
parse_rules() {
  awk -v cfg="$1" -v pre="$2" -v ref="$3" '
    function glob_re(g,   r, c, i) {
      for (i = 1; i <= length(g); i++) { c = substr(g, i, 1)
        if (c == "*" && substr(g, i, 3) == "**/") { r = r "(.*/)?"; i += 2 }
        else if (c == "*" && substr(g, i, 2) == "**") { r = r ".*"; i++ }
        else if (c == "*") r = r "[^/]*"; else if (c == "?") r = r "[^/]"
        else if (index("\\.[]()+{}|^$", c)) r = r "\\" c; else r = r c
      }
      return "^" r "$"
    }
    { sub(/\r$/, "") }
    /^[ \t]*(#|$)/ { next }
    $1 == "exempt" && NF == 2 { print "E " glob_re(pre $2) " " $2 " " cfg; next }
    { print "X " ref cfg ":" NR ": unknown or malformed line (only exempt <glob> is allowed): " $0 }'
}

# Prints the rule records of .no-stubs and each projects/<p>/.no-stubs at commit REF (empty: the working tree).
rules_at() {
  local f
  if [ -z "$1" ]; then printf '%s\n' "$config" projects/*/"$config"
  else git ls-tree -r --name-only "$1" -- "$config" projects; fi |
    awk '/^(projects\/[A-Za-z0-9_-][A-Za-z0-9._-]*\/)?\.no-stubs$/' | while IFS= read -r f; do
      if [ -z "$1" ]; then
        if [ -f "$f" ]; then parse_rules "$f" "${f%"$config"}" "" < "$f"; fi
      else git show "$1:$f" | parse_rules "$f" "${f%"$config"}" "$1:"; fi
    done
}

ci=0
case ${1:-} in
  --ci) ci=1; [ $# -le 2 ] || fail "usage: check-no-stubs.sh [--ci BASE]" ;;
  '') ;;
  *) fail "usage: check-no-stubs.sh [--ci BASE]" ;;
esac

rules_at "" > "$tmp/rules"
status=0
if grep -q '^X ' "$tmp/rules"; then sed -n 's/^X /[FAIL] /p' "$tmp/rules"; status=1; fi

# Every regular file that is not exempt, split into Rust files and files that may carry the marker.
git ls-files -z --cached --others --exclude-standard | tr '\0' '\n' | sort -u |
  awk -v rules="$tmp/rules" 'BEGIN { while ((getline r < rules) > 0) { split(r, w, " "); if (w[1] == "E") ex[w[2]] = 1 } }
    { for (re in ex) if ($0 ~ re) next; print }' | while IFS= read -r f; do
    if [ -f "$f" ] && [ ! -L "$f" ]; then printf '%s\n' "$f"; fi
  done > "$tmp/files"
awk -v docs="$docs" -v rs="$tmp/rs" -v txt="$tmp/txt" "$ext"'
  BEGIN { n = split(docs, d, " "); for (i = 1; i <= n; i++) doc[d[i]] = 1; printf "" > rs; printf "" > txt }
  { e = ext($0) } e == "rs" { print > rs } !(e in doc) { print > txt }' "$tmp/files"

# Files with a candidate line (grep -I skips binaries), then each such line, dropping Rust comments.
{ tr '\n' '\0' < "$tmp/rs" | xargs -0 -r grep -I -l -E -e "$rust" -- || :; } > "$tmp/hits"
{ tr '\n' '\0' < "$tmp/txt" | xargs -0 -r grep -I -l -F -e "$marker" -- || :; } >> "$tmp/hits"
sort -u "$tmp/hits" | sed 's|^|./|' | tr '\n' '\0' |
  xargs -0 -r awk -v docs="$docs" -v rust="$rust" -v marker="$marker" "$ext"'
    BEGIN { n = split(docs, d, " "); for (i = 1; i <= n; i++) doc[d[i]] = 1 }
    FNR == 1 { p = substr(FILENAME, 3); e = ext(p) }
    { sub(/\r$/, ""); why = "" }
    e == "rs" && match($0, rust) && substr($0, 1, RSTART) !~ /\/[\/*]/ {
      why = substr($0, RSTART, RLENGTH); sub(/^[^a-z]*/, "", why); sub(/!.*/, "", why); why = why "!() stub" }
    why == "" && !(e in doc) && index($0, marker) { why = "stub marker" }
    why != "" { t = $0; sub(/^[ \t]+/, "", t); if (length(t) > 160) t = substr(t, 1, 157) "..."
      print "[FAIL] " p ":" FNR ": " why ": " t }' > "$tmp/stubs"
found=$(awk 'END { print NR }' "$tmp/stubs")
cat "$tmp/stubs"
echo "no-stubs: $(awk 'END { print NR }' "$tmp/files") file(s) checked, $found stub(s)"
if [ "$found" -gt 0 ]; then
  status=1
  echo "no-stubs: implement each stub before it reaches a protected branch. Generated or vendored paths go in" \
    ".no-stubs as exempt <glob>; a reviewer allows a new line with the no-stubs-exception label, then closes and reopens the pull request."
fi

# CI: each .no-stubs may only shrink against BASE, and in a sync the default branch tip.
if [ "$ci" -eq 1 ]; then
  base=${2:-}
  if is_zero "$base" || ! git cat-file -e "$base^{commit}" 2>/dev/null; then base=$(fallback_base HEAD); fi
  engine_dir=$(cd "$(dirname "${BASH_SOURCE[0]:-.}")" && pwd)
  [ -x "$engine_dir/sync-tip.sh" ] || fail "sync-tip.sh is missing beside the engine"
  sync=$("$engine_dir/sync-tip.sh" "${NO_STUBS_DEFAULT_BRANCH:-}" "${NO_STUBS_REPO:-}" "${NO_STUBS_HEAD_REPO:-}" \
    "${NO_STUBS_BASE_REF:-}" "${NO_STUBS_HEAD_REF:-}" "$base" HEAD)
  for r in "$base" "$sync"; do [ -z "$r" ] || rules_at "$r"; done | grep '^E ' > "$tmp/old-rules" || true
  awk 'FILENAME == ARGV[1] { old[$2 " " $4] = 1; next } $1 == "E" && !(($2 " " $4) in old) { print $4 " new exempt line " $3 }' \
    "$tmp/old-rules" "$tmp/rules" > "$tmp/added"
  if [ -s "$tmp/added" ]; then
    if [ "${NO_STUBS_EXCEPTION:-}" = true ]; then
      sed 's/^[^ ]* /no-stubs: allowed by the no-stubs-exception label: /' "$tmp/added"
    else
      sed 's/^\([^ ]*\) /[FAIL] \1: /' "$tmp/added"
      echo "no-stubs: .no-stubs may only shrink. A reviewer allows an addition by" \
        "putting the no-stubs-exception label on the pull request, then closing and reopening it."
      status=1
    fi
  fi
fi

[ "$status" -eq 0 ] && echo "no-stubs: ok" || echo "no-stubs: see .no-stubs and scripts/check-no-stubs.sh"
exit "$status"
