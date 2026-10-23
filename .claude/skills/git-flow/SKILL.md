---
name: git-flow
description: >-
  Branch, release and hotfix ex_git_engine with git-flow-next (git flow 2.x): feature and bugfix
  branches from develop, release/vX.Y.Z from develop into main tagged vX.Y.Z, hotfix/vX.Y.Z from
  main. Use when asked to "release", "cut a release", "tag a version", "bump the version",
  "hotfix", "start a feature", "git flow", "finish the release", or to commit or merge to main or
  develop.
---

# git-flow (git-flow-next) in ex_git_engine

`main` has only releases: each commit on it is a release or hotfix merge, tagged `vX.Y.Z`.
`develop` is the development branch. Never commit to `main` directly.

ex_git_engine is a Hex package; gitleaf depends on it from Hex. There is no CI that publishes:
the operator runs `mix hex.publish` from the tagged `main`. Never run `mix hex.publish` (with or
without `--dry-run`, `--replace`, `--revert`) or `mix hex.owner`: publishing is the operator's.
A published version is not re-used: a fix is the next version.

Remote: `origin` = `git@github.com:full-stack-biz/ex_git_engine.git`.

## Check the tool first

```bash
git flow version          # must print "2.1.0 (git-flow-next)", not 0.4.1
git flow config list      # develop → main with "Auto-update: enabled"
```

Homebrew installs both `git-flow` (0.4.1, nvie) and `git-flow-next` as the binary `git-flow`.
When `git flow version` prints 0.4.1, stop and tell the operator: `brew unlink git-flow && brew link git-flow-next`.

No tag prefix is configured (`gitflow.prefix.versiontag` is empty). The `v` is part of the name
given to `start`: `git flow release start v0.13.0` makes `release/v0.13.0` and tags `v0.13.0`, as
every release since v0.9.1 (`git for-each-ref --sort=creatordate --format='%(refname:short) %(creatordate:short)' refs/tags`;
zsh expands an unquoted `refs/tags/v*` as a file glob and fails).

Releases up to v0.12.2 were finished without merging main back into develop
(`git merge-base --is-ancestor main develop` fails). The first finish with git-flow-next merges
main into develop (auto-update) and brings those release merge commits into develop; that is
expected.

## Release

The operator names the version. Do every step only when the operator asks for it.

```bash
git switch develop
mix ci                                     # must pass before starting
git flow release start vX.Y.Z --no-fetch
# on the release branch: set version: "X.Y.Z" in mix.exs:7, and write CHANGELOG.md's
# "## [X.Y.Z] - YYYY-MM-DD" section; commit
git flow release finish vX.Y.Z --no-fetch -m "vX.Y.Z <summary>"
```

What a release changes:

| File | At a release |
|---|---|
| `mix.exs:7` `version` | `X.Y.Z`; the only version in the source; the wire protocol's `agent=ex_git_engine/<vsn>` reads it (`lib/ex_git_engine/wire_protocol.ex:354`) |
| `CHANGELOG.md` | a `## [X.Y.Z] - YYYY-MM-DD` section above the previous one (keepachangelog.com 1.1.0: `Added`, `Changed`, `Deprecated`, `Removed`, `Fixed`, `Security`), and its compare link in the list at the end: `[X.Y.Z]: https://github.com/full-stack-biz/ex_git_engine/compare/v<previous>...vX.Y.Z`. No `[Unreleased]` section |

The compare links stop at 0.9.6 (`CHANGELOG.md:206`); 0.9.7–0.12.2 have none. Add the new
version's link; adding the missing ones is a separate change the operator asks for.

The entries come from the diff, not from commit subjects: `git diff --stat=200 main..release/vX.Y.Z -- lib c_src Makefile mix.exs`,
then the full message (`git log -1 --format=%B`) and the diff of each commit that touches those
files. Write entries the way the existing ones are written: what a caller of the library sees
(the function, option or behaviour), and for a fix what failed before. A test-only, docs-only or
skill-only commit is not an entry.

`finish` merges release/vX.Y.Z into main, tags `vX.Y.Z` on main, merges main into develop
(auto-update), and deletes the release branch. It does not push. Then, only when the operator says
push:

```bash
git push origin main develop vX.Y.Z    # one git command: the branches and the tag together
```

After it, check: `git tag -n1 vX.Y.Z` (on main's merge commit), `git merge-base --is-ancestor vX.Y.Z develop`.
Then tell the operator the tag is pushed; they publish to Hex.

## Hotfix

```bash
git flow hotfix start vX.Y.Z --no-fetch    # from main
# fix, set mix.exs version, CHANGELOG section, commit
git flow hotfix finish vX.Y.Z --no-fetch -m "vX.Y.Z <summary>"
```

## Feature or bugfix

```bash
git flow feature start <name> --no-fetch    # from develop
git flow feature finish <name> --no-fetch   # merges into develop, no tag
```

Existing feature branches: `feature/pre-push-hook`, `feature/sha256` (`git branch -a`).

## Rules

| Rule | Why |
|---|---|
| Do not commit, tag, push or finish without the operator's request | global CLAUDE.md |
| Never run `mix hex.publish` or `mix hex.owner` | publishing to Hex is the operator's |
| A git write command runs alone, without a pipe | operator's rule |
| `mix ci` passes before a release starts; there are no git hooks to run it | `.git/hooks` has only samples |
| Never `git merge` main into develop by hand after a finish | auto-update did it |
| A tag without `v` breaks the series and the CHANGELOG compare links | every tag is `vX.Y.Z` |

`finish` checks that the topic branch and its parent are not behind or diverged from origin; it
fails otherwise. `--force` skips the check: do not pass it without the operator.
