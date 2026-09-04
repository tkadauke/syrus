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
    return if preserve_train_for_continuation_retry?

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
      LandingFailureHandler.call(job: job, reason: reason, run: failed_run) if job.landing?
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

  # The run whose failure ended the train. It carries the Problem the step
  # declared, which is how LandingFailureHandler now tells "rebuild the train"
  # apart from "this train is dead" -- previously that decision was made by
  # regex-matching the prose below, and `stale_base_artifact_reason` existed
  # only to manufacture prose that would match.
  #
  # CaptureRunDiagnostic runs before run.fail!, so the diagnostic exists by
  # the time after_fail fires.
  def failed_run
    return @failed_run if defined?(@failed_run)

    @failed_run = Run.joins(:step)
                     .where(steps: { workflow_id: @workflow.id })
                     .where(state: "failed")
                     .order(id: :desc)
                     .includes(:run_diagnostic)
                     .first
  end

  # Human-readable context for the stale-base case, from the structured
  # artifact Steps::MergeTrainLand writes before raising. This is now only
  # ever read as text -- the routing decision comes from the declared Problem.
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
  def failed_run_error_message
    failed_run&.run_diagnostic&.error_message.presence
  end

  def preserve_train_for_continuation_retry?
    return false if @cancelled

    failed_step = RetryFailedStepEnqueuer.failed_step_for(@workflow)
    return false unless failed_step

    @workflow.work_definition.retry_policy.continuation?(failed_step)
  end

  def merge_train
    id = @workflow.artifact("merge_train_id")
    return if id.blank?

    MergeTrain.find_by(id: id)
  end
end
