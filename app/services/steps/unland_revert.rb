module Steps
  class UnlandRevert < Base
    def call
      workspace.setup
      git = streaming_git(env: { "GIT_TERMINAL_PROMPT" => "0" })
      expected_base = workflow.artifact("unland_base_sha").to_s
      actual_base = git.run("rev-parse", "#{workspace.base_ref}^{commit}", chdir: workspace.path.to_s).strip
      raise StepFailed, "default branch moved before rollback construction; retry the unland" unless actual_base == expected_base

      conflict = false
      Array(workflow.artifact("unland_commit_shas")).reverse_each do |sha|
        begin
          git.run("revert", "--no-edit", sha, chdir: workspace.path.to_s)
        rescue GitRunner::GitError
          conflict = true
          break
        end
      end
      workflow.set_artifact!("unland_conflict", conflict)
      skip_conflict_step! unless conflict
      run.update!(head_sha: head_sha)
    end

    private

    def skip_conflict_step!
      target = step.next_step
      target.skip_with_reason!("all landed commits reversed cleanly") if target&.kind == "unland_conflict" && target.may_skip?
    end
  end
end
