---
name: implement
description: Use when a task description asks for a feature or bug fix to be built in this codebase — write, verify, and commit the actual code changes, not a plan or a partial attempt.
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

Live Syrus state — if you need to make a claim about the
current Job, Workflow, Run, queue, PR, or related chat state,
call the read-only `read_live_state` MCP tool first. Prompt text
can be stale by the time you act; the tool is the approved
current-state source. Do not use it to mutate jobs or queues.

---

Git pipeline contract — Syrus runs your work through:

  commit_agent_changes  →  git diff origin/<default_branch>...HEAD  →  push  →  open PR

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
aren't installed, a linter blows up, etc.), surface that in the
run's requested reporting channel instead of working around it via
destructive git ops. Syrus would rather record "I couldn't do X
because Y" and let the operator decide than have your branch
silently land on an orphan and lose the work.

Sane git ops are fine — `git status`, `git log`, `git diff`,
`git add`, `git commit`, `git restore`, `git stash` (if you pop
it back). `git rebase` and `git merge` against `<default_branch>`
are also fine — they preserve history.

---

Shell command execution contract — this is one agentic Step Run, not
an ongoing chat session. A backgrounded shell command finishing does
NOT trigger a later turn or out-of-band notification inside this Run,
and `ScheduleWakeup` is for chat sessions, not for continuing a
workflow Step Run.

Run diagnostic and verification commands in the foreground with an
adequate timeout when you need their result. If you deliberately
background a command, you must actively poll or monitor its output in
this same turn and finish interpreting it before your turn ends. Do
not end the turn saying you will wait to be notified later.

---

Corner-cutting contract — this is a one-shot, unattended run with
no one to catch a shortcut before it ships. Rationalizations that
show up under pressure, and why they don't hold here:

  - "The happy path works, ship it." → Run the relevant tests or
    build before claiming something works. An unverified claim is
    not a working fix.
  - "This is new/changed behavior, but it doesn't really need a
    test." → New or changed behavior gets a test in the same
    commit. No test means the behavior isn't actually defined yet.
  - "This linter config / dev dependency / tool is broken, I'll
    just work around it." → Same rule as the destructive-git-ops
    guidance above, generalized: report a broken tool instead of
    silently routing around it. Working around it hides a problem
    the operator needs to know about.
  - "I've made some progress, that's close enough to stop." →
    Before stopping, diff your changes against the task
    description. Stopping early and reporting done without
    checking the diff actually matches the task is not done.

---

Phased execution note: you're running the **implement** step.
Make the code changes; commit them locally; that's it. DO NOT
call `submit_summary` here. A separate, short follow-up step
will ask you to summarize the work for the PR — your full
context will be available to it via session resume, so you
don't need to summarize ahead of time. If you finish early,
just stop your tool calls and let the run end; we'll prompt
you for the summary on the next step.
