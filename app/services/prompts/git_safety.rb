module Prompts
  # Trailing block appended to every primary-agent prompt (Initial,
  # PrFeedback, ScheduledTask, Rebase) telling the agent what
  # Syrus is and what git invariants its pipeline assumes. Lives in
  # the prompt — not the target repo's CLAUDE.md — because these are
  # *Syrus* contracts, not per-repo conventions, and they apply to
  # every target repo uniformly.
  #
  # Real-world incident this guards: an agent hit a tooling error mid-run,
  # decided to "manually" fix things, ran `git checkout --orphan` (or
  # equivalent), and produced a branch with no shared ancestor to main.
  # Pipeline diff capture then failed with exit 128 and the work was lost.
  module GitSafety
    TEXT = <<~TXT.strip
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

      If a tool gives you trouble (a setup task fails because dependencies
      aren't installed, a linter blows up, etc.), surface that in the
      run's requested reporting channel instead of working around it via
      destructive git ops. Syrus would rather record "I couldn't do X
      because Y" and let the operator decide than have your branch
      silently land on an orphan and lose the work.

      Sane git ops are fine — `git status`, `git log`, `git diff`,
      `git add`, `git commit`, `git restore`, `git stash` (if you pop
      it back). `git rebase` and `git merge` against `<default_branch>`
      are also fine — they preserve history.
    TXT
  end
end
