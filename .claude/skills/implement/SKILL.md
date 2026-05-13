---
name: implement
description: Implement a feature or bug fix in this codebase based on the provided task description
---

$ARGUMENTS

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

---

If you encounter ambiguity that materially affects design (not
style), you may call `ask_operator(question:, context:)` to pause
and ask. Use sparingly — operator time is more expensive than
yours. Style preferences, plausible defaults, and reversible
decisions should NOT use this; pick a reasonable answer and
proceed. If operator chat is disabled and the tool returns an
error, mark the run failed with category `needs_clarification`
instead.

---

Phased execution note: you're running the **implement** step.
Make the code changes; commit them locally; that's it. DO NOT
call `submit_summary` here. A separate, short follow-up step
will ask you to summarize the work for the PR — your full
context will be available to it via session resume, so you
don't need to summarize ahead of time. If you finish early,
just stop your tool calls and let the run end; we'll prompt
you for the summary on the next step.
