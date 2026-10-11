class LandingQueueReentry
  START_BLOCKER_PREFIX = "landing start blocked:".freeze

  Result = Data.define(:cleared_job_ids) do
    def any? = cleared_job_ids.any?
  end

  def self.call(job) = new(job).call
  def self.landing_start_blocker?(code_or_reason)
    LandingFailureCode.resolve(code_or_reason)&.landing_start_blocker? ||
      legacy_landing_start_blocker_reason?(code_or_reason)
  end

  # Compatibility for Jobs written before landing_failure_code existed.
  # Current queue decisions should pass the structured code.
  def self.legacy_landing_start_blocker_reason?(reason) = reason.to_s.start_with?(START_BLOCKER_PREFIX)

  def initialize(job)
    @job = job
  end

  def call
    ids = clearable_jobs.map(&:id)
    if ids.any?
      Job.where(id: ids).update_all(landing_failure_reason: nil, landing_failure_code: nil, updated_at: Time.current)
      LandingQueueProcessorJob.perform_later
    end
    Result.new(cleared_job_ids: ids)
  end

  private

  attr_reader :job

  def clearable_jobs
    candidates = if AppSetting.merge_train_enabled? && job.epic_id.present?
      job.epic.jobs.where(state: "approved")
    else
      Job.where(id: job.id, state: "approved")
    end

    candidates
      .where(landing_failure_code: LandingFailureCode::LANDING_START_BLOCKED)
      .or(candidates.where(landing_failure_code: nil).where("landing_failure_reason LIKE ?", "#{START_BLOCKER_PREFIX}%"))
      .select { |candidate| ready_to_reenter?(candidate) }
  end

  def ready_to_reenter?(candidate)
    return false if landing_start_blocker_backoff_active?(candidate)
    return merge_train_ready_to_reenter?(candidate) if AppSetting.merge_train_enabled? && candidate.epic_id.present?

    return false if candidate.dependencies_failed_for_execution?
    return false unless candidate.dependencies_satisfied_for_execution?
    return false unless JobStackResolver.new(candidate).resolve!(apply: false).ready?

    candidate.ready_for_execution?
  end

  def merge_train_ready_to_reenter?(candidate)
    MergeTrainDispatcher.blocker_reason(candidate.epic).blank?
  end

  def landing_start_blocker_backoff_active?(candidate)
    workflow = candidate.workflows
      .where(trigger_kind: WorkDefinitions.landing_workflow_kinds)
      .reorder(id: :desc)
      .detect { |wf| WorkUnits::StartBlock.for(wf).landing_start_blocker? }
    next_check_at = workflow ? WorkUnits::StartBlock.for(workflow).next_check_at : nil

    next_check_at.present? && next_check_at.future?
  end
end
