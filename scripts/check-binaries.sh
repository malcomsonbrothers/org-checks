#!/usr/bin/env bash
# Org-wide no-binaries check. Needs only bash, git, awk, od and grep. Binaries, media, 3D and
# Blender files, model weights, archives, compiled code, databases, documents, secrets and junk
# do not belong in git. Fails when any commit in BASE..TIP adds, modifies or renames into place
# (rebase merges keep every commit, so a file added and then deleted still fails):
#   1. any binary (a NUL byte in the first 8 KB, git's own test) or media by its first bytes
#   2. a denied file name or folder from the org lists, even when it is text or a Git LFS pointer
#   3. any file over 1 MB
# Small favicons and app icons with image content pass; anything else needs a row. Never skips.
#   check-binaries.sh [BASE [TIP]]   commits in BASE..TIP (TIP defaults to HEAD)
#   check-binaries.sh --ci BASE TIP  the same, and .binary-allow may not add rows compared with
#                                    BASE or the default branch tip. BINARIES_EXCEPTION=true (the
#                                    PR label) allows new rows.
# The org lists are data: BINARIES_LISTS, else lists/no-binaries.txt beside this script, else the
# copy on org-checks master. Commits already on the default branch are skipped: they passed in
# their own pull request. A merge counts only files that differ from every parent. A missing BASE
# falls back to the merge-base with the default branch (BINARIES_DEFAULT_BRANCH, else origin/HEAD,
# origin/main or origin/master); with none, every commit reachable from TIP is checked.
# .binary-allow lines, read at TIP (# starts a comment):
#   allow <glob> <reason...>    the path may be anything above
#   exempt <glob> <reason...>   a generated file (OpenAPI JSON, say) may be over 1 MB
# Globs: * is one path segment, ** any depth; other characters are literal. Each
# projects/<p>/.binary-allow adds rows relative to its folder.
set -euo pipefail
export LC_ALL=C

size_max=1048576 icon_max=65536 svg_max=20480
empty_tree=4b825dc642cb6eb9a060e54bf8d69288fbee4904
raw_lists=https://raw.githubusercontent.com/malcomsonbrothers/org-checks/master/scripts/lists/no-binaries.txt

here=$(cd "$(dirname "${BASH_SOURCE[0]:-.}")" 2>/dev/null && pwd || :)
cd "$(git rev-parse --show-toplevel)"
config=.binary-allow
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
fail() { echo "no-binaries: $*" >&2; exit 2; }
usage="usage: check-binaries.sh [--ci] [BASE [TIP]]"

lists=${BINARIES_LISTS:-$here/lists/no-binaries.txt}
if [ ! -f "$lists" ]; then
  [ -z "${BINARIES_LISTS:-}" ] || fail "BINARIES_LISTS names no file: $lists"
  curl -fsSL "$raw_lists" -o "$tmp/lists" || fail "no lists/no-binaries.txt beside the script and could not fetch $raw_lists"
  lists=$tmp/lists
fi

default_branch() {
  local b d=${BINARIES_DEFAULT_BRANCH:-}
  for b in ${d:+"origin/$d" "$d"} "$(git symbolic-ref -q --short refs/remotes/origin/HEAD || :)" \
    origin/main origin/master; do
    [ -n "$b" ] && git rev-parse -q --verify "$b^{commit}" >/dev/null && { echo "$b"; return; }
  done
  return 0
}

