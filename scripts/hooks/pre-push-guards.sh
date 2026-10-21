#!/usr/bin/env bash
# Org pre-push release guard, vendored by org-checks scripts/install-hooks.sh into
# .githooks/org/pre-push-guards.sh and called by .githooks/pre-push with the hook's arguments
# (remote name, URL) and stdin. Do not edit the vendored copy; re-run the installer instead.
# A push to swarm/run counts its unreleased commits: those committed since the head of
# <remote>/staging (else the remote's default branch). A push to <project>/swarm/run, where the
# pushed commit has a projects/<project>/ folder, counts against <remote>/<project>/staging.
# Rebase merges rewrite SHAs, so the committer date, not ancestry, marks what was released: the
# date of the newest non-merge commit on the release ref's first-parent chain (for a project, the
# newest such commit touching projects/<project>/). Releases land as linear commits, so merges on
# that chain (a sync of the default branch into staging) and what they bring in are not releases.
# With no such commit, the release ref's head counts.
# Warns at 80, refuses at 150.
# A repo's .release-guard (read at the pushed commit) may lower either: "warn N", "refuse N";
# for <project>/swarm/run, so may projects/<project>/.release-guard.
# Uses only refs git already has: no network.
set -euo pipefail
export LC_ALL=C

warn=80 refuse=150
remote=${1:-origin}
default=$(git symbolic-ref -q "refs/remotes/$remote/HEAD" || :)

status=0
while read -r _local_ref local_sha remote_ref _remote_sha; do
  case $remote_ref in
    refs/heads/swarm/run) p="" ;;
    refs/heads/*/swarm/run) p=${remote_ref#refs/heads/}; p=${p%/swarm/run}; case $p in */*) continue ;; esac ;;
    *) continue ;;
  esac
  case $local_sha in *[!0]*) ;; *) continue ;; esac # deleting swarm/run
  if [ -n "$p" ] && [ "$(git cat-file -t "$local_sha:projects/$p" 2>/dev/null)" != tree ]; then continue; fi
  run=${p:+$p/}swarm/run staging=${p:+$p/}staging
  git rev-parse -q --verify "refs/remotes/$remote/$run^{commit}" >/dev/null || continue
  release=""
  for c in "refs/remotes/$remote/$staging" "$default" "refs/remotes/$remote/main" "refs/remotes/$remote/master"; do
    if [ -n "$c" ] && git rev-parse -q --verify "$c^{commit}" >/dev/null; then release=$c; break; fi
  done
  [ -n "$release" ] || continue
  since=$(git log -1 --first-parent --no-merges --format=%cI "$release" -- ${p:+"projects/$p"})
  [ -n "$since" ] || since=$(git log -1 --format=%cI "$release")
  w=$warn r=$refuse
  while read -r key value rest; do
    case $key in ''|'#'*) continue ;; esac
    if ! [[ $value =~ ^[0-9]+$ ]] || [ -n "$rest" ]; then echo "release-guard: ignoring .release-guard line: $key $value $rest" >&2
    elif [ "$key" = warn ]; then [ "$value" -ge "$w" ] || w=$value
    elif [ "$key" = refuse ]; then [ "$value" -ge "$r" ] || r=$value
    else echo "release-guard: ignoring .release-guard line: $key $value" >&2; fi
  done < <(for f in .release-guard ${p:+"projects/$p/.release-guard"}; do
    git show "$local_sha:$f" 2>/dev/null | tr -d '\r' || :; done)
  n=$(git rev-list --count --since="$since" "$local_sha")
  [ "$n" -ge "$w" ] || continue
  msg="$n unreleased commits on $run: cut a staging release now; GitHub refuses rebase-merge past ~100"
  echo "release-guard: $msg" >&2
  echo "release-guard: counted since ${release#refs/remotes/} at $since (git fetch if that is stale)" >&2
  if [ "$n" -ge "$r" ]; then
    echo "release-guard: push refused at $r or more; release $run to $staging first" >&2
    status=1
  fi
done
exit "$status"
