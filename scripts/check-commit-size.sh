#!/usr/bin/env bash
# Org-wide per-commit size limit. Needs only bash, git and awk. Every commit in BASE..TIP
# may change at most 1,000 lines (additions plus deletions, renames detected), not counting
# lockfiles, real binaries of the listed formats or paths the repo exempts in .commit-size.
# Other binaries count a line per 40 bytes; a merge counts what it adds beyond an automatic
# merge; a path with a newline or tab fails. Never skips.
#   check-commit-size.sh [BASE [TIP]]   commits in BASE..TIP (TIP defaults to HEAD)
#   check-commit-size.sh --ci BASE TIP  the same, and .commit-size may not add exempt lines
#                                       compared with BASE. COMMIT_SIZE_EXCEPTION=true (the
#                                       PR label) allows oversized commits and new lines.
# An all-zero or missing BASE falls back to the merge-base with the default branch
# (COMMIT_SIZE_DEFAULT_BRANCH, else origin/HEAD, origin/main or origin/master); with
# none, every commit reachable from TIP is checked. With COMMIT_SIZE_BASE_REF equal to the
# default branch, commits already on origin/staging are skipped (a promotion).
# .commit-size lines, read at TIP (# starts a comment):   exempt <glob>
# Globs: * is one path segment, ** any depth; other characters are literal.
set -euo pipefail
export LC_ALL=C

# Org limit and the lockfiles never counted, at any depth. No repository can change them.
limit=1000
lockfiles="Cargo.lock bun.lock package-lock.json pnpm-lock.yaml yarn.lock uv.lock"
# Binary formats exempt only where the content really is binary (to git, ignoring attributes).
binexts="png jpg jpeg gif webp ico woff woff2 ttf otf pdf mp4 webm wasm"

cd "$(git rev-parse --show-toplevel)"
config=.commit-size
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
fail() { echo "commit-size: $*" >&2; exit 2; }
is_zero() { case ${1:-0} in *[!0]*) return 1 ;; *) return 0 ;; esac; }

default_branch() {
  local b d=${COMMIT_SIZE_DEFAULT_BRANCH:-}
  for b in ${d:+"origin/$d" "$d"} "$(git symbolic-ref -q --short refs/remotes/origin/HEAD || :)" \
    origin/main origin/master; do
    [ -n "$b" ] && git rev-parse -q --verify "$b^{commit}" >/dev/null && { echo "$b"; return; }
  done
  return 0
}

# Prints the merge-base of TIP with the default branch, or nothing (check every commit).
fallback_base() {
  local d
  d=$(default_branch)
  [ -n "$d" ] && git merge-base "$1" "$d" 2>/dev/null || true
}

