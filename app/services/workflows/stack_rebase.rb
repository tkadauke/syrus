module Workflows
  class StackRebase < Base
    steps :stack_auto_rebase, :stack_agent_rebase, :stack_force_push

    def self.trigger_kind = "stack_rebase"

    def self.queue_name = :merges

    def self.instantiate(
      job:,
      artifacts: nil,
      agent_provider: nil,
      pr: nil,
      base_branch: nil,
      planned_execution_requirements: nil
    )
      super(
        job: job,
        artifacts: StackRebasePlan.artifacts_for(job: job, artifacts: artifacts, pr: pr, base_branch: base_branch),
        agent_provider: agent_provider,
        planned_execution_requirements: planned_execution_requirements
      )
    end

    # After the surrounding transaction commits, as Workflows::Rebase does:
    # the hook runs inside the stack rebase's success transition, holding its
    # Workflow, and launching a landing (an auto_merge, or the stack's Epic
    # merge train) locks the new lineage's WorkIntent and WorkUnit below it --
    # out of the row-lock order (NY40). Outside a transaction this runs at once.
    def self.after_success(workflow)
      job_ids = Array(workflow.artifact(StackRebasePlan::STACK_ARTIFACT)).filter_map { |entry| entry["job_id"] }
      return if job_ids.empty?

      ActiveRecord.after_all_transactions_commit do
        job_ids.each do |job_id|
          stack_job = Job.find_by(id: job_id)
          next unless stack_job&.approved?

          LandingQueueProcessor.try_land!(stack_job)
        end
      rescue StandardError => e
        # Best-effort like every lifecycle hook: the rebase's success is
        # committed, and the recurring landing loop picks the Jobs up anyway.
        Rails.logger.warn("[Workflow##{workflow.id}] after_success landing re-dispatch raised: #{e.class}: #{e.message}")
      end
    end
  end
end
