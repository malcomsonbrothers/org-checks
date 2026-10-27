#!/usr/bin/env bash
# Org-wide media check. Needs only bash, git, awk and od. Images, video and audio belong in R2
# (user-facing assets) or a local test corpus (fixtures), not in git. Fails when the change adds,
# modifies or renames into place a media file: by extension, by content (magic bytes, so a renamed
# extension is caught) or as a Git LFS pointer (any LFS file). SVGs count only above 20 KB. Small
# favicons and app icons pass without config; anything else needs an allow row. Never skips.
#   check-media.sh [BASE [TIP]]   files changed from the merge-base of BASE and TIP (TIP defaults to
#                                 HEAD) to TIP
#   check-media.sh --ci BASE TIP  files changed from BASE to TIP (the merge commit), and .media-allow
#                                 may not add rows compared with BASE or the default branch tip.
#                                 MEDIA_EXCEPTION=true (the PR label) allows new rows.
# A missing BASE falls back to the merge-base with the default branch (MEDIA_DEFAULT_BRANCH, else
# origin/HEAD, origin/main or origin/master); with none, every file at TIP is checked.
# .media-allow lines, read at TIP (# starts a comment):   allow <glob> <reason...>
# Globs: * is one path segment, ** any depth; other characters are literal. Each
# projects/<p>/.media-allow adds allow rows relative to its folder.
set -euo pipefail
export LC_ALL=C

# Org lists, fixed here: no repository can change them.
images=" png jpg jpeg webp gif avif heic heif bmp tif tiff ico psd "
video=" mp4 mov webm mkv avi m4v "
audio=" wav mp3 m4a aac ogg oga flac opus "
svg_max=20480 icon_max=65536
empty_tree=4b825dc642cb6eb9a060e54bf8d69288fbee4904

cd "$(git rev-parse --show-toplevel)"
config=.media-allow
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
fail() { echo "no-media: $*" >&2; exit 2; }
usage="usage: check-media.sh [--ci] [BASE [TIP]]"

default_branch() {
  local b d=${MEDIA_DEFAULT_BRANCH:-}
  for b in ${d:+"origin/$d" "$d"} "$(git symbolic-ref -q --short refs/remotes/origin/HEAD || :)" \
    origin/main origin/master; do
    [ -n "$b" ] && git rev-parse -q --verify "$b^{commit}" >/dev/null && { echo "$b"; return; }
  done
  return 0
}

# Turns a .media-allow text (stdin) at path CFG in commit REF, with globs relative to folder PRE,
# into rule records:   A regex glob config (allow row) | X error
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
    $1 == "allow" && NF >= 3 { print "A " glob_re(pre $2) " " $2 " " cfg; next }
    { print "X " ref ":" cfg ":" NR ": unknown or malformed line (only allow <glob> <reason> is allowed): " $0 }'
}

# Prints the rule records of .media-allow and each projects/<p>/.media-allow at commit REF.
rules_at() {
  local f
  git ls-tree -r --name-only "$1" -- "$config" projects | awk '/^(projects\/[A-Za-z0-9_-][A-Za-z0-9._-]*\/)?\.media-allow$/' |
    while IFS= read -r f; do git show "$1:$f" | parse_rules "$f" "${f%"$config"}" "$1"; done
}

# Names the media format of the first bytes of a blob (lower-case hex), or nothing.
sniff() {
  case $1 in
    89504e47*) echo PNG ;; ffd8ff*) echo JPEG ;; 47494638*) echo GIF ;;
    52494646????????57454250*) echo WebP ;; 52494646????????57415645*) echo WAV ;;
    52494646????????41564920*) echo AVI ;; ????????66747970*) echo "ISO media (MP4, MOV, M4A, HEIC or AVIF)" ;;
    1a45dfa3*) echo "Matroska (MKV or WebM)" ;; 4f676753*) echo Ogg ;; 664c6143*) echo FLAC ;;
    494433*) echo "MP3 (ID3)" ;; 38425053*) echo PSD ;; 49492a00* | 4d4d002a*) echo TIFF ;;
  esac
}

