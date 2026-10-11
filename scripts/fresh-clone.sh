#!/usr/bin/env bash
# Fetches the pull request into a new, empty repository for a required workflow, instead of
# trusting the runner's workspace. The self-hosted runners are shared and keep each repository's
# workspace between jobs, so another job may leave it blob-less (filtered), shallow or otherwise
# altered; actions/checkout reuses such a .git, a later read needs a blob the job can no longer
# fetch, and the check fails. Needs only bash and git (2.32 or later).
#   fresh-clone.sh DEST URL [--depth N] [--checkout COMMIT] REFSPEC...
# DEST is removed and created afresh, with origin at URL, then REFSPECs are fetched in one go:
# never with a filter, with full history unless --depth limits it. --checkout detaches HEAD at
# COMMIT with its files; without it there is no working tree checkout. FRESH_CLONE_TOKEN, when
# set, authenticates that one fetch through a header exported only for it, so it is never
# written to .git/config or any process's command line. The runner user's global and system git config are ignored.
set -euo pipefail
export LC_ALL=C GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 GIT_TERMINAL_PROMPT=0
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES \
  GIT_CONFIG_PARAMETERS GIT_CONFIG_COUNT
fail() { echo "fresh-clone: $*" >&2; exit 2; }
usage="usage: fresh-clone.sh DEST URL [--depth N] [--checkout COMMIT] REFSPEC..."

[ $# -ge 2 ] || fail "$usage"
dest=$1 url=$2; shift 2
depth=() commit=""
while [ $# -gt 0 ]; do
  case $1 in
    --depth) [[ ${2:-} =~ ^[1-9][0-9]*$ ]] || fail "--depth needs a positive number"; depth=(--depth "$2"); shift 2 ;;
    --checkout) [ -n "${2:-}" ] || fail "$usage"; commit=$2; shift 2 ;;
    -*) fail "$usage" ;;
    *) break ;;
  esac
done
[ $# -gt 0 ] || fail "$usage"

rm -rf "$dest"
git init -q "$dest"
git -C "$dest" remote add origin "$url"
# The header is exported only around the fetch, never passed as an argument: the runners' users
# share /proc, where any process's command line is readable but its environment is not.
# printf and echo are builtins, so the token is in no command line here either.
if [ -n "${FRESH_CLONE_TOKEN:-}" ]; then
  basic=$(printf 'x-access-token:%s' "$FRESH_CLONE_TOKEN" | base64 | tr -d '\n')
  echo "::add-mask::$basic"
  export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=http.extraHeader GIT_CONFIG_VALUE_0="AUTHORIZATION: basic $basic"
fi
fetched=0
git -C "$dest" fetch --quiet --no-tags --no-recurse-submodules "${depth[@]}" origin "$@" && fetched=1
unset GIT_CONFIG_COUNT GIT_CONFIG_KEY_0 GIT_CONFIG_VALUE_0 basic
[ "$fetched" -eq 1 ] || fail "could not fetch $* from $url"
if [ -n "$commit" ]; then git -C "$dest" checkout --quiet --detach "$commit" -- ||
  fail "could not check out $commit"; fi

# The new repository must be complete: no promisor remote or filter, and full history unless
# --depth asked for less (a short history fetched with --depth is not shallow).
if git -C "$dest" config --get-regexp '^(remote\..*\.(promisor|partialclonefilter)|extensions\.partialclone)$'; then
  fail "the new clone is a partial clone"
fi
if [ ${#depth[@]} -eq 0 ] && [ "$(git -C "$dest" rev-parse --is-shallow-repository)" != false ]; then
  fail "the new clone is shallow"
fi
echo "fresh-clone: fetched $* into $dest${depth[*]:+ (${depth[*]})}${commit:+, checked out $commit}"
