module Prompts
  # Trailing block appended to every primary-agent prompt (Initial,
  # PrFeedback, Resume, ScheduledTask, Rebase) telling the agent what
  # Syrus is and what git invariants its pipeline assumes. Lives in
  # the prompt — not the target repo's CLAUDE.md — because these are
  # *Syrus* contracts, not per-repo conventions, and they apply to
  # every target repo uniformly.
  #
  # Real-world incident this guards: tkadauke/syrus#82 (Run 94). Agent
  # hit a tooling error mid-run, decided to "manually" fix things, ran
  # `git checkout --orphan` (or equivalent), produced a branch with no
  # shared ancestor to main. Pipeline's diff capture (`git diff
  # main...HEAD`) failed with exit 128, run was marked failed, ~1 hour
  # of agent work lost.
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
