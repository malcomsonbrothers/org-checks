#!/usr/bin/env bash
# Org-wide refusal of implementation stubs. Needs only bash, git, grep, awk and xargs. Never skips, and
# nothing can be exempted: no config file, no label.
#   check-no-stubs.sh   tracked and untracked files in the working tree (in CI, the pull request's merge)
# A stub is a Rust todo!() or unimplemented!() call in a .rs file, or the stub marker in any text file but
# Markdown (md, markdown, mdx), where docs describe it. The marker is TODO and STUB joined by a hyphen; this
# file spells it in two parts so it never carries it. A Rust match after // or /* on its line is a comment
# that only names the macro, so it is not a stub. Binaries (a NUL byte), symlinks and submodules are skipped.
set -euo pipefail
export LC_ALL=C

# What counts as a stub, fixed org-wide: no repository can change it.
marker='TODO''-STUB'
rust='(^|[^A-Za-z0-9_])(todo|unimplemented)![ '$'\t'']*[({[]'
docs="md markdown mdx"

[ $# -eq 0 ] || { echo "usage: check-no-stubs.sh" >&2; exit 2; }
cd "$(git rev-parse --show-toplevel)"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
ext='function ext(p) { sub(/.*\//, "", p); sub(/^\.+/, "", p); if (p !~ /\.[^.]+$/) return ""; sub(/.*\./, "", p); return tolower(p) }'

# Every regular file, split into Rust files and files that may carry the marker.
git ls-files -z --cached --others --exclude-standard | tr '\0' '\n' | sort -u | while IFS= read -r f; do
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
  echo "no-stubs: implement each stub before it reaches a protected branch; stubs belong on swarm and item branches only."
  echo "no-stubs: see scripts/check-no-stubs.sh"
  exit 1
fi
echo "no-stubs: ok"
