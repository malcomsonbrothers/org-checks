# org-checks

Checks that every Malcomson Brothers repository must pass. This repository is
public on purpose: the checks need no secrets, and a public repository can be
read by any workflow in the organisation. Nothing here may ever need a secret.

The checks are enforced by an organisation ruleset whose "Require workflows to
pass" rule points at a workflow in this repository at a pinned commit. There
is nothing to adopt and no caller file: the check runs on every pull request
in every organisation repository, in the context of that repository.

## File lengths

Required workflow: `.github/workflows/file-lengths.yml`. It runs on our
self-hosted Linux runners (`[self-hosted, Linux, metal]`), never on
GitHub-hosted runners, so a repository needs a runner group that gives it one
of those runners. It always enforces: any violation fails the pull request.

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

## Crate tokens

Candidate required workflow: `.github/workflows/crate-tokens.yml`. It is not
in any ruleset yet. Like the file length check it runs on our self-hosted
Linux runners (`[self-hosted, Linux, metal]`) and always enforces.

Every unit stays within 50,000 Claude tokens of hand-written source,
measured as tiktoken `o200k_base` tokens x 1.5, rounded up. The check finds
units in any repository on its own:

- every Cargo package: a directory whose `Cargo.toml` has a `[package]`
  table (a virtual workspace manifest is not a unit)
- every JS/TS package: a directory with a `package.json`, unless that
  manifest only lists workspaces (it has a `workspaces` field or sits beside
  `pnpm-workspace.yaml`)

A unit is `.` when it is the repository root. Each tracked or untracked,
non-ignored file counts towards the deepest unit that contains it; files
outside every unit count towards nothing. These are never counted:
lockfiles, `*.d.ts`, source maps, `*.min.js` and `*.min.css`, `*.snap`,
SVGs, OpenAPI and Swagger documents (`openapi*.json`, `swagger*.yaml` and
so on), anything under `target`, `node_modules`, `dist`, `build`,
`.svelte-kit`, `.next`, `.nuxt`, `.turbo`, `coverage`, `.sqlx` or `openapi`
directories, files that say `@generated` or `DO NOT EDIT` in their first
kilobyte, binaries, symlinks and submodules.

### `.crate-tokens`

Without a `.crate-tokens` file at the repository root every unit gets the
limit with nothing exempt. A repository's `.crate-tokens` may add, one per
line (`#` starts a comment):

- `exempt <glob>` for generated or vendored paths, with the same glob
  syntax as `.file-lengths`
- `baseline <unit> <tokens>` for a grandfathered unit. It fails once the
  unit grows past its row. When the unit shrinks the check prints a note
  asking you to lower the row (or delete it once the unit is within the
  limit); it does not fail on that, because token counts move with every
  edit.

`.crate-tokens` may only shrink against the pull request base. A new or
raised `baseline` row or a new `exempt` line fails unless a reviewer adds
the `crate-tokens-exception` label to the pull request and then closes and
reopens it.

### Fixing a pull request that fails on units that were already too big

With [uv](https://docs.astral.sh/uv/) installed, run this at the root of a
clean checkout of the pull request branch (the check also counts untracked,
non-ignored files, so stray local files would inflate the rows) and commit
`.crate-tokens`:

```sh
curl -fsSL https://raw.githubusercontent.com/malcomsonbrothers/org-checks/master/scripts/check-crate-tokens.sh |
  bash -s -- --print-baseline >> .crate-tokens
```

The pull request that adds the baseline rows needs the
`crate-tokens-exception` label: ask a reviewer to add it, then close and
reopen the pull request so the check re-runs with the label. The check's
failure output prints the same instructions.

It prints a `baseline <unit> <tokens>` row for every unit over the limit,
at its current count, including units already in `.crate-tokens`, so
delete existing `baseline` rows first. Add `exempt` lines before running
it. `--report` lists every unit's count, largest first.
`scripts/check-crate-tokens.sh` is a thin wrapper that runs
`scripts/check-crate-tokens.py` through uv (downloading it from this
repository's `master` when piped from curl); run either directly in a clone.

## Pull request titles

Candidate required workflow: `.github/workflows/pr-title.yml`. It is not in
any ruleset yet. It fails unless the pull request title is a Conventional
Commit subject, `type(scope)!: summary` with the scope and `!` optional:

- types: `feat fix docs style refactor perf test build ci chore revert`
- scope: lower-case letters, digits and `. _ / , -`, e.g. `feat(web,api): ...`
- revert with `revert: ...`, not git's `Revert "..."`

This is the pattern the organisation commit-message rulesets apply to
commits on default branches and `staging`, so a squash merge that takes the
title as its commit subject passes them as well.

Required workflows only run on `opened`, `synchronize` and `reopened`, not
on `edited`, and a re-run replays the original event. The job therefore
reads the current title through the API. To fix a failure, edit the title,
then re-run the failed check (or close and reopen the pull request).

The workflow embeds `scripts/check-pr-title.sh` in the same way as the file
length check; `scripts/check-pr-title.test.sh` fails while the two differ.

## Changing a check

The required workflow embeds `scripts/check-file-lengths.sh`, so the job
fetches nothing and the ruleset's pinned commit pins the engine as well.
After editing the script, paste it back into the workflow between
`<<'ENGINE'` and `ENGINE`, indented ten spaces;
`scripts/check-file-lengths.test.sh` fails while the two differ.
`crate-tokens.yml` embeds `scripts/check-crate-tokens.py` in the same way,
checked by `scripts/check-crate-tokens.test.sh` (it fetches only uv and the
pinned tiktoken). The tests run in `.github/workflows/tests.yml` on every
push and pull request.

A change merged here takes effect organisation-wide only when the ruleset's
pinned ref is updated to the new commit. Until then every repository keeps
running the previously pinned version.
