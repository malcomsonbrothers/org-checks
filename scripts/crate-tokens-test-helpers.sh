# Shared setup and helpers for the crate-tokens tests (sourced, not run). Each case runs in a
# throwaway git repo made by repo(); expect() and same() tally results into passed and failed.
here=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 GIT_AUTHOR_NAME=t GIT_COMMITTER_NAME=t \
  GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_EMAIL=t@example.com
unset CRATE_TOKENS_EXCEPTION CRATE_TOKENS_DEFAULT_BRANCH CRATE_TOKENS_HEAD_REF CRATE_TOKENS_HEAD_REPO CRATE_TOKENS_REPO
passed=0 failed=0

repo() { # fresh repo on master with one commit
  cd "$work" && rm -rf "${work:?}/$1" && git init -q -b master "$1" && cd "$1"
  printf 'x\n' > README.md && save init
}
crate() { mkdir -p "$1" && printf '[package]\nname = "%s"\n' "${1##*/}" > "$1/Cargo.toml"; }
pkg() { mkdir -p "$1" && printf '{ "name": "%s" }\n' "${1##*/}" > "$1/package.json"; }
big() { mkdir -p "$(dirname "$1")" && seq 1 "${2:-40000}" > "$1"; } # well over 50k tokens
small() { mkdir -p "$(dirname "$1")" && printf 'fn main() {}\n' > "$1"; }
cfg() { printf '%s\n' "$@" > .crate-tokens; }
save() { git add -A && git commit -q -m "${1:-c}"; }
run() { out=$("$@" 2>&1) && rc=0 || rc=$?; }
check() { run uv run --no-config --quiet --script "$here/scripts/check-crate-tokens.py" "$@"; }
units() { check --report; printf '%s\n' "$out" | awk 'NR > 1 { print $4 }' | sort | tr '\n' ' '; }
tokens() { check --report; printf '%s\n' "$out" | awk -v u="$1" '$4 == u { print $1 }'; }
expect() { # expect NAME RC [PATTERN that must appear in the output]
  if [ "$rc" = "$2" ] && { [ -z "${3:-}" ] || printf '%s\n' "$out" | grep -q -e "$3"; }; then
    passed=$((passed + 1))
  else
    failed=$((failed + 1)); echo "not ok: $1 (exit $rc, wanted $2${3:+, /$3/})"; printf '%s\n' "$out" | sed 's/^/    /'
  fi
}
same() { # same NAME GOT WANT
  if [ "$2" = "$3" ]; then passed=$((passed + 1)); else
    failed=$((failed + 1)); echo "not ok: $1"; echo "    got:  $2"; echo "    want: $3"
  fi
}