# A favicon or app icon by name: favicon.*, apple-touch-icon*, apple-icon*, icon.*, icon-*,
# android-chrome-*, mstile-*, any .ico, or an image in an .appiconset folder.
icon_name() {
  local p=$1 n=${1##*/}
  case $n in favicon.* | apple-touch-icon* | apple-icon* | icon.* | icon-* | android-chrome-* | mstile-* | *.ico) return 0 ;; esac
  case $p in *.appiconset/*) return 0 ;; esac
  return 1
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
from=${base:-$empty_tree}

rules_at "$tip" > "$tmp/rules"
status=0
if grep -q '^X ' "$tmp/rules"; then sed -n 's/^X /[FAIL] /p' "$tmp/rules"; status=1; fi

# Every added, modified, copied or renamed regular file at TIP (renames detected, so a move counts
# at its new path); a mode-only change and deletions count nothing. Records: sha TAB path.
: > "$tmp/changed"; weird=0
git diff-tree -r -M --no-abbrev --raw -z "$from" "$tip" > "$tmp/raw"
while IFS= read -r -d '' head; do
  read -r omode nmode osha nsha st <<< "${head#:}"
  IFS= read -r -d '' path
  case $st in R* | C*) IFS= read -r -d '' path ;; esac
  case $st in D*) continue ;; esac
  case $nmode in 100644 | 100755) ;; *) continue ;; esac
  [ "$osha" != "$nsha" ] || [ "$omode" = 000000 ] || case $st in R* | C*) ;; *) continue ;; esac
  if [[ $path == *$'\t'* || $path == *$'\n'* ]]; then weird=$((weird + 1)); continue; fi
  printf '%s\t%s\n' "$nsha" "$path" >> "$tmp/changed"
done < "$tmp/raw"
if [ "$weird" -gt 0 ]; then echo "[FAIL] $weird changed path(s) contain a tab or newline; rename them"; status=1; fi

# Sizes in one call (records: sha TAB size TAB lower-case path), then each file's first 64 bytes.
cut -f1 "$tmp/changed" | git cat-file --batch-check='%(objectname) %(objectsize)' > "$tmp/sizes"
awk -F '\t' 'FILENAME == ARGV[1] { split($0, w, " "); n[w[1]] = w[2]; next } { print $1 "\t" n[$1] + 0 "\t" tolower($2) "\t" $2 }' \
  "$tmp/sizes" "$tmp/changed" > "$tmp/files"
lfs=$(printf 'version https://git-lfs.github.com/spec/' | od -An -tx1 | tr -d ' \n')
: > "$tmp/media"; count=0 icons=0 media=0
while IFS=$'\t' read -r sha n lower path; do
  count=$((count + 1))
  h=$( { git cat-file blob "$sha" 2>/dev/null || :; } | od -An -tx1 -N64 | tr -d ' \n') || :
  e=${lower##*/}; [[ $e == ?*.* ]] && e=${e##*.} || e=""
  kind=""
  if [[ $h == "$lfs"* ]]; then kind="a Git LFS pointer (keep media out of LFS too)"
  elif [ -n "$e" ] && [[ $images == *" $e "* ]]; then kind="an image (.$e)"
  elif [ -n "$e" ] && [[ $video == *" $e "* ]]; then kind="a video (.$e)"
  elif [ -n "$e" ] && [[ $audio == *" $e "* ]]; then kind="an audio file (.$e)"
  elif [ "$e" = svg ] && [ "$n" -gt "$svg_max" ]; then kind="an SVG over 20 KB ($n bytes)"
  elif f=$(sniff "$h") && [ -n "$f" ]; then kind="$f content under another extension"
  fi
  [ -n "$kind" ] || continue
  # Small favicons and app icons pass without config (never an LFS pointer or a disguised file).
  if [[ $kind == "an image"* || ( $e == svg && $kind == "an SVG"* ) ]] && [ "$n" -le "$icon_max" ] && icon_name "$lower"; then
    echo "no-media: $path: favicon or app icon, $n bytes"; icons=$((icons + 1)); continue
  fi
  printf '%s\t%s\n' "$path" "$kind" >> "$tmp/media"
done < "$tmp/files"

# Each media file needs an allow row in .media-allow (or projects/<p>/.media-allow).
awk -F '\t' 'FILENAME == ARGV[1] { split($0, w, " "); if (w[1] == "A") { re[w[2]] = w[4] ": allow " w[3] }; next }
  { why = ""; for (r in re) if ($1 ~ r) { why = re[r]; break }
    if (why != "") print "no-media: " $1 ": allowed by " why
    else { print "[FAIL] " $1 ": " $2; bad++ } }
  END { exit bad > 0 }' "$tmp/rules" "$tmp/media" || media=1
echo "no-media: $count changed file(s) checked, $icons favicon or app icon(s)"
if [ "$media" -eq 1 ]; then status=1
  echo "no-media: images, video and audio do not belong in git. Put user-facing assets in R2 (served" \
    "from the CDN) and test fixtures in the local test corpus, and load them from there. Favicons" \
    "and app icons up to 64 KB pass as they are. For a file that truly must live in the repository," \
    "add 'allow <path or glob> <reason>' to .media-allow at the repository root (or" \
    "projects/<p>/.media-allow) and ask a reviewer to put the media-exception label on the pull" \
    "request, then close and reopen it so this check re-runs."
fi

# CI: each .media-allow may only shrink against BASE; rows the default branch tip has passed there.
if [ "$ci" -eq 1 ]; then
  dflt=$(default_branch)
  for r in "$base" "$dflt"; do [ -z "$r" ] || rules_at "$r"; done | grep '^A ' > "$tmp/old-rules" || true
  awk 'FILENAME == ARGV[1] { old[$2 " " $4] = 1; next } $1 == "A" && !(($2 " " $4) in old) { print $4 " new allow row " $3 }' \
    "$tmp/old-rules" "$tmp/rules" > "$tmp/added"
  if [ -s "$tmp/added" ]; then
    if [ "${MEDIA_EXCEPTION:-}" = true ]; then
      sed 's/^[^ ]* /no-media: allowed by the media-exception label: /' "$tmp/added"
    else
      sed 's/^\([^ ]*\) /[FAIL] \1: /' "$tmp/added"
      echo "no-media: .media-allow may only shrink. A reviewer allows a new row by putting the" \
        "media-exception label on the pull request, then closing and reopening it."
      status=1
    fi
  fi
fi

[ "$status" -eq 0 ] && echo "no-media: ok" || echo "no-media: see .media-allow and scripts/check-media.sh"
exit "$status"
