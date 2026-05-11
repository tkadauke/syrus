---
name: rebase
description: Resolve conflicts and rebase a branch that has fallen behind its base to restore PR mergeability
---

$ARGUMENTS

Your job is to make it mergeable again. Specifically:

1. Run `git fetch origin <base_branch>` (the base branch name is given in the context above) so you have the latest base.
2. Run `git rebase origin/<base_branch>` (you are already on the branch specified in the context).
3. If conflicts come up, **resolve them mechanically** — preserve both intents
   where possible, prefer minimal edits, never delete code that looks like real
   work just to make the rebase clean.
4. Continue the rebase (`git add <resolved files> && git rebase --continue`)
   until it completes.
5. Do NOT make functional changes beyond what conflict resolution requires.
6. Do NOT run tests, lint, formatters, or anything else that mutates files.
   If they catch real bugs introduced by the conflict resolution, that's
   a separate Run's problem.
7. If you cannot resolve a conflict mechanically (the two sides genuinely
   disagree on intent), abort the rebase (`git rebase --abort`) and explain
   in `submit_summary`. Do NOT push a half-rebased branch.

Syrus will force-push the rebased branch to origin once you finish — your
only job is to leave the working tree on a clean rebased HEAD.

---

Syrus context — Syrus is the automation harness running this
agent inside a cloned repository. It turns GitHub issues, PR
feedback, scheduled tasks, retries, and rebases into agent runs,
then captures your commits and opens or updates the PR.

Before you start, Syrus may run setup commands from `.syrus.yml`
at the repo root. Supported shape:

  prepare:
    - bundle install
    - npm ci

`prepare: []` or `prepare: false` opts out. If `.syrus.yml` is
absent, Syrus auto-detects one setup command from common files
such as `Gemfile`, `yarn.lock`, `pnpm-lock.yaml`,
`package-lock.json`, or `package.json`. Do not edit `.syrus.yml`
unless the task asks you to fix setup itself.

---

Git pipeline contract — Syrus runs your work through:

  commit_agent_changes  →  git diff <default_branch>...HEAD  →  push  →  open PR

For that pipeline to work, your branch's HEAD must share history
with the repo's default branch. Don't break that invariant. In
particular, NEVER run any of these mid-run:

  - `git checkout --orphan ...`  /  `git switch --orphan ...`
  - `git reset --hard <unrelated commit>`
  - `git rm -r .` followed by re-adding everything
  - `rm -rf .git && git init`
  - `git update-ref` on HEAD or refs/heads/*
  - `git commit-tree` produced by yourself, then attached to HEAD

If a tool gives you trouble (a Rails task fails because dev gems
aren't installed, a linter blows up, etc.), surface that in your
`submit_summary` instead of working around it via destructive git
ops. Syrus would rather record "I couldn't do X because Y" and
let the operator decide than have your branch silently land on an
orphan and lose the work.

Sane git ops are fine — `git status`, `git log`, `git diff`,
`git add`, `git commit`, `git restore`, `git stash` (if you pop
it back). `git rebase` and `git merge` against `<default_branch>`
are also fine — they preserve history.