# Turns a .binary-allow text (stdin) at path CFG in commit REF, with globs relative to folder PRE,
# into rule records:   A|E regex glob config (allow or exempt row) | X error
parse_rules() {
  awk -v cfg="$1" -v pre="${2:-}" -v ref="${3:-}" '
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
    { sub(/\r$/, "") }
    /^[ \t]*(#|$)/ { next }
    ($1 == "allow" || $1 == "exempt") && NF >= 3 { print ($1 == "allow" ? "A " : "E ") glob_re(pre $2) " " $2 " " cfg; next }
    { print "X " ref ":" cfg ":" NR ": unknown or malformed line (only allow or exempt <glob> <reason>): " $0 }'
}

# Prints the rule records of .binary-allow and each projects/<p>/.binary-allow at commit REF.
rules_at() {
  local f
  git ls-tree -r --name-only "$1" -- "$config" projects | awk '/^(projects\/[A-Za-z0-9_-][A-Za-z0-9._-]*\/)?\.binary-allow$/' |
    while IFS= read -r f; do git show "$1:$f" | parse_rules "$f" "${f%"$config"}" "$1"; done
}

ci=0
if [ "${1:-}" = --ci ]; then ci=1; shift; fi
case ${1:-} in -*) fail "$usage" ;; esac
[ $# -le 2 ] || fail "$usage"
[ "$ci" -eq 0 ] || [ $# -eq 2 ] || fail "$usage"
tip=$(git rev-parse -q --verify "${2:-HEAD}^{commit}") || fail "unknown commit ${2:-HEAD}"
base=${1:-}
if [ -z "$base" ]; then d=$(default_branch); base=${d:+$(git merge-base "$tip" "$d" || :)}
else git cat-file -e "$base^{commit}" 2>/dev/null || fail "base commit $base is not in this clone; fetch it"
  [ "$ci" -eq 1 ] || base=$(git merge-base "$base" "$tip" || :)
fi

rules_at "$tip" > "$tmp/rules"
status=0
if grep -q '^X ' "$tmp/rules"; then sed -n 's/^X /[FAIL] /p' "$tmp/rules"; status=1; fi

# Prints each added, modified, copied or renamed regular file from tree-ish FROM to commit TO as
# sha TAB path (renames detected, so a move counts at its new path; a mode-only change and
# deletions count nothing), and WEIRD for a path with a tab or newline.
changes() {
  local head omode nmode osha nsha st path
  git diff-tree -r -M --no-abbrev --raw -z "$1" "$2" > "$tmp/raw"
  while IFS= read -r -d '' head; do
    read -r omode nmode osha nsha st <<< "${head#:}"
    IFS= read -r -d '' path
    case $st in R* | C*) IFS= read -r -d '' path ;; esac
    case $st in D*) continue ;; esac
    case $nmode in 100644 | 100755) ;; *) continue ;; esac
    [ "$osha" != "$nsha" ] || [ "$omode" = 000000 ] || case $st in R* | C*) ;; *) continue ;; esac
    if [[ $path == *$'\t'* || $path == *$'\n'* ]]; then echo WEIRD; continue; fi
    printf '%s\t%s\n' "$nsha" "$path"
  done < "$tmp/raw"
}

# Every commit in BASE..TIP not already on the default branch; a merge keeps only the files that
# differ from every parent (what it adds beyond its parents), a root commit diffs the empty tree.
dflt=$(default_branch)
git rev-list --reverse ${base:+"^$base"} ${dflt:+"^$dflt"} "$tip" > "$tmp/commits"
: > "$tmp/all"; commits=0
while IFS= read -r c; do
  commits=$((commits + 1))
  read -r -a ps < <(git rev-list --parents -n 1 "$c")
  [ "${#ps[@]}" -gt 1 ] || ps+=("$empty_tree")
  changes "${ps[1]}" "$c" > "$tmp/c"
  for p in "${ps[@]:2}"; do
    changes "$p" "$c" > "$tmp/p"
    awk 'FILENAME == ARGV[1] { a[$0] = 1; next } $0 in a' "$tmp/p" "$tmp/c" > "$tmp/both"; mv "$tmp/both" "$tmp/c"
  done
  cat "$tmp/c" >> "$tmp/all"
done < "$tmp/commits"
weird=$(grep -c '^WEIRD$' "$tmp/all" || :)
grep -v '^WEIRD$' "$tmp/all" | sort -u > "$tmp/changed" || :
if [ "$weird" -gt 0 ]; then echo "[FAIL] $weird changed path(s) contain a tab or newline; rename them"; status=1; fi

# Sizes in one call, then each file's first 8 KB: a NUL byte makes it binary, the first 64 bytes
# go to the magic patterns, and a token file is searched for a literal token (never printed).
# Records: sha TAB size TAB nul TAB hex TAB token TAB path.
cut -f1 "$tmp/changed" | git cat-file --batch-check='%(objectname) %(objectsize)' > "$tmp/sizes"
awk -F '\t' 'FILENAME == ARGV[1] { split($0, w, " "); n[w[1]] = w[2]; next } { print $1 "\t" n[$1] + 0 "\t" $2 }' \
  "$tmp/sizes" "$tmp/changed" > "$tmp/sized"
