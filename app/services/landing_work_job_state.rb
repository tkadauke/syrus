class LandingWorkJobState
  def self.ensure_landing!(job:, workflow: nil, reason:)
    new(job: job, workflow: workflow, reason: reason).ensure_landing!
  end

  def initialize(job:, workflow:, reason:)
    @job = job
    @workflow = workflow
    @reason = reason
  end

  def ensure_landing!
    return false unless job
    return true if job.landing?
    return false unless landing_workflow?

    StateTransition.with_source("system", reason: reason, metadata: metadata) do
      job.with_lock do
        job.reload
        return true if job.landing?
        return false unless repairable?

        job.landing_failure_reason = nil
        if job.may_start_landing?
          job.start_landing!
        elsif job.may_repair_to_landing?
          job.repair_to_landing!
        else
          return false
        end

        job.save!
      end
    end

    true
  end

  private

  attr_reader :job, :workflow, :reason

  def landing_workflow?
    return false if workflow && !workflow.landing_workflow?
    return true if job.running? && workflow&.landing_workflow?

    WorkEngine::RuntimeOwnership.active_landing_work_for_job?(job)
  end

  def repairable?
    return true if job.running?

    job.approved? && WorkEngine::RuntimeOwnership.active_landing_work_for_job?(job)
  end

  def metadata
    {
      workflow_id: workflow&.id,
      workflow_trigger_kind: workflow&.trigger_kind,
      job_id: job&.id,
      job_slug: job&.slug
    }.compact
  end
end
