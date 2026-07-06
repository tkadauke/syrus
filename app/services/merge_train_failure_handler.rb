# Reverts an Epic merge-train's member Jobs when the train workflow
# fails or is cancelled, reusing the per-PR landing-failure semantics so
# transient blockers auto-retry and genuine failures require operator
# re-approval. See docs/plans/landing-merge-train.md.
class MergeTrainFailureHandler
  def self.call(workflow:, cancelled: false) = new(workflow: workflow, cancelled: cancelled).call

  def initialize(workflow:, cancelled: false)
    @workflow = workflow
    @cancelled = cancelled
  end

  def call
    train = merge_train
    return unless train

    reason = failure_reason
    unless train.terminal?
      train.update!(state: @cancelled ? "cancelled" : "failed", failure_reason: reason.truncate(500), finished_at: Time.current)
    end

    train.members.each do |member|
      next if member.state == "merged"

      job = member.job
      # LandingFailureHandler classifies the reason: transient/infra
      # blockers defer_landing (stay approved, auto-retry), genuine
      # failures fail_landing (-> implemented, approval cleared, requires
      # operator re-approval).
      LandingFailureHandler.call(job: job, reason: reason) if job.landing?
      member.update!(state: "failed", reason: reason.truncate(500))
    end
  end

  private

  def failure_reason
    (@workflow.failure_reason.presence ||
      @workflow.artifact("failure_reason").presence ||
      stale_base_artifact_reason ||
      failed_run_error_message ||
      (@cancelled ? "merge_train cancelled" : "merge_train failed")).to_s
  end

  # Reconstruct the stale-base reason string from the structured artifact
  # that Steps::MergeTrainLand writes before raising StepFailed. This lets
  # LandingFailureHandler match merge_train_rebuild_required? even when the
  # workflow's failure_reason column was never populated (StepDispatcher
  # hard_fail_workflow! is called with no reason for ordinary step failures).
  def stale_base_artifact_reason
    stale = @workflow.artifact(Steps::MergeTrainLand::STALE_BASE_ARTIFACT)
    return unless stale.is_a?(Hash)

    case stale["reason"]
    when "base_moved"
      built   = stale["built_base_sha"].to_s.first(12)
      current = stale["current_base_sha"].to_s.first(12)
      "#{Steps::MergeTrainLand::STALE_BASE_FAILURE_PREFIX} from #{built} to #{current}; rebuild required"
    when "missing_built_base_sha"
      "#{Steps::MergeTrainLand::MISSING_BASE_FAILURE_PREFIX}; rebuild required"
    end
  end

  # Fall back to the failed run's diagnostic error message when neither
  # workflow.failure_reason nor any workflow artifact carries the reason.
  # CaptureRunDiagnostic is called before run.fail!, so the diagnostic
  # row exists by the time after_fail fires.
  def failed_run_error_message
    run_id = Run.joins(:step)
               .where(steps: { workflow_id: @workflow.id })
               .where(state: "failed")
               .order(id: :desc)
               .pick(:id)
    return unless run_id

    RunDiagnostic.where(run_id: run_id).pick(:error_message).presence
  end

  def merge_train
    id = @workflow.artifact("merge_train_id")
    return if id.blank?

    MergeTrain.find_by(id: id)
  end
end
