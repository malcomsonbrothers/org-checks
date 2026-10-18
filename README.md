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
light pool of self-hosted Linux runners on metal-02
(`[self-hosted, Linux, light]`), never on GitHub-hosted runners, so a
repository needs a runner group that gives it one of those runners. It always enforces: any violation fails the pull request.

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
in any ruleset yet. Like the file length check it runs on our light pool of
self-hosted Linux runners (`[self-hosted, Linux, light]`) and always enforces.

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
so on), the org-vendored `.githooks/org/`, anything under `target`, `node_modules`, `dist`, `build`,
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

## Commit size

Candidate required workflow: `.github/workflows/commit-size.yml`. It is not
in any ruleset yet. Like the file length check it runs on our light pool of
self-hosted Linux runners (`[self-hosted, Linux, light]`) and always enforces.

It refuses commits too large to review. Every commit in the pull request
(base..head) may change at most 1,000 lines: additions plus deletions, with
renames detected so a pure move counts nothing. Each commit is measured,
not the pull request total, so a promotion pull request made of reviewable
slices passes while a squash of the same work fails. A failure names each
oversized commit, its size and the limit.

- Never counted where its manifest sits beside it in the commit (at any
  depth): `Cargo.lock` (`Cargo.toml`), `bun.lock`, `package-lock.json`,
  `pnpm-lock.yaml`, `yarn.lock` (`package.json`) and `uv.lock`
  (`pyproject.toml`). A lockfile name without its manifest counts.
- A file renamed out of an exempt path into a counted one counts in full.
- Binaries are what git calls binary (a NUL byte in the first 8,000 bytes)
  with the pull request's `.gitattributes` ignored, so attributes cannot
  hide text. A binary `png jpg jpeg gif webp avif ico woff woff2 ttf otf
  pdf mp4 webm wasm jar so zip gz tar` file is exempt; any other binary
  counts the larger of its lines and one line per 40 bytes. Deleting a
  binary, or renaming it unchanged, counts nothing.
- A merge commit counts what it adds beyond an automatic merge of its
  parents (`git show --remerge-diff`): a clean merge counts nothing, a
  conflict resolution or extra change counts. Octopus merges (three or
  more parents) fail; merge the branches one at a time.
