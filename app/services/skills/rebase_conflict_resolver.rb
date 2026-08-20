require "open3"

module Skills
  # Built-in skill (EPIC-234): judgment-heavy fallback for a git conflict
  # the automated rebase machinery (`AutoRebase`/`Steps::AgentRebase`,
  # `Steps::ForcePush`, `Steps::StackAgentRebase`/`Steps::StackForcePush`)
  # couldn't resolve mechanically. Generic across repos — resolving a
  # conflict sensibly isn't tied to any branch-naming policy, so this
  # skill takes the conflicted branch/base as plain parameters rather
  # than assuming Syrus's own `syrus/...` naming.
  #
  # Manual invocation only, by design (per the originating issue): this
  # skill is reachable only through the normal skill entry points (Job
  # launch, chat slash command, ScheduledTask) — nothing in the automated
  # rebase pipeline references it or hands off to it. Whether/how it
  # should become an automatic hand-off target from that pipeline is an
  # explicit open design question this PR does not decide (see the PR
  # description); resolving it here would be guessing at a design call
  # the issue asked to defer to a reviewer.
  #
  # A standalone skill Job always starts from a fresh checkout on the
  # skill Job's own branch, not the conflicted branch itself (see
  # Steps::RunSkill) — so the deliverable here is a new branch/PR
  # containing the resolved code for operator review, not an in-place
  # force-push of the original branch. The instructions say this
  # explicitly so the resulting PR body doesn't read as though the
  # original conflicted branch was updated. The other reachable path is a
  # Coding Mode chat slash command, where the workspace can already be
  # mid-rebase/mid-merge from something the operator did by hand — the
  # pre-scan below detects that case and tells the agent to finish
  # resolving what's already there instead of starting a fresh fetch.
  class RebaseConflictResolver < Base
    def self.skill_name
      "rebase-conflict-resolver"
    end

    def self.description
      "Judgment-heavy fallback for resolving a git conflict the automated rebase machinery couldn't " \
        "resolve mechanically. Manual invocation only — not an automatic hand-off target."
    end

    def self.parameter_schema
      [
        { key: "branch_name", type: "string", required: true, label: "Branch with the conflict" },
        { key: "base_branch", type: "string", required: false, label: "Rebase onto (defaults to the repository's default branch)" }
      ]
    end

    def to_s
      [ intro, pre_scan_section, step_by_step_instructions ].compact.join("\n\n")
    end

    private

    def resolved_base_branch
      @args["base_branch"].presence || @repository&.default_branch || "the repository's default branch"
    end

    def intro
      <<~TXT.strip
        You are resolving a git conflict that the automated rebase
        machinery (`AutoRebase`/`Steps::AgentRebase`, `Steps::ForcePush`,
        `Steps::StackAgentRebase`/`Steps::StackForcePush`) either
        couldn't resolve mechanically, or that an operator wants resolved
        by hand instead of waiting for that pipeline. Manual invocation
        only: this run only exists because this skill was explicitly
        invoked — nothing in Syrus currently hands off to it
        automatically.

        That automated pipeline's own conflict resolution is deliberately
        mechanical (see `.claude/skills/rebase/SKILL.md`): preserve both
        sides, make minimal edits, abort rather than guess when intent
        genuinely conflicts. Your job is the escalation past that — read
        both sides for what they actually intended (commit messages,
        surrounding code, what each change was trying to accomplish) and
        make a considered judgment call, not just a structural merge.

        Branch with the conflict: {{branch_name}}
        Rebase onto: #{resolved_base_branch}
      TXT
    end

    def pre_scan_section
      scan = workspace_conflict_scan
      return nil unless scan

      if scan[:conflicted_files].empty? && !scan[:rebase_in_progress] && !scan[:merge_in_progress]
        return <<~TXT.strip
          ## Automated pre-scan results

          Syrus checked this checkout before invoking you: it is not
          currently mid-rebase or mid-merge, and `git diff --diff-filter=U`
          finds no unmerged files. Fetch and reproduce the conflict
          yourself per Step 1 below — there is nothing already in
          progress here to pick up.
        TXT
      end

      <<~TXT.strip
        ## Automated pre-scan results

        Syrus found this checkout already in a conflicted state before
        invoking you:

        - Rebase in progress: #{scan[:rebase_in_progress]}
        - Merge in progress: #{scan[:merge_in_progress]}
        - Files with unresolved conflicts: #{conflicted_files_summary(scan)}

        Finish resolving the conflict already present here rather than
        starting a fresh fetch/rebase, unless what's checked out doesn't
        actually match the branch/base named above.
      TXT
    end

    def conflicted_files_summary(scan)
      return "none listed by `git diff --diff-filter=U`, but a rebase/merge is in progress — inspect `git status` directly" if scan[:conflicted_files].empty?

      scan[:conflicted_files].join(", ")
    end

    def workspace_conflict_scan
      return nil unless @workspace_path

      git_dir = Pathname.new(@workspace_path.to_s).join(".git")
      return nil unless git_dir.exist?

      @workspace_conflict_scan ||= {
        rebase_in_progress: git_dir.join("rebase-merge").exist? || git_dir.join("rebase-apply").exist?,
        merge_in_progress: git_dir.join("MERGE_HEAD").exist?,
        conflicted_files: conflicted_files
      }
    end

    def conflicted_files
      stdout, _stderr, status = Open3.capture3("git", "-C", @workspace_path.to_s, "diff", "--name-only", "--diff-filter=U")
      return [] unless status.success?

      stdout.split("\n").map(&:strip).reject(&:empty?)
    end

    def step_by_step_instructions
      <<~INSTRUCTIONS.strip
        ## Step 1 — reproduce or pick up the conflict

        If the pre-scan above found an in-progress rebase/merge, continue
        from that state. Otherwise:

        - `git fetch origin {{branch_name}}`
        - `git fetch origin` the base branch named above
        - Check out `{{branch_name}}` locally and rebase it onto the
          fetched base ref. Confirm you actually hit a conflict — if the
          rebase completes cleanly, there is nothing for this skill to
          add; say so and stop rather than inventing unrelated changes.

        ## Step 2 — resolve with judgment, not just mechanically

        For each conflicted hunk, read enough context to understand what
        each side was actually trying to do — not just what the text
        diff shows. Prefer preserving both intents where they're
        genuinely compatible. Where they truly conflict, make the call
        that best serves the codebase and explain your reasoning when you
        report back — that reasoning is the entire value of escalating
        past the mechanical resolver. Keep edits to what reconciling the
        conflict requires; do not use this as an opportunity to refactor,
        rename, or "clean up" code that isn't part of the conflict.

        ## Step 3 — finish cleanly

        `git add <resolved files>` and `git rebase --continue` (or the
        equivalent for a merge) until it completes. Confirm the working
        tree is clean and no conflict markers remain anywhere in the
        tree. This workflow does not run automated graders afterward, so
        use your judgment about whether running a relevant slice of the
        repository's own tests is warranted given the size and risk of
        what you resolved.

        ## Step 4 — report clearly

        In your final report:

        - Explain what conflicted and how you resolved each hunk, and why.
        - State plainly that this produces a new branch/PR containing the
          resolved code for operator review — it does **not**
          automatically force-push or overwrite the original conflicted
          branch (`{{branch_name}}`). Applying it there, if at all, is the
          operator's call.

        If you cannot resolve the conflict with real confidence — the
        two sides' intent genuinely can't be reconciled without more
        context than you have — do not guess. Abort any rebase/merge in
        progress, leave the working tree exactly as you found it, make no
        commit, and explain what's blocking a confident resolution. That
        is a valid, successful outcome: a run with nothing to commit
        closes without opening a PR.
      INSTRUCTIONS
    end
  end
end
