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

      # A land step can fail AFTER GitHub genuinely merged the integration
      # branch (e.g. a crash between the merge and this member's own
      # bookkeeping finishing in Steps::MergeTrainLand#reconcile_members!).
      # "the workflow failed" does not mean "this member's work is lost" --
      # check for positive evidence one way or the other before reverting.
      if already_landed?(job)
        complete_landing!(member, job)
        next
      end

      # LandingFailureHandler classifies the reason: transient/infra
      # blockers defer_landing (stay approved, auto-retry), genuine
      # failures fail_landing (-> implemented, approval cleared, requires
      # operator re-approval).
      LandingFailureHandler.call(job: job, reason: reason, run: failed_run) if job.landing?
      member.update!(state: "failed", reason: reason.truncate(500))
    end
  end

  private

  # Positive evidence a member's commits are already safely on base: the
  # train actually landed a real integration merge (record_integration_merge_commit!
  # ran before Steps::MergeTrainLand#reconcile_members! could crash), and this
  # member's own rebased commits (record_member_commits! in
  # Steps::MergeTrainBuild) were recorded during this same workflow attempt.
  # Scoped by @workflow.created_at so a LandedCommit trail left by a much
  # earlier failed/rebuilt attempt for the same Job can't be mistaken for
  # evidence from the attempt that just failed.
  def already_landed?(job)
    return false unless integration_merge_sha

    LandedCommit.where(landable: job, kind: "implementation")
      .where("created_at >= ?", @workflow.created_at)
      .exists?
  end

  def complete_landing!(member, job)
    job.update_column(:landed_sha, integration_merge_sha)
    job.close_with_reason!("pr_merged") if job.may_close?
    member.update!(state: "merged")
    log_self_healed!(job)
  end

  def log_self_healed!(job)
    log_run = failed_run || job.current_run
    return unless log_run

    JobLog.append!(
      run: log_run,
      kind: "system",
      chunk: "merge_train: #{job.slug} was already landed at #{integration_merge_sha.to_s.first(9)} when the train " \
             "failed; closed pr_merged instead of reverting. Its PR/branch may still need manual GitHub cleanup."
    )
  rescue StandardError => e
    Rails.logger.warn("[MergeTrainFailureHandler] failed to log self-healed landing for #{job.slug}: #{e.class}: #{e.message}")
  end

  def integration_merge_sha
    return @integration_merge_sha if defined?(@integration_merge_sha)

    landable = merge_train_landable
    @integration_merge_sha = landable && LandedCommit
      .where(landable: landable, kind: "integration_merge")
      .where("created_at >= ?", @workflow.created_at)
      .order(:created_at)
      .last&.sha
  end

  # Same attribution rule as Steps::MergeTrainStep#landed_commit_landable:
  # the Epic for an Epic-backed train, the MergeTrain itself for a
  # bundle-backed train.
  def merge_train_landable(train = merge_train)
    return train.epic if train.epic_backed?
    return train if train.bundle_backed?

    nil
  end

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
    return @merge_train if defined?(@merge_train)

    id = @workflow.artifact("merge_train_id")
    @merge_train = id.present? ? MergeTrain.find_by(id: id) : nil
  end
end