- A changed path containing a newline or a tab fails the commit.
- Promotions: in a pull request from the repository's own `staging`
  branch (not a fork's) into the default branch, commits already on
  `origin/staging` are skipped, because they passed this check on their
  way into staging. The same holds for `<project>/staging` when the base
  has a `projects/<project>/` folder; any other `<x>/staging` is checked
  in full.
- If the base branch is force-pushed while a pull request is open, commits
  that left the base become part of base..head and are measured again;
  rebase the pull request onto the new base.

The job fetches the full history of the pull request into a fresh clone
(see "How the checks fetch the pull request" below).

### `.commit-size`

Without a `.commit-size` file at the repository root the limit applies with
only the lockfiles exempt. A repository's `.commit-size`, read at the pull
request head, may add, one per line (`#` starts a comment):

- `exempt <glob>` for generated or vendored paths, with the same glob
  syntax as `.file-lengths`

`.commit-size` may only shrink against the pull request base. A new
`exempt` line fails unless a reviewer adds the `commit-size-exception`
label to the pull request and then closes and reopens it. The label also
allows oversized commits, for the rare change that cannot be split.

### Fixing a pull request that fails

Split each named commit (`git rebase -i`, mark it `edit`, then
`git reset HEAD~` and commit it again in parts), or exempt generated
paths in `.commit-size`. To check locally before pushing, from a clone
of this repository or a copy of `scripts/check-commit-size.sh`:

```sh
scripts/check-commit-size.sh origin/main HEAD
```

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

## Commit count

Candidate required workflow: `.github/workflows/commit-count.yml`
(GitHub-hosted). It is not in any ruleset yet. A pull request into the
default branch, `staging` or `<project>/staging` may hold at most 95 commits: GitHub will not
rebase-merge many more (about 100 work, 300 do not), and releases are never
squashed. Release more often or split the pull request. The
`commit-count-exception` label allows more; close and reopen the pull
request after adding it.

## Org hooks

Candidate required workflow: `.github/workflows/org-hooks.yml`
(GitHub-hosted). It is not in any ruleset yet. On pull requests into the
default branch, `staging` or `<project>/staging`, every repository must ship
`.githooks/org/pre-push-guards.sh` identical to this repository's
`scripts/hooks/pre-push-guards.sh`, and an executable `.githooks/pre-push`
that calls it. To install or update, at the repository root, then commit
`.githooks`:

```sh
curl -fsSL https://raw.githubusercontent.com/malcomsonbrothers/org-checks/master/scripts/install-hooks.sh | bash
git config core.hooksPath .githooks   # once per clone
```

The guard is local only, so the swarm never waits for CI. A push to
`swarm/run` counts the commits made since the head of `origin/staging`
(else the default branch) was committed: from 80 it warns, from 150 it
refuses the push. Cut a staging release to clear it, and `git fetch` if
`origin/staging` is stale. A repository's `.release-guard` may only lower
the thresholds, with `warn <n>` and `refuse <n>` lines. A push to
`<project>/swarm/run` counts against `origin/<project>/staging` the same
way when the pushed commit has a `projects/<project>/` folder, and
`projects/<project>/.release-guard` may lower its thresholds too. In a
repository without `projects/` the check also accepts the previous guard
(`GUARD_BLOB_PREVIOUS`, until the next pin bump after 2026-10-18), which
guards it the same way; otherwise every repository must reinstall when the
guard changes here and the ruleset pin moves. After changing `scripts/hooks/pre-push-guards.sh`, update
`GUARD_BLOB` in `org-hooks.yml` and run `scripts/install-hooks.sh` here;
`scripts/check-org-hooks-pin.sh` fails until both match.

## Monorepos

A repository holding several projects keeps each under `projects/<project>/`
(letters, digits, `.`, `_` and `-`, not starting with `.`) and gives each
its own branches: `<project>/swarm/run`, `<project>/swarm/next` and
`<project>/staging`. The checks key on the folder, not on a monorepo flag:
any repository with a top-level `projects/<x>/.file-lengths`,
`.commit-size` or `.crate-tokens` has it read as that folder's config.

- `projects/<project>/.file-lengths`, `.commit-size` and `.crate-tokens`
  add lines with paths, globs and units relative to that folder (`.` is the
  folder itself). They cannot reach outside it. `limit` lines stay in the
  root `.file-lengths`. A path with rows in two files is an error.
- Each file may only shrink against the same file at the base, so moving
  a row to another file counts as a new row there.
- `<project>/staging` (one folder segment) is a staging branch for the
  commit count and the org hooks check, and for the promotion rule when
  the base has `projects/<project>/`.
- Precondition before a ruleset pins this version: `refs/heads/*/staging`
  carries the same ruleset as `staging` (pull requests required), and
  creating a `*/staging` branch is restricted. Otherwise anyone could
  push commits straight to `<project>/staging` and have the promotion skip
  them.

## Changing a check

The required workflow embeds `scripts/check-file-lengths.sh`, so the job
fetches nothing and the ruleset's pinned commit pins the engine as well.
After editing the script, paste it back into the workflow between
`<<'ENGINE'` and `ENGINE`, indented ten spaces;
`scripts/check-file-lengths.test.sh` fails while the two differ.
`crate-tokens.yml` embeds `scripts/check-crate-tokens.py` in the same way,
checked by `scripts/check-crate-tokens.test.sh` (it fetches only uv and the
pinned tiktoken), and `commit-size.yml` embeds `scripts/check-commit-size.sh`,
checked by `scripts/check-commit-size.test.sh`. The tests run in `.github/workflows/tests.yml` on every
push and pull request.

### How the checks fetch the pull request

The self-hosted runners are shared and keep each repository's workspace
between jobs, so another job can leave it as a blob-less (filtered) or
shallow clone. `actions/checkout` reuses such a `.git`, and a check that
later needs a missing blob fails because the job can no longer fetch it.
So `commit-size.yml`, `file-lengths.yml` and `crate-tokens.yml` never use
the workspace: `scripts/fresh-clone.sh`, embedded between `<<'CLONE'` and
`CLONE` like the engines, fetches the pull request into a new repository
under `$RUNNER_TEMP`, never with a filter, using the job token through an
environment-only header that is never written to `.git/config`. The commit
size check fetches the full history of the base and head (fork heads come
through the base repository); the file length and crate token checks fetch
only the merge commit and the base commit. `scripts/fresh-clone.test.sh`
replays the blob-less workspace failure and fails while a workflow's copy
differs from the script.

A change merged here takes effect organisation-wide only when the ruleset's
pinned ref is updated to the new commit. Until then every repository keeps
running the previously pinned version.
