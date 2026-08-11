class WorkflowAdmissionControlWakeup
  Result = Data.define(:workflow_ids, :auto_retry_attempt_ids) do
    def workflow_count = workflow_ids.size
    def auto_retry_count = auto_retry_attempt_ids.size
  end

  def self.call = new.call

  def call
    workflow_ids = wake_deferred_workflows
    auto_retry_attempt_ids = wake_auto_retries
    LandingQueueProcessorJob.perform_later
    Result.new(workflow_ids: workflow_ids, auto_retry_attempt_ids: auto_retry_attempt_ids)
  end

  private

  def wake_deferred_workflows
    Workflow
      .where(state: %w[queued running])
      .where("artifacts LIKE ? OR artifacts LIKE ?", "%#{StepDispatcher::ADMISSION_BLOCK_REASON}%", '%"pause_reason"%')
      .filter_map do |workflow|
        next unless admission_or_resource_paused?(workflow)

        WorkflowPhaseAdmissionJob.perform_later(workflow.id)
        workflow.id
      end
  end

  def wake_auto_retries
    AutoRetryAttempt
      .includes(:job)
      .where(performed_at: nil, skipped_reason: nil)
      .where("scheduled_at > ?", Time.current)
      .find_each
      .map do |attempt|
        attempt.update!(skipped_reason: "workflow admission control changed; reconciler will retry immediately")
        WorkEngine::Reconciler.request(source: self.class.name, job: attempt.job)
        attempt.id
      end
  end

  def admission_or_resource_paused?(workflow)
    workflow.artifact("start_blocked_reason").to_s.in?(admission_pause_reasons) ||
      workflow.artifact("pause_reason").to_s.in?(admission_pause_reasons)
  end

  def admission_pause_reasons
    [
      StepDispatcher::ADMISSION_BLOCK_REASON,
      StepDispatcher::PAUSE_REASON_RESOURCE_SAFETY
    ]
  end
end