# Turns the org lockfiles plus a .commit-size text (stdin) into rule records:
#   D regex glob (org lockfile) | E regex glob (repo exempt) | X error
parse_rules() {
  awk -v locks="$lockfiles" -v cfg="$1" '
    function glob_re(g,   r, c, i) {
      r = ""
      for (i = 1; i <= length(g); i++) {
        c = substr(g, i, 1)
        if (c == "*" && substr(g, i, 3) == "**/") { r = r "(.*/)?"; i += 2 }
        else if (c == "*" && substr(g, i, 2) == "**") { r = r ".*"; i++ }
        else if (c == "*") r = r "[^/]*"
        else if (c == "?") r = r "[^/]"
        else if (index("\\.[]()+{}|^$", c)) r = r "\\" c
        else r = r c
      }
      return "^" r "$"
    }
    BEGIN { n = split(locks, l, " "); for (i = 1; i <= n; i++) print "D " glob_re("**/" l[i]) " " l[i] }
    { sub(/\r$/, "") }
    /^[ \t]*(#|$)/ { next }
    $1 == "exempt" && NF == 2 { print "E " glob_re($2) " " $2; next }
    { print "X " cfg ":" NR ": unknown or malformed line (only exempt <glob> is allowed): " $0 }'
}

# Prints commit C's changes as NUL-separated --raw then --numstat records: against its
# parent (the empty tree for a root commit), and for a merge what it adds beyond an automatic
# merge (nothing when its tree equals a parent's). Attributes come from the empty tree, so a
# pull request's .gitattributes cannot mark text as binary.
diff_of() {
  local c=$1 p ps tree opts=(-r -M -l0 --no-textconv --no-abbrev --raw --numstat -z)
  local g=(git -c core.attributesFile=/dev/null --attr-source=4b825dc642cb6eb9a060e54bf8d69288fbee4904)
  read -r -a ps < <(git rev-list --parents -n 1 "$c")
  if [ "${#ps[@]}" -le 2 ]; then "${g[@]}" diff-tree --root --no-commit-id "${opts[@]}" "$c"; return; fi
  tree=$(git rev-parse "$c^{tree}")
  for p in "${ps[@]:1}"; do [ "$(git rev-parse "$p^{tree}")" != "$tree" ] || return 0; done
  "${g[@]}" show --remerge-diff --format= "${opts[@]}" "$c"
}

# Reads diff_of output (NULs turned into newlines, after refusing paths with a newline) and
# prints "class<TAB>add<TAB>del<TAB>new blob<TAB>binary<TAB>listed format<TAB>path" per
# file. Class: T a path has a tab | E exempt | W renamed out of an exempt path | N counted.
classify() {
  awk -v rules="$tmp/rules" -v bin="$binexts" '
    BEGIN { while ((getline r < rules) > 0) { split(r, w, " "); if (w[1] == "D" || w[1] == "E") ex[w[2]] = 1 }
      n = split(bin, b, " "); for (k = 1; k <= n; k++) isbin[b[k]] = 1 }
    function exempt(p,   re) { for (re in ex) if (p ~ re) return 1; return 0 }
    rp == 2 { old[i] = $0; rp = 1; next }
    rp == 1 { new[i] = $0; if (!ren[i]) old[i] = $0; rp = 0; next }
    np > 0 { np--; next }
    !num && /^:/ { i++; split($0, h, " "); sha[i] = h[4]; ren[i] = h[5] ~ /^[RC]/; rp = ren[i] ? 2 : 1; next }
    { num = 1; j++; split($0, f, "\t"); np = ren[j] ? 2 : 0; o = old[j]; p = new[j]
      e = tolower(p); sub(/.*\//, "", e); if (e !~ /^[^.].*\.[^.]+$/) e = ""; sub(/.*\./, "", e)
      if (o ~ /\t/ || p ~ /\t/) c = "T"; else if (exempt(p)) c = "E"
      else if (ren[j] && exempt(o)) c = "W"; else c = "N"
      print c "\t" f[1] + 0 "\t" f[2] + 0 "\t" sha[j] "\t" (f[1] == "-") "\t" ((e in isbin) ? 1 : 0) "\t" p }'
}

# Prints "<counted> <exempt> <paths with a tab>" for the rows in $tmp/rows. A binary (to git:
# a NUL in the first 8,000 bytes) of a listed format is exempt; any other binary counts the
# larger of its lines and one line per 40 bytes. A file renamed out of an exempt path counts
# in full. Deleting a binary counts nothing.
tally() {
  awk -F '\t' '($1 == "W" || $5) && $4 !~ /^0+$/ { print $4 }' "$tmp/rows" | sort -u |
    while IFS= read -r sha; do
      git cat-file blob "$sha" > "$tmp/blob"
      printf '%s %s %s\n' "$sha" "$(awk 'END { print NR }' "$tmp/blob")" "$(wc -c < "$tmp/blob")"
    done > "$tmp/inspect"
  awk -F '\t' 'FILENAME == ARGV[1] { split($0, w, " "); nl[w[1]] = w[2]; by = int((w[3] + 39) / 40)
      size[w[1]] = by > w[2] ? by : w[2]; next }
    $1 == "T" { tab++; next }
    $1 == "E" { sk += $5 ? size[$4] : $2 + $3; next }
    $5 && $6 { sk += size[$4]; next }
    $1 == "W" { cnt += $5 ? size[$4] : nl[$4]; next }
    { cnt += $5 ? size[$4] : $2 + $3 }
    END { print cnt + 0, sk + 0, tab + 0 }' "$tmp/inspect" "$tmp/rows"
}

ci=0
if [ "${1:-}" = --ci ]; then ci=1; shift; fi
case ${1:-} in -*) fail "usage: check-commit-size.sh [--ci] [BASE [TIP]]" ;; esac
[ $# -le 2 ] || fail "usage: check-commit-size.sh [--ci] [BASE [TIP]]"
tip=$(git rev-parse -q --verify "${2:-HEAD}^{commit}") || fail "unknown commit ${2:-HEAD}"
base=${1:-}
if is_zero "$base"; then base=$(fallback_base "$tip")
elif ! git cat-file -e "$base^{commit}" 2>/dev/null; then
  fail "base commit $base is not in this clone; fetch it (in CI, check out with fetch-depth: 0)"
fi

git show "$tip:$config" 2>/dev/null > "$tmp/cfg" || : > "$tmp/cfg"
parse_rules "$tip:$config" < "$tmp/cfg" > "$tmp/rules"

status=0
if grep -q '^X ' "$tmp/rules"; then sed -n 's/^X /[FAIL] /p' "$tmp/rules"; status=1; fi

# A promotion (a pull request into the default branch, in a repository with a staging branch)
# skips commits already on origin/staging: they passed this check on their way into staging.
skip=""
if [ -n "${COMMIT_SIZE_BASE_REF:-}" ] && [ "$COMMIT_SIZE_BASE_REF" = "${COMMIT_SIZE_DEFAULT_BRANCH:-}" ] &&
  git rev-parse -q --verify "refs/remotes/origin/staging^{commit}" >/dev/null; then
  skip=refs/remotes/origin/staging
  echo "commit-size: promotion into $COMMIT_SIZE_BASE_REF: commits already on origin/staging are skipped"
fi
git rev-list --reverse ${base:+"^$base"} ${skip:+"^$skip"} "$tip" > "$tmp/commits"
over=0 count=0
while IFS= read -r c; do
  count=$((count + 1))
  subject=$(git log -1 --format=%s "$c")
  short=$(git rev-parse --short "$c")
  diff_of "$c" > "$tmp/d"
  if [ "$(tr -cd '\n' < "$tmp/d" | wc -c)" -gt 0 ]; then
    echo "[FAIL] $short $subject: a changed path contains a newline; rename it"; status=1; continue
  fi
  tr '\0' '\n' < "$tmp/d" | classify > "$tmp/rows"
  read -r n skipped tabs < <(tally)
  if [ "$tabs" -gt 0 ]; then
    echo "[FAIL] $short $subject: $tabs changed path(s) contain a tab; rename them"; status=1; continue
  fi
  note=""; [ "$skipped" -eq 0 ] || note=" (+$skipped exempt)"
  if [ "$n" -le "$limit" ]; then
    echo "commit-size: $short $n changed lines$note: $subject"
  elif [ "${COMMIT_SIZE_EXCEPTION:-}" = true ]; then
    echo "commit-size: allowed by the commit-size-exception label: $short $subject: $n changed lines, limit $limit"
  else
    echo "[FAIL] $short $subject: $n changed lines$note, limit $limit (split it into smaller commits)"
    over=$((over + 1)); status=1
  fi
done < "$tmp/commits"
echo "commit-size: $count commit(s) checked; a merge counts only what it adds beyond an automatic merge"
if [ "$over" -gt 0 ]; then
  echo "commit-size: $over commit(s) over $limit changed lines. Split each into reviewable commits" \
    "(git rebase -i, then edit and git reset HEAD~ to re-commit it in parts). Generated or vendored" \
    "paths go in .commit-size as exempt <glob>. A reviewer can allow it instead by putting the" \
    "commit-size-exception label on the pull request, then closing and reopening it."
fi

# CI: .commit-size may only shrink compared with BASE.
if [ "$ci" -eq 1 ]; then
  if [ -n "$base" ]; then git show "$base:$config" 2>/dev/null || true; fi |
    parse_rules "$base:$config" | grep '^E ' > "$tmp/old-rules" || true
  awk 'FILENAME == ARGV[1] { old[$2] = 1; next } $1 == "E" && !($2 in old) { print "new exempt line " $3 }' \
    "$tmp/old-rules" "$tmp/rules" > "$tmp/added"
  if [ -s "$tmp/added" ]; then
    if [ "${COMMIT_SIZE_EXCEPTION:-}" = true ]; then
      sed 's/^/commit-size: allowed by the commit-size-exception label: /' "$tmp/added"
    else
      sed 's/^/[FAIL] .commit-size: /' "$tmp/added"
      echo "commit-size: .commit-size may only shrink. A reviewer allows an addition by" \
        "putting the commit-size-exception label on the pull request, then closing and reopening it."
      status=1
    fi
  fi
fi

[ "$status" -eq 0 ] && echo "commit-size: ok" || echo "commit-size: see .commit-size and scripts/check-commit-size.sh"
exit "$status"
