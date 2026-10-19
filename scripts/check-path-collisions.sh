#!/usr/bin/env bash
# Org-wide check that no two tracked paths collide on a case-insensitive filesystem (macOS APFS
# and HFS+, Windows NTFS) or a Unicode-normalising one (macOS). Needs bash, git and python3 (standard library
# only: bash and coreutils cannot normalise Unicode). Never skips.
#   check-path-collisions.sh          the index (git ls-files)
#   check-path-collisions.sh TREEISH  the tree of a commit, e.g. a pull request merge
# Every path and each of its parent directories is case-folded per character (the one-character
# fold, else lower case, so ς, σ and Σ match but ß stays apart from SS) and put in NFC; two
# different names with the same fold collide (Foo/x and foo/y, file A and directory a/, NFC and
# NFD spellings of the same accented name). Only the shallowest collision is reported: when two
# directories collide, the files inside them are not listed again. Exits 1 on any collision, 2
# when the check cannot run.
set -euo pipefail
export LC_ALL=C

fail() { echo "path-collisions: $*" >&2; exit 2; }
[ $# -le 1 ] || fail "usage: check-path-collisions.sh [TREEISH]"
command -v python3 >/dev/null || fail "python3 is required"
git rev-parse --git-dir >/dev/null 2>&1 || fail "not in a git repository"

if [ $# -eq 1 ]; then
  git rev-parse -q --verify "$1^{tree}" >/dev/null || fail "not a commit or tree: $1"
  list() { git ls-tree -r -z --name-only --full-tree "$1"; }
else
  cd "$(git rev-parse --show-toplevel)"
  list() { git ls-files -z --cached; }
fi

# The fold, the grouping and the report. Paths arrive NUL-separated; bytes that are not UTF-8
# pass through unchanged (surrogateescape) and are compared as given.
# shellcheck disable=SC2016 # Python source
fold='
import sys, unicodedata
def low(s):
    return "".join(c.casefold() if len(c.casefold()) == 1 else c.lower() for c in s)
def fold(s):
    return unicodedata.normalize("NFC", low(unicodedata.normalize("NFC", s)))
raw = sys.stdin.buffer.read().split(b"\0")
names = {}  # folded path -> set of original names; a directory keeps a trailing slash
for b in raw:
    if not b:
        continue
    parts = b.decode("utf-8", "surrogateescape").split("/")
    for i in range(1, len(parts) + 1):
        orig = "/".join(parts[:i]) + ("/" if i < len(parts) else "")
        names.setdefault(fold(orig.rstrip("/")), set()).add(orig)
bad = {k for k, v in names.items() if len(v) > 1}
def shown(s):
    s = s.encode("utf-8", "surrogateescape").decode("utf-8", "replace")
    return s if s.isprintable() else ascii(s)
groups = []
for k in bad:
    parent = k.rpartition("/")[0]
    hidden = False
    while parent:
        if parent in bad:
            hidden = True
            break
        parent = parent.rpartition("/")[0]
    if not hidden:
        groups.append(sorted(names[k]))
for g in sorted(groups):
    print("  " + "  ".join(shown(n) for n in g))
sys.exit(3 if groups else 0)
'

status=0
out=$(list "$@" | python3 -I -c "$fold") || status=$?
case $status in
  0) echo "path-collisions: ok, no tracked paths collide" ;;
  3)
    status=1
    echo "path-collisions: these tracked paths differ only in case (colliding on macOS and Windows) or"
    echo "Unicode normalisation (colliding on macOS), where a clone keeps one of each group and loses the rest."
    echo "Rename or remove all but one name in each group (a trailing / marks a directory):"
    printf '%s\n' "$out"
    ;;
  *) fail "the check failed to run" ;;
esac
exit "$status"
