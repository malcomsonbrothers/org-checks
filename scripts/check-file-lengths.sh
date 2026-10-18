#!/usr/bin/env bash
# Org-wide per-file line limits. Needs only bash, git and awk. Never skips: with no
# .file-lengths the org limits below apply with no exemptions and no baseline.
#   check-file-lengths.sh                  tracked and untracked files in the working tree
#   check-file-lengths.sh --staged         the index (pre-commit); lowers or drops shrunk rows
#   check-file-lengths.sh --range BASE TIP files changed in BASE...TIP, read at TIP (pre-push)
#   check-file-lengths.sh --ci BASE        the working tree, and no .file-lengths may add lines
#                                          against BASE unless FILE_LENGTHS_EXCEPTION=true (label)
#   check-file-lengths.sh --print-baseline "baseline <path> <lines>" for every oversized file
# An all-zero or missing BASE falls back to the merge-base with the default branch
# (FILE_LENGTHS_DEFAULT_BRANCH, else origin/HEAD, origin/main or origin/master).
# .file-lengths lines (a repo may not change an org limit, only add new file types):
#   limit <max lines> <extensions...>   exempt <glob>   baseline <path> <lines>
# Globs: * is one path segment, ** any depth; other characters are literal. Each
# projects/<p>/.file-lengths adds exempt and baseline lines relative to its folder.
set -euo pipefail
export LC_ALL=C

# Org default limits. Extension-less files whose shebang runs sh, bash or zsh get 250.
org_limits="600 rs svelte ts tsx js jsx mjs cjs mts cts py css scss swift go kt;250 sh bash zsh sql"
shell_limit=250

cd "$(git rev-parse --show-toplevel)"
config=.file-lengths
mode=${1:-all}
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
fail() { echo "file-lengths: $*" >&2; exit 2; }
is_zero() { case ${1:-0} in *[!0]*) return 1 ;; *) return 0 ;; esac; }

# Prints the merge-base of TIP with the default branch, or nothing (check every file).
fallback_base() {
  local b d=${FILE_LENGTHS_DEFAULT_BRANCH:-}
  for b in ${d:+"origin/$d" "$d"} "$(git symbolic-ref -q --short refs/remotes/origin/HEAD || :)" \
    origin/main origin/master; do
    if [ -n "$b" ] && git rev-parse -q --verify "$b^{commit}" >/dev/null; then git merge-base "$1" "$b" 2>/dev/null || :; return; fi
  done
}

