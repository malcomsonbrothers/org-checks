# Shared setup and helpers for the commit-size tests (sourced, not run). Each case runs in a
# throwaway git repo made by repo(); expect() tallies results into passed and failed.
here=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 GIT_AUTHOR_NAME=t GIT_COMMITTER_NAME=t \
  GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_EMAIL=t@example.com
unset COMMIT_SIZE_EXCEPTION COMMIT_SIZE_DEFAULT_BRANCH COMMIT_SIZE_BASE_REF COMMIT_SIZE_HEAD_REF \
  COMMIT_SIZE_HEAD_REPO COMMIT_SIZE_REPO
passed=0 failed=0 zero=0000000000000000000000000000000000000000

repo() { # fresh repo with one small commit on master, work continuing on branch pr
  cd "$work" && rm -rf "$1" && git init -q -b master "$1" && cd "$1"
  echo init > README && save init && git checkout -q -b pr
}
body() { awk -v n="$1" -v t="${2:-x}" 'BEGIN { for (i = 1; i <= n; i++) print t i }'; }
lines() { mkdir -p "$(dirname "$2")"; body "$1" "${3:-x}" > "$2"; }
cfg() { printf '%s\n' "$@" > .commit-size; }
save() { git add -A && git commit -q -m "${1:-c}"; }
run() { out=$("$@" 2>&1) && rc=0 || rc=$?; }
check() { run "$here/scripts/check-commit-size.sh" "$@"; }
expect() { # expect NAME RC [PATTERN that must appear in the output]
  if [ "$rc" = "$2" ] && { [ -z "${3:-}" ] || grep -q -e "$3" <<<"$out"; }; then
    passed=$((passed + 1))
  else
    failed=$((failed + 1)); echo "not ok: $1 (exit $rc, wanted $2${3:+, /$3/})"; printf '%s\n' "$out" | sed 's/^/    /'
  fi
}
