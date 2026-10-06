# org-checks

Checks that every Malcomson Brothers repository must pass. This repository is
public on purpose: the checks need no secrets, and a public repository can be
read by any workflow in the organisation. Nothing here may ever need a secret.

The checks are enforced by an organisation ruleset whose "Require workflows to
pass" rule points at a workflow in this repository at a pinned commit. There
is nothing to adopt and no caller file: the check runs on every pull request
in every organisation repository, in the context of that repository.

## File lengths

Required workflow: `.github/workflows/file-lengths.yml`. It runs on
GitHub-hosted `ubuntu-latest`, so it works in every repository, including
those that cannot use the self-hosted runner group. It always enforces: any
violation fails the pull request.

### Limits

The organisation limits are fixed in `scripts/check-file-lengths.sh`, and no
repository can change them:

- 600 lines: `rs svelte ts tsx js jsx mjs cjs mts cts py css scss swift go kt`
- 250 lines: `sh bash zsh sql`, plus extension-less files whose shebang runs
  sh, bash or zsh

### `.file-lengths`

The check never skips. Without a `.file-lengths` file at the repository root
it applies the organisation limits with nothing exempt. A repository's
`.file-lengths` may add, one per line (`#` starts a comment):

- `limit <max lines> <extensions...>` for file types the organisation limits
  do not cover (a line naming a covered extension is an error)
- `exempt <glob>` for generated or vendored paths: `*` is one path segment,
  `**` any depth, every other character literal, so
  `web/src/routes/[id]/**` works
- `baseline <path> <lines>` for grandfathered oversized files. Each row must
  equal the file's real length. The pre-commit hook lowers a row (and stages
  `.file-lengths`) when its file shrinks, and drops it once the file is
  within the limit or deleted.

`.file-lengths` may only shrink against the pull request base. A new or
raised `baseline`, `exempt` or `limit` line fails unless a reviewer adds the
`file-lengths-exception` label to the pull request and then closes and
reopens it. Required workflows do not re-run on label changes, so the
reopen is what makes the check see the label.

### Fixing a pull request that fails on files that were already oversized

Run this at the repository root, commit `.file-lengths`, and ask a reviewer
to label the pull request `file-lengths-exception`, then close and reopen
the pull request so the check re-runs with the label:

```sh
curl -fsSL https://raw.githubusercontent.com/malcomsonbrothers/org-checks/master/scripts/check-file-lengths.sh |
  bash -s -- --print-baseline >> .file-lengths
```

It prints a `baseline <path> <lines>` row for every oversized file that is
not exempt, at its current length. It also prints rows for files already in
`.file-lengths`, so delete any existing `baseline` rows first. Add `exempt`
and `limit` lines before running it.

### Local git hooks (optional)

Copy `scripts/check-file-lengths.sh` and `.githooks/` from this repository
into the same paths in your repository, then once per clone:

```sh
git config core.hooksPath .githooks
```

Pre-commit checks the staged content; pre-push checks the files changed in
the commits being pushed (a new branch from its merge-base with the default
branch).

## Changing a check

The required workflow embeds `scripts/check-file-lengths.sh`, so the job
fetches nothing and the ruleset's pinned commit pins the engine as well.
After editing the script, paste it back into the workflow between
`<<'ENGINE'` and `ENGINE`, indented ten spaces;
`scripts/check-file-lengths.test.sh` fails while the two differ. The tests
run in `.github/workflows/tests.yml` on every push and pull request.

A change merged here takes effect organisation-wide only when the ruleset's
pinned ref is updated to the new commit. Until then every repository keeps
running the previously pinned version.
