module Steps
  class UnlandConflict < Base
    def call
      workspace.setup
      run.update!(prompt: Prompts::UnlandConflict.new(job: job).to_s) if run.prompt.blank?
      perform_agentic_change_step(
        log_message: "invoking agent to resolve rollback conflicts (#{workflow.slug})",
        commit_message: "Resolve rollback conflicts for #{job.rollback_of.slug}"
      )
    end
  end
end