tokenfiles=" $(awk '$1 == "tokenfile" { printf "%s ", $2 }' "$lists")"
shopt -s nocasematch
: > "$tmp/files"; count=0
while IFS=$'\t' read -r sha n path; do
  count=$((count + 1))
  hx=$( { git cat-file blob "$sha" 2>/dev/null || :; } | od -An -tx1 -N8000 | tr -d '\n') || :
  nul=0; [[ $hx != *" 00"* ]] || nul=1
  h=${hx// /}; h=${h:0:128}
  tok=0
  if [[ $tokenfiles == *" ${path##*/} "* ]] && { git cat-file blob "$sha" || :; } |
    grep -Eiq '(_authtoken|_auth|_password|password|token)[[:space:]]*[=:][[:space:]]*[^$[:space:]]'; then tok=1; fi
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$sha" "$n" "$nul" "$h" "$tok" "$path" >> "$tmp/files"
done < "$tmp/sized"
shopt -u nocasematch
lfs=$(printf 'version https://git-lfs.github.com/spec/' | od -An -tx1 | tr -d ' \n')

# Classifies each file against the org lists and the repository's rows. Prints one line per file:
#   [FAIL] path: category: description (detail) | no-binaries: path: why it passes
# and a closing "#" line of failure counts by category.
awk -F '\t' -v lists="$lists" -v rules="$tmp/rules" -v lfs="$lfs" -v smax="$size_max" -v imax="$icon_max" -v svgmax="$svg_max" '
  function re(g, hex,   r, c, i) { r = ""
    for (i = 1; i <= length(g); i++) { c = substr(g, i, 1)
      if (c == "*") r = r ".*"; else if (c == "?") r = r "."
      else if (c == "[" || c == "]") r = r c
      else if (index("\\.()+{}|^$", c)) r = r "\\" c; else r = r c }
    return "^" r "$" }
  BEGIN {
    while ((getline l < lists) > 0) { split(l, w, " ")
      if (w[1] == "about") { d = l; sub(/^about [^ ]+ /, "", d); about[w[2]] = d }
      else if (w[1] == "deny") { nd++; dre[nd] = re(w[3]); dcat[nd] = w[2] }
      else if (w[1] == "keep") keep[re(w[2])] = 1
      else if (w[1] == "dir") { nf++; fre[nf] = re(w[3]); fcat[nf] = w[2] }
      else if (w[1] == "magic") { nm++; m = w[3]; sub(/\*$/, "", m); mre[nm] = re(m); sub(/\$$/, "", mre[nm]); mcat[nm] = w[2]
        d = l; sub(/^magic [^ ]+ [^ ]+ /, "", d); mname[nm] = d }
      else if (w[1] == "icon") icon[re(w[2])] = 1
      else if (w[1] == "icondir") icondir[re(w[2])] = 1
      else if (w[1] == "iconext") iconext[w[2]] = 1 }
    while ((getline l < rules) > 0) { split(l, w, " "); if (w[1] == "A") allow[w[2]] = w[4] ": allow " w[3]
      else if (w[1] == "E") exempt[w[2]] = w[4] ": exempt " w[3] } }
  function row(p, set,   r) { for (r in set) if (p ~ r) return set[r]; return "" }
  function out(p, cat, detail) { if ((p, cat) in done) return; done[p, cat] = 1; bycat[cat]++
    print "[FAIL] " p ": " cat ": " about[cat] (detail != "" ? " (" detail ")" : "") }
  function pass(p, why) { if (!(p in passed)) print "no-binaries: " p ": " why; passed[p] = 1 }
  { sha = $1; n = $2 + 0; nul = $3; h = $4; tok = $5; p = $6; lp = tolower(p)
    k = split(lp, seg, "/"); name = seg[k]; on = p; sub(/.*\//, "", on); ext = name ~ /^[^.].*\.[^.]+$/ ? name : ""; sub(/.*\./, "", ext)
    isl = index(h, lfs) == 1; mc = ""
    for (i = 1; i <= nm && !isl; i++) if (h ~ mre[i]) { mc = mcat[i]; mn = mname[i]; break }
    why = row(p, allow); if (why != "") { pass(p, "allowed by " why); next }
    cat = ""; detail = ""
    for (j = 1; j < k && cat == ""; j++) for (i = 1; i <= nf; i++) if (seg[j] ~ fre[i]) { cat = fcat[i]; detail = "under " seg[j] "/"; break }
    isicon = 0; for (r in icon) if (name ~ r) isicon = 1; for (j = 1; j < k; j++) for (r in icondir) if (seg[j] ~ r) isicon = 1
    if (cat == "" && isicon && (ext in iconext) && !isl && n <= imax && (mc == "" || mc == "image") && !(ext == "svg" && nul)) {
      if (!(p in passed)) icons++; pass(p, "favicon or app icon, " n " bytes"); next }
    kept = 0; for (r in keep) if (name ~ r) kept = 1
    for (i = 1; i <= nd && cat == "" && !kept; i++) if (name ~ dre[i]) { cat = dcat[i]; detail = on (mc != "" ? ", " mn " content" : "") }
    if (cat == "" && tok) { cat = "secret"; detail = on " holding a token" }
    if (cat == "" && isl) cat = "lfs"
    if (cat == "" && mc != "") { cat = mc == "image" ? "image" : mc; detail = mn " content" }
    if (cat == "" && nul) cat = "binary"
    if (cat == "" && ext == "svg" && n > svgmax) { cat = "media"; detail = "an SVG over 20 KB, " n " bytes" }
    if (cat != "") out(p, cat, detail)
    if (n > smax) { why = row(p, exempt); if (why != "") pass(p, "size allowed by " why); else out(p, "size", n " bytes") } }
  END { for (c in bycat) { s = s " " c " " bycat[c]; tot += bycat[c] }; print "# " tot + 0 " " icons + 0 s }' "$tmp/files" > "$tmp/out"
grep -v '^# ' "$tmp/out" || :
read -r _ nfail icons bycat < <(grep '^# ' "$tmp/out")
echo "no-binaries: $commits commit(s), $count changed file(s) checked, $icons favicon or app icon(s)"
if [ "$nfail" -gt 0 ]; then status=1
  echo "no-binaries: $nfail failure(s) by category:${bycat:+ $bycat}"
  echo "no-binaries: binaries, media and the other listed files do not belong in git. Put user-facing" \
    "assets in R2 (served from the CDN), test fixtures in the local test corpus, secrets in SSM, and" \
    "build output in .gitignore. Favicons and app icons up to 64 KB pass as they are. For a file that" \
    "truly must live in the repository, add 'allow <path or glob> <reason>' (or 'exempt' for a" \
    "generated file over 1 MB) to .binary-allow at the repository root (or projects/<p>/.binary-allow)" \
    "and ask a reviewer to put the binary-exception label on the pull request, then close and reopen" \
    "it so this check re-runs. Remove a committed secret and rotate it; deleting it does not unpublish it."
fi

# CI: each .binary-allow may only shrink against BASE; rows the default branch tip has passed there.
if [ "$ci" -eq 1 ]; then
  for r in "$base" "$dflt"; do [ -z "$r" ] || rules_at "$r"; done | grep '^[AE] ' > "$tmp/old-rules" || true
  awk 'FILENAME == ARGV[1] { old[$1 " " $2 " " $4] = 1; next }
    $1 ~ /^[AE]$/ && !(($1 " " $2 " " $4) in old) { print $4 " new " ($1 == "A" ? "allow" : "exempt") " row " $3 }' \
    "$tmp/old-rules" "$tmp/rules" > "$tmp/added"
  if [ -s "$tmp/added" ]; then
    if [ "${BINARIES_EXCEPTION:-}" = true ]; then
      sed 's/^[^ ]* /no-binaries: allowed by the binary-exception label: /' "$tmp/added"
    else
      sed 's/^\([^ ]*\) /[FAIL] \1: /' "$tmp/added"
      echo "no-binaries: .binary-allow may only shrink. A reviewer allows a new row by putting the" \
        "binary-exception label on the pull request, then closing and reopening it."
      status=1
    fi
  fi
fi

[ "$status" -eq 0 ] && echo "no-binaries: ok" || echo "no-binaries: see .binary-allow and scripts/check-binaries.sh"
exit "$status"
