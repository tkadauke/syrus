module Workflows
  class StackRebase < Base
    steps :stack_auto_rebase, :stack_agent_rebase, :stack_force_push

    def self.trigger_kind = "stack_rebase"

    def self.instantiate(job:, artifacts: nil, agent_provider: nil, pr: nil, base_branch: nil)
      super(
        job: job,
        artifacts: StackRebasePlan.artifacts_for(job: job, artifacts: artifacts, pr: pr, base_branch: base_branch),
        agent_provider: agent_provider
      )
    end

    def self.after_success(workflow)
      Array(workflow.artifact(StackRebasePlan::STACK_ARTIFACT)).each do |entry|
        stack_job = Job.find_by(id: entry["job_id"])
        next unless stack_job&.approved?

        LandingQueueProcessor.try_land!(stack_job)
      end
    end
  end
end
