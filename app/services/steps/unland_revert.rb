module Steps
  class UnlandRevert < Base
    def call
      workspace.setup
      git = streaming_git(env: { "GIT_TERMINAL_PROMPT" => "0" })
      expected_base = workflow.artifact("unland_base_sha").to_s
      actual_base = git.run("rev-parse", "#{workspace.base_ref}^{commit}", chdir: workspace.path.to_s).strip
      raise StepFailed, "default branch moved before rollback construction; retry the unland" unless actual_base == expected_base

      shas = Array(workflow.artifact("unland_commit_shas")).reverse
      conflict = revert_in_progress?
      unless conflict
        begin
          # One sequencer operation is important: after a conflict,
          # `git revert --continue` applies every remaining SHA in order.
          # --no-commit also makes a retry before the final commit harmless,
          # because workspace setup discards an interrupted clean worktree.
          git.run("revert", "--no-commit", *shas, chdir: workspace.path.to_s)
          commit_agent_changes("Rollback #{job.rollback_of.slug}")
        rescue GitRunner::GitError => e
          raise StepFailed, "rollback reversal failed without a resolvable conflict: #{e.message}" unless revert_in_progress?

          conflict = true
        end
      end
      workflow.set_artifact!("unland_conflict", conflict)
      skip_conflict_step! unless conflict
      run.update!(head_sha: head_sha)
    end

    private

    def revert_in_progress?
      git_path = GitRunner.new.run("rev-parse", "--git-path", "REVERT_HEAD", chdir: workspace.path.to_s).strip
      File.exist?(Pathname.new(git_path).absolute? ? git_path : workspace.path.join(git_path))
    rescue GitRunner::GitError
      false
    end

    def skip_conflict_step!
      target = workflow.steps.find_by(kind: "unland_conflict")
      target.skip_with_reason!("all landed commits reversed cleanly") if target&.may_skip?
    end
  end
end
