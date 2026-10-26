# Shared setup and helpers for the file length tests (sourced, not run). Each case runs in a
# throwaway git repo made by repo(); expect() tallies results into passed and failed.
here=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 GIT_AUTHOR_NAME=t GIT_COMMITTER_NAME=t \
  GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_EMAIL=t@example.com
unset FILE_LENGTHS_EXCEPTION FILE_LENGTHS_DEFAULT_BRANCH FILE_LENGTHS_HEAD_REF FILE_LENGTHS_HEAD_REPO FILE_LENGTHS_REPO
passed=0 failed=0 zero=0000000000000000000000000000000000000000

repo() { # fresh repo with the check and hooks committed on master
  cd "$work" && rm -rf "$1" "$1.git" && git init -q -b master "$1" && cd "$1"
  mkdir scripts .githooks && cp "$here/scripts/check-file-lengths.sh" scripts/
  cp "$here/.githooks/pre-commit" "$here/.githooks/pre-push" .githooks/
  mkdir .githooks/org && cp "$here/.githooks/org/pre-push-guards.sh" .githooks/org/
  git config core.hooksPath .githooks && save init
}
remote() { git init -q --bare "../$1.git" && git remote add origin "../$1.git" && git push -q -u origin master >/dev/null 2>&1; }
body() { awk -v n="$1" 'BEGIN { for (i = 1; i <= n; i++) print "x" }'; }
lines() { mkdir -p "$(dirname "$2")"; body "$1" > "$2"; }
cfg() { printf '%s\n' "$@" > .file-lengths; }
save() { git add -A && git commit -q --no-verify -m "${1:-c}"; }
run() { out=$("$@" 2>&1) && rc=0 || rc=$?; }
check() { run scripts/check-file-lengths.sh "$@"; }
expect() { # expect NAME RC [PATTERN that must appear in the output]
  if [ "$rc" = "$2" ] && { [ -z "${3:-}" ] || printf '%s\n' "$out" | grep -q -e "$3"; }; then
    passed=$((passed + 1))
  else
    failed=$((failed + 1)); echo "not ok: $1 (exit $rc, wanted $2${3:+, /$3/})"; printf '%s\n' "$out" | sed 's/^/    /'
  fi
}
