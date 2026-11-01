module Steps
  class UnlandConflict < Base
    def call
      workspace.setup
      run.update!(prompt: Prompts::UnlandConflict.new(job: job, workflow: workflow).to_s) if run.prompt.blank?
      perform_agentic_change_step(
        log_message: "invoking agent to resolve rollback conflicts (#{workflow.slug})",
        commit_message: "Resolve rollback conflicts for #{job.rollback_subject.slug}"
      )
      raise StepFailed, "rollback conflict resolution left a revert in progress" if revert_in_progress?
    end

    private

    def revert_in_progress?
      git_path = GitRunner.new.run("rev-parse", "--git-path", "REVERT_HEAD", chdir: workspace.path.to_s).strip
      File.exist?(Pathname.new(git_path).absolute? ? git_path : workspace.path.join(git_path))
    rescue GitRunner::GitError
      false
    end
  end
end