# Copies .file-lengths and each projects/<p>/.file-lengths at SRC (a commit, : for the
# index, empty for the working tree) into DIR, and lists them in DIR.list.
load_configs() {
  local f
  case $1 in
    '') printf '%s\n' "$config" projects/*/"$config" ;;
    :) git ls-files -- "$config" projects ;;
    *) git ls-tree -r --name-only "$1" -- "$config" projects ;;
  esac | awk '/^(projects\/[A-Za-z0-9._-]+\/)?\.file-lengths$/' | while IFS= read -r f; do
    if [ -z "$1" ] && [ ! -f "$f" ]; then continue; fi
    mkdir -p "$2/${f%"$config"}" && printf '%s\n' "$f"
    if [ -z "$1" ]; then cat "$f"; else git show "${1%:}:$f"; fi > "$2/$f"
  done > "$2.list"
}

# Turns org limits plus the configs that load_configs put in DIR into rule records, each
# config's paths prefixed with its folder: O ext max (org) | L ext max config (repo)
#   | E regex glob config | B path lines config | X error
parse_rules() {
  awk -v org="$org_limits" -v dir="$1" '
    function glob_re(g,   r, c, i) {
      for (i = 1; i <= length(g); i++) { c = substr(g, i, 1)
        if (c == "*" && substr(g, i, 3) == "**/") { r = r "(.*/)?"; i += 2 }
        else if (c == "*" && substr(g, i, 2) == "**") { r = r ".*"; i++ }
        else if (c == "*") r = r "[^/]*"; else if (c == "?") r = r "[^/]"
        else if (index("\\.[]()+{}|^$", c)) r = r "\\" c; else r = r c
      }
      return "^" r "$"
    }
    function err(m) { print "X " cfg ":" nr ": " m }
    function rule(   e, j) {
      sub(/\r$/, ""); if (/^[ \t]*(#|$)/) return
      if ($1 == "limit" && pre != "") err("limit lines belong in the root .file-lengths")
      else if ($1 == "limit") {
        if ($2 !~ /^[0-9]+$/ || NF < 3) { err("expected: limit <max lines> <extensions...>"); return }
        for (j = 3; j <= NF; j++) {
          e = $j; sub(/^\./, "", e)
          if (e in orgl) err("limit for ." e " is set org-wide to " orgl[e] " lines in the shared check; a repo may not change it")
          else print "L " e " " $2 " " cfg
        }
      } else if ($1 == "exempt" && NF == 2) print "E " glob_re(pre $2) " " $2 " " cfg
      else if ($1 == "baseline" && NF == 3 && $3 ~ /^[0-9]+$/) {
        if ((pre $2) in seen) err("duplicate baseline row for " pre $2)
        seen[pre $2] = 1; print "B " pre $2 " " $3 " " cfg
      } else err("unknown or malformed line: " $0)
    }
    BEGIN {
      n = split(org, rows, ";")
      for (i = 1; i <= n; i++) { k = split(rows[i], w, " ")
        for (j = 2; j <= k; j++) { orgl[w[j]] = w[1]; print "O " w[j] " " w[1] } }
      while ((getline cfg < (dir ".list")) > 0) {
        pre = cfg; sub(/[^\/]*$/, "", pre); nr = 0
        while ((getline line < (dir "/" cfg)) > 0) { nr++; $0 = line; rule() }
      }
    }'
}

# Prints "lines<TAB>shebang-is-shell<TAB>path" for each non-empty file named on stdin
# (newline separated, relative to the current directory).
count_files() {
  sed 's|^|./|' | tr '\n' '\0' | xargs -0 -r awk '
    FNR == 1 { if (p != "") print n "\t" s "\t" p
      p = substr(FILENAME, 3); l = $0; sub(/\r$/, "", l)
      s = (l ~ /^#![ \t]*[^ \t]*\/(env[ \t]+(-S[ \t]+)?)?(sh|bash|zsh)([ \t]|$)/) ? 1 : 0 }
    { n = FNR }
    END { if (p != "") print n "\t" s "\t" p }'
}

# Keeps paths (stdin) that have a limited extension or no extension and are not exempt.
candidates() {
  awk -v rules="$tmp/rules" '
    BEGIN { while ((getline r < rules) > 0) { split(r, w, " ")
      if (w[1] == "O" || w[1] == "L") lim[w[2]] = 1; else if (w[1] == "E") ex[w[2]] = 1 } }
    { b = $0; sub(/.*\//, "", b); e = ""
      if (b ~ /^[^.].*\.[^.]+$/) { e = b; sub(/.*\./, "", e) }
      if (e != "" && !(e in lim)) next; for (re in ex) if ($0 ~ re) next
      print }'
}

# Copies regular-file blobs ("mode sha<TAB>path" on stdin, for paths in $tmp/want) into
# $tmp/t, then counts them there.
count_blobs() {
  local meta mode sha p
  mkdir -p "$tmp/t"
  awk -F '\t' 'NR == FNR { want[$0] = 1; next } ($2 in want)' "$tmp/want" - |
    while IFS="$(printf '\t')" read -r meta p; do
      mode=${meta%% *}; sha=${meta#* }; case $mode in 100644|100755) ;; *) continue ;; esac
      mkdir -p "$tmp/t/$(dirname "$p")" && git cat-file blob "$sha" > "$tmp/t/$p"
      printf '%s\n' "$p"
    done > "$tmp/blobs"
  (cd "$tmp/t" && count_files < "$tmp/blobs")
}

# Load the configuration from the place the mode measures.
case $mode in
  --staged) load_configs : "$tmp/c" ;;
  --range)
    [ $# -eq 3 ] || fail "usage: --range BASE TIP"
    tip=$(git rev-parse -q --verify "$3^{commit}") || fail "unknown commit $3"
    base=$2
    if is_zero "$base"; then base=$(fallback_base "$tip")
    elif ! git cat-file -e "$base^{commit}" 2>/dev/null; then
      fail "remote commit $base is not in this clone; run git fetch and push again"
    fi
    load_configs "$tip" "$tmp/c" ;;
  --ci|--print-baseline|all) load_configs "" "$tmp/c" ;;
  *) fail "unknown mode $mode" ;;
esac
parse_rules "$tmp/c" > "$tmp/rules"

# Measure. $tmp/exists lists every path present, for stale baseline rows.
case $mode in
  --staged)
    git ls-files -s -z | tr '\0' '\n' |
      awk -F '\t' '{ split($1, m, " "); print m[1] " " m[2] "\t" $2 }' > "$tmp/index"
    cut -f2- "$tmp/index" > "$tmp/exists"
    git diff --cached --name-only --no-renames --diff-filter=d -z | tr '\0' '\n' | candidates > "$tmp/want"
    count_blobs < "$tmp/index" > "$tmp/counts" ;;
  --range)
    git ls-tree -r -z "$tip" | tr '\0' '\n' |
      awk -F '\t' '{ split($1, m, " "); print m[1] " " m[3] "\t" $2 }' > "$tmp/tree"
    cut -f2- "$tmp/tree" > "$tmp/exists"
    if [ -n "$base" ]; then
      git diff --name-only --no-renames --diff-filter=d -z "$base...$tip" | tr '\0' '\n'
    else cut -f2- "$tmp/tree"; fi | candidates > "$tmp/want"
    count_blobs < "$tmp/tree" > "$tmp/counts" ;;
  *)
    git ls-files -z --cached --others --exclude-standard | tr '\0' '\n' | sort -u > "$tmp/exists"
    candidates < "$tmp/exists" | while IFS= read -r f; do
      if [ -f "$f" ] && [ ! -L "$f" ]; then printf '%s\n' "$f"; fi
    done | count_files > "$tmp/counts" ;;
esac

status=0
awk -F '\t' -v staged="$([ "$mode" = --staged ] && echo 1 || echo 0)" -v sl="$shell_limit" \
  -v pb="$([ "$mode" = --print-baseline ] && echo 1 || echo 0)" '
  FILENAME == ARGV[1] { split($0, w, " ")
    if (w[1] == "O" || w[1] == "L") lim[w[2]] = w[3]; else if (w[1] == "B") row[w[2]] = w[3]
    else if (w[1] == "X") { sub(/^X /, ""); m = "[FAIL] " $0; if (pb) print m > "/dev/stderr"; else print m; bad = 1 }
    next }
  FILENAME == ARGV[2] { have[$0] = 1; next }
  { n = $1; p = $3; b = p; sub(/.*\//, "", b); e = ""
    if (b ~ /^[^.].*\.[^.]+$/) { e = b; sub(/.*\./, "", e) }
    max = e != "" ? lim[e] : ($2 == 1 ? sl : "")
    if (pb) { if (max != "" && n > max) print "baseline " p " " n; next }
    if (max == "") { if (p in row) { print "[FAIL] " p ": baseline row for a file with no limit, delete it"; bad = 1 }; next }
    if (p in row) {
      if (n > row[p]) { print "[FAIL] " p ": " n " lines, baseline " row[p] " (grew; split it)"; bad = 1 }
      else if ((n < row[p] || n <= max) && staged) print (n > max ? "LOWER " p " " n : "DROP " p)
      else if (n < row[p]) { print "[FAIL] " p ": " n " lines, lower its baseline row from " row[p] " to " (n > max ? n : "nothing (delete the row)"); bad = 1 }
      else if (n <= max) { print "[FAIL] " p ": " n " lines is within the limit " max ", delete its baseline row"; bad = 1 }
    } else if (n > max) { print "[FAIL] " p ": " n " lines, limit " max " (split it)"; bad = 1 }
  }
  END {
    for (p in row) if (!pb && !(p in have)) {
      if (staged) print "DROP " p; else { print "[FAIL] baseline row for missing file " p; bad = 1 }
    }
    exit bad
  }' "$tmp/rules" "$tmp/exists" "$tmp/counts" > "$tmp/out" || status=1
grep -v -E '^(LOWER|DROP) ' "$tmp/out" || true
[ "$mode" != --print-baseline ] || exit "$status"

# Pre-commit: rewrite lowered or dropped rows in the index copies (and the working copies).
if grep -q -E '^(LOWER|DROP) ' "$tmp/out"; then
  rewrite() {
    awk -v edits="$tmp/out" -v pre="$1" '
      BEGIN { while ((getline r < edits) > 0) { split(r, w, " ")
        if (w[1] == "LOWER") to[w[2]] = w[3]; else if (w[1] == "DROP") to[w[2]] = "" } }
      $1 == "baseline" && ((pre $2) in to) { if (to[pre $2] != "") print "baseline " $2 " " to[pre $2]; next }
      { print }'
  }
  while IFS= read -r f; do
    rewrite "${f%"$config"}" < "$tmp/c/$f" > "$tmp/new"
    if cmp -s "$tmp/new" "$tmp/c/$f"; then continue; fi
    git update-index --add --cacheinfo "100644,$(git hash-object -w "$tmp/new"),$f"
    if [ -f "$f" ]; then rewrite "${f%"$config"}" < "$f" > "$tmp/wt" && cat "$tmp/wt" > "$f"; fi
  done < "$tmp/c.list"
  sed -n 's/^LOWER \(.*\) \([0-9]*\)$/file-lengths: lowered the baseline row for \1 to \2 (staged)/p
s/^DROP \(.*\)$/file-lengths: dropped the baseline row for \1 (staged)/p' "$tmp/out"
fi

# CI: each .file-lengths may only shrink compared with the same file at BASE.
if [ "$mode" = --ci ]; then
  base=${2:-}
  if is_zero "$base" || ! git cat-file -e "$base^{commit}" 2>/dev/null; then base=$(fallback_base HEAD); fi
  : > "$tmp/b.list"; if [ -n "$base" ]; then load_configs "$base" "$tmp/b"; fi
  parse_rules "$tmp/b" | grep -v '^[OX] ' > "$tmp/old-rules" || true
  grep -v '^[OX] ' "$tmp/rules" > "$tmp/new-rules" || true
  awk '
    FILENAME == ARGV[1] { old[$1 " " $2 " " $4] = $3; next }
    { k = $1 " " $2 " " $4; f = $4 " " }
    $1 == "B" && !(k in old) { print f "new baseline row " $2 " " $3; next }
    $1 == "B" && $3 > old[k] { print f "baseline row " $2 " raised from " old[k] " to " $3; next }
    $1 == "E" && !(k in old) { print f "new exempt line " $3; next }
    $1 == "L" && !(k in old) { print f "new limit " $3 " for ." $2; next }
    $1 == "L" && $3 > old[k] { print f "limit for ." $2 " raised from " old[k] " to " $3 }
  ' "$tmp/old-rules" "$tmp/new-rules" > "$tmp/added"
  if [ -s "$tmp/added" ]; then
    if [ "${FILE_LENGTHS_EXCEPTION:-}" = true ]; then
      sed 's/^[^ ]* /file-lengths: allowed by the file-lengths-exception label: /' "$tmp/added"
    else
      sed 's/^\([^ ]*\) /[FAIL] \1: /' "$tmp/added"
      echo "file-lengths: .file-lengths may only shrink. A reviewer allows an addition by" \
        "putting the file-lengths-exception label on the pull request, then closing and reopening it."
      status=1
    fi
  fi
fi

[ "$status" -eq 0 ] && echo "file-lengths: ok" || echo "file-lengths: see .file-lengths and scripts/check-file-lengths.sh"
exit "$status"
