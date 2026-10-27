# Reverts an Epic merge-train's member Jobs when the train workflow
# fails or is cancelled, reusing the per-PR landing-failure semantics so
# transient blockers auto-retry and genuine failures require operator
# re-approval. See docs/plans/landing-merge-train.md.
class MergeTrainFailureHandler
  class_attribute :multisect_evaluator, default: nil

  # How long a preserved train waits before its relaunch runs. Long enough
  # that the failing workflow's own terminal bookkeeping (WorkUnit sync,
  # workspace release) has settled, short enough to stay well inside the
  # reconciler's stale-train grace.
  PRESERVED_RELAUNCH_DELAY = 30.seconds

  def self.call(workflow:, cancelled: false, allow_preservation: true)
    new(workflow: workflow, cancelled: cancelled, allow_preservation: allow_preservation).call
  end

  # `allow_preservation: false` is the teardown entry point: the relaunch a
  # preservation decision promised could not be delivered, so the train has to
  # be terminalized for its real failure reason instead of being left active
  # for the stale-train reaper to blame on missing runtime.
  def initialize(workflow:, cancelled: false, allow_preservation: true)
    @workflow = workflow
    @cancelled = cancelled
    @allow_preservation = allow_preservation
  end

  def call
    train = merge_train
    return unless train
    return handle_agent_withdrawal!(train) if agent_withdrawn_job_id.present?
    return if preserve_train!(train)

    reason = failure_reason
    return if preserve_train_for_terminal_multisect_result?
    return if !@cancelled && start_multisect_rung!(train)

    unless train.terminal?
      train.update!(
        state: @cancelled ? "cancelled" : "failed",
        failure_reason: reason.truncate(500),
        failure_code: failure_code.code,
        finished_at: Time.current
      )
    end

    delete_integration_branch(train) unless preserve_branch_for_fix_replay?(train)

    train.members.each do |member|
      next if member.state == "merged"

      job = member.job

      # Failure handling may be delayed until after the landing queue has
      # already placed this Job on a replacement train. The old train no
      # longer owns the Job in that case and must not defer/fail it out from
      # under the replacement. Its own member row is still terminalized below
      # so cleanup remains complete.
      if owned_by_replacement_landing_work?(job)
        member.update!(state: "failed", reason: reason.truncate(500))
        next
      end

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
      LandingFailureHandler.call(job: job, reason: reason, run: failed_run, problem: failure_problem) if job.landing?
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
  # `merge_train_build` publishes the integration branch so the rest of the
  # chain can be picked up by any worker. A train that never lands would
  # otherwise leave that branch behind for good, so retire it here -- the
  # successful path already does the same in Steps::MergeTrainLand.
  # Never fatal: the branch is disposable, the member revert above is not.
  def delete_integration_branch(train)
    branch = train.integration_branch
    return if branch.blank?
    return if @workflow.job.nil?

    github_client.delete_branch(@workflow.job.repository.slug, branch)
  rescue StandardError => e
    Rails.logger.warn("[MergeTrainFailureHandler] could not delete #{branch}: #{e.class}: #{e.message}")
  end

  def already_landed?(job)
    return false unless integration_merge_sha

    LandedCommit.where(landable: job, kind: "implementation")
      .where("created_at >= ?", @workflow.created_at)
      .exists?
  end

  def owned_by_replacement_landing_work?(job)
    active = WorkUnits::Ownership.active_landing_work_for_job(job)
    active&.workflow&.id.present? && active.workflow.id != @workflow.id
  end

  def complete_landing!(member, job)
    job.update_column(:landed_sha, integration_merge_sha)
    reconcile_member_pull_request!(job)
    job.close_with_reason!("pr_merged") if job.may_close?
    member.update!(state: "merged")
    log_self_healed!(job)
  end

  # Same PR reconciliation (comment + close) the happy path uses in
  # Steps::MergeTrainLand#reconcile_member_pull_request_after_landing -- a
  # self-healed member never went through an integration PR merge here, so
  # nothing else ever comments on or closes its GitHub PR, leaving it open
  # forever even though the Job itself lands correctly.
  def reconcile_member_pull_request!(job)
    MergeTrainMemberPrReconciler.call(
      client: github_client,
      repository: @workflow.job.repository,
      train: merge_train,
      member_job: job,
      integration_pr: nil,
      log: ->(message, kind: nil) { job_log(job, message, kind: kind) }
    )
  rescue StandardError => e
    Rails.logger.warn("[MergeTrainFailureHandler] could not reconcile PR for #{job.slug}: #{e.class}: #{e.message}")
  end

  def github_client
    @github_client ||= GithubClient.for(repository: @workflow.job.repository, user: @workflow.job.user)
  end

  def log_self_healed!(job)
    job_log(
      job,
      "merge_train: #{job.slug} was already landed at #{integration_merge_sha.to_s.first(9)} when the train " \
      "failed; closed pr_merged instead of reverting and closed its PR. Its branch may still need manual GitHub cleanup."
    )
  end

  def job_log(job, message, kind: "system")
    log_run = failed_run || job.current_run
    return unless log_run

    JobLog.append!(run: log_run, kind: kind, chunk: message)
  rescue StandardError => e
    Rails.logger.warn("[MergeTrainFailureHandler] failed to log for #{job.slug}: #{e.class}: #{e.message}")
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
      failed_run_classification_reason ||
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
                     .includes(:run_diagnostic, :run_failure_classification)
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

  def failure_problem
    return @failure_problem if defined?(@failure_problem)

    code = failed_run&.run_diagnostic&.problem_code.presence ||
      failed_run&.run_failure_classification&.classification.presence
    @failure_problem = Problem.resolve(code) if code.present?
  end

  def failure_code
    @failure_code ||= LandingFailureCode.from_problem(failure_problem) ||
      LandingFailureCode.legacy_from_reason(failure_reason) ||
      LandingFailureCode.fetch(LandingFailureCode::ATTRIBUTABLE_FAILURE)
  end

  # A run whose worker died leaves no diagnostic -- CaptureRunDiagnostic runs
  # inside the process that just disappeared -- so every fallback above comes
  # back empty and the train was recorded with the literal string
  # "merge_train failed". Twelve trains carry that and are unclassifiable after
  # the fact; all of the ones still inspectable turned out to be worker deaths.
  #
  # RunFailureClassifier reaches the same conclusion from the outside, and its
  # verdict is written whether or not the process survived. Using it here does
  # two things: the operator sees what happened, and LandingFailureHandler's
  # TRANSIENT_BLOCKER_PATTERNS can match `worker_died` and defer instead of
  # clearing every member's approval for something that says nothing about the
  # work.
  def failed_run_classification_reason
    classification = failed_run&.run_failure_classification
    return nil if classification.nil?

    detail = classification.reason.presence
    [ "merge_train run failed: #{classification.classification}", detail ].compact.join(" — ")
  end

  # Preservation is an act of scheduling, not of omission.
  #
  # Both preserve paths used to answer "keep this train" by returning early,
  # and nothing anywhere then asked the preserved train to continue. Nothing
  # searches for preserved trains; the landing queue will not replace a train
  # that is still active; and the ladder's own attempt counter only advances
  # when an AutoRetryAttempt exists, so a preserved train never even escalated
  # to the next rung. The train sat active with a failed workflow and no
  # runtime until `WorkEngine::Reconciler`'s stale-train reaper failed it two
  # minutes later for "no active Workflow or WorkUnit owns it" -- which threw
  # away the real failure reason and spent the landing lock on nothing.
  #
  # So preservation now only stands if a relaunch was actually scheduled. When
  # it cannot be (no failed step to resume, the workspace is gone, the ladder's
  # retry budget is spent, or the attempt could not be written), this returns
  # false and the caller tears the train down for its real reason -- the same
  # answer as before preservation existed, which is the conservative one.
  def preserve_train!(train)
    return false unless @allow_preservation
    return false unless preserve_train_for_continuation_retry? || preserve_train_for_failure_policy?

    schedule_preserved_train_relaunch!(train)
  end

  def schedule_preserved_train_relaunch!(train)
    failed_step = RetryFailedStepEnqueuer.failed_step_for(@workflow)
    return refuse_preservation("no failed step to resume") unless failed_step
    return refuse_preservation("the workflow workspace is already cleaned up") unless @workflow.retry_available?

    # The generic reconciler path writes AutoRetryAttempts for this workflow
    # too (that is also how the ladder counts attempts). A pending one already
    # owns recovery, so preservation stands on it rather than racing a second
    # attempt onto the same step.
    if (pending = @workflow.auto_retry_attempts.pending.order(:scheduled_at, :id).first)
      job_log(
        @workflow.job,
        "merge_train: preserving #{train.label}; #{pending.retry_kind} auto-retry attempt " \
        "##{pending.id} already owns the relaunch (due #{pending.scheduled_at.iso8601})"
      )
      return true
    end

    attempt = nil
    scheduled_at = Time.current + PRESERVED_RELAUNCH_DELAY
    ActiveRecord::Base.transaction do
      # Tier 1 of the remediation resolution rule (see Remediation::Resolver):
      # a runtime patch on this one step instance. Without it the merge-train
      # retry policy answers `rebuild_unit` for every step kind preservation
      # cares about -- assemble, reconcile, land -- and the rebuild then asks
      # the dispatcher for a brand-new train, which refuses while this one is
      # still active. The override is what makes "the retry reuses what was
      # already assembled" true rather than aspirational; the enqueuer clears
      # it once consumed, so it never silently governs a later failure.
      failed_step.update!(details: failed_step.details.to_h.merge("remediation" => "resume_step"))

      attempt = AutoRetryAttempt.create!(
        job: @workflow.job,
        workflow: @workflow,
        run: failed_run,
        agent_provider: relaunch_agent_provider,
        failure_classification: failure_policy_retry_classification,
        retry_kind: AutoRetryAttempt::PRESERVED_MERGE_TRAIN_RETRY_KIND,
        attempt_number: failure_policy_attempt_number,
        scheduled_at: scheduled_at
      )

      # Inside the transaction with the attempt it drives, so the two cannot
      # disagree. A rolled-back attempt leaves at most an enqueued job with no
      # record, which AutoRetryJob discards; the reverse -- an attempt nothing
      # ever runs -- would read as a pending relaunch and block the train's
      # other recovery paths while delivering nothing.
      AutoRetryJob.set(wait_until: scheduled_at, priority: @workflow.job&.solid_queue_priority).perform_later(attempt.id)
    end

    record_relaunch_backoff(attempt)
    job_log(
      @workflow.job,
      "merge_train: preserving #{train.label} (#{train.members.size} PR(s)); " \
      "relaunching #{failed_step.kind} at #{scheduled_at.iso8601} via auto-retry attempt ##{attempt.id}"
    )
    true
  rescue StandardError => e
    Rails.logger.warn(
      "[MergeTrainFailureHandler] could not schedule preserved relaunch for MergeTrain ##{train.id}: #{e.class}: #{e.message}"
    )
    refuse_preservation("the relaunch could not be scheduled (#{e.class})")
  end

  # Bookkeeping, not part of the promise: the relaunch is already scheduled by
  # the time this runs, so a failure here must not be allowed to retract the
  # preservation decision and tear the train down on top of it.
  def record_relaunch_backoff(attempt)
    WorkUnits::AutoRetryBackoff.record!(attempt)
  rescue StandardError => e
    Rails.logger.warn("[MergeTrainFailureHandler] could not record relaunch backoff for attempt ##{attempt.id}: #{e.class}: #{e.message}")
  end

  def refuse_preservation(reason)
    job_log(@workflow.job, "merge_train: not preserving the train -- #{reason}; tearing it down instead")
    false
  end

  def relaunch_agent_provider
    failed_run&.agent_provider.presence ||
      @workflow.agent_provider.presence ||
      @workflow.job&.agent_provider
  end

  def preserve_train_for_continuation_retry?
    return false if @cancelled

    failed_step = RetryFailedStepEnqueuer.failed_step_for(@workflow)
    return false unless failed_step

    @workflow.work_definition.retry_policy.continuation?(failed_step)
  end

  # `restart` (the default) tears the assembly down and hands every member
  # back individually, so the next attempt rebuilds membership from the
  # approved pool and regrades from scratch. Under `keep_assembly`, or the
  # first rung of `keep_fixes`, an infrastructure failure leaves the train
  # and its integration branch intact instead, so the retry reuses what was
  # already assembled. Rebuild-required failures are excluded because the
  # assembly is known stale; `keep_fixes` can still preserve its branch for
  # repair replay after the train is terminalized.
  #
  # Only failures that are not a member's own fault qualify. A member whose
  # code broke the train must still fail out; preserving the assembly around it
  # would wedge the train on the same defect indefinitely. A failure we cannot
  # attribute is treated as the member's, which keeps the default conservative.
  def preserve_train_for_failure_policy?
    return false if @cancelled
    return false if MergeTrainFixReplay.stale_base_rebuild_required?(@workflow)

    resolved_failure_policy.preserve_train?(preservable_failure: preservable_failure?)
  end

  # Steps that run before any member's code is exercised, or after grading has
  # already passed. A failure here is the train's own machinery -- an assemble
  # that lost the landing lock, a reconcile that could not reach the forge, a
  # land whose base moved underneath it -- and tearing the assembly down for it
  # rebuilds and regrades the identical members, which costs 45-167 minutes of
  # a landing lock that is already the throughput ceiling.
  #
  # `merge_train_build` is deliberately absent: a conflict while rebasing
  # members into the integration branch IS a member's fault. So is anything in
  # the grade loop, and so is `prepare` (a member can break dependency install).
  TRAIN_ATTRIBUTED_STEP_KINDS = %w[
    merge_train_assemble
    merge_train_reconcile
    merge_train_land
    merge_train_land_after_rebase
  ].freeze

  # Retryability was the original proxy for "not the member's fault" and it is
  # wrong in the direction that matters: an assemble-step LockConflict, a base
  # that moved mid-start, and `no_capable_worker` are all classified
  # non-retryable AND are nobody's code, so every one of them tore down a sound
  # assembly. Retryable still qualifies on its own; step attribution only adds
  # the non-retryable train-level failures it was missing.
  # Causes that are never the member's fault, wherever they occur.
  #
  # TRAIN_ATTRIBUTED_STEP_KINDS asks *where* a failure happened. That is the
  # right question for a conflict or a base that moved, and the wrong one for a
  # run that never executed the member's code at all. `no_capable_worker` is
  # the clearest case: no live worker advertised the capability the step needs,
  # so the assembly is sound and rebuilding it changes nothing about the
  # outcome. It arrives on a `grader` -- a step kind deliberately attributed to
  # the member, because a failing test *is* the member's fault -- and so it
  # tore down 14 sound assemblies in a single day, each costing 45-167 minutes
  # of a landing lock that is already the throughput ceiling.
  #
  # Keyed on the run outcome rather than the classification because
  # RunFailureClassifier files this under the generic `application_error`
  # fallback with retryable: false, which is exactly why retryability did not
  # catch it.
  TRAIN_ATTRIBUTED_RUN_OUTCOMES = %w[ no_capable_worker ].freeze

  def preservable_failure?
    return true if retryable_failure?
    return true if train_attributed_outcome?

    TRAIN_ATTRIBUTED_STEP_KINDS.include?(failed_step_kind)
  end

  def train_attributed_outcome?
    TRAIN_ATTRIBUTED_RUN_OUTCOMES.include?(failed_run&.agent_outcome.to_s)
  end

  def retryable_failure?
    failed_run&.run_failure_classification&.retryable == true
  end

  def failed_step_kind
    (failed_run&.step || @workflow.steps.where(state: "failed").order(:position).last)&.kind.to_s
  end

  def preserve_train_for_terminal_multisect_result?
    return false if @cancelled

    result = @workflow.artifact(MergeTrainMultisect::ARTIFACT_KEY).to_h
    return false unless result["status"].in?(%w[attributed aborted])

    job_log(
      @workflow.job,
      "merge_train: focused multisect recorded #{result['reason']}; preserving the train for the next rung or operator review.",
      kind: "system"
    )
    true
  end

  def handle_agent_withdrawal!(train)
    reason = failure_reason
    unless train.terminal?
      train.update!(state: @cancelled ? "cancelled" : "failed", failure_reason: reason.truncate(500), finished_at: Time.current)
    end
    delete_integration_branch(train)

    train.members.includes(:job).each do |member|
      job = member.job
      if member.job_id == agent_withdrawn_job_id
        LandingFailureHandler.call(job: job, reason: reason, run: nil) if job&.landing?
      elsif job&.landing? && job.may_defer_landing?
        job.landing_failure_reason = "merge_train_agent withdrew another member; rederive train without it"
        job.defer_landing!
        job.save! if job.changed?
      end
      member.update!(state: "failed", reason: reason.truncate(500)) unless member.state == "merged"
    end
  end

  def agent_withdrawn_job_id
    return @agent_withdrawn_job_id if defined?(@agent_withdrawn_job_id)

    id = @workflow.artifact(Steps::MergeTrainAgent::WITHDRAWN_JOB_ID_ARTIFACT).to_i
    @agent_withdrawn_job_id = id.positive? ? id : nil
  end

  def start_multisect_rung!(train)
    config = merge_train_config

    # Each guard reports itself. Multisect ran zero times across a week of
    # failed trains with `failure_rungs: [multisect]` configured, and because
    # every guard returned a bare false there was no way to tell which one --
    # the config not loading, an artifact already present, or the workflow
    # being unable to reopen because a newer workflow had superseded it.
    declined = multisect_decline_reason(config)
    if declined
      job_log(@workflow.job, "merge_train: multisect rung not started (#{declined})")
      return false
    end

    failed_step = failed_run&.step || @workflow.steps.where(state: "failed").order(:position).last

    prepare_step = nil
    Step.transaction do
      continuation = failed_step.next_step
      insertion_position = failed_step.position + 1
      @workflow.steps.where("position >= ?", insertion_position).update_all([ "position = position + ?", 2 ])
      prepare_step = Step.create!(
        workflow: @workflow,
        kind: "merge_train_multisect_prepare",
        position: insertion_position,
        placement_policy: Step::Kind.fetch("merge_train_multisect_prepare").placement_policy_for(@workflow.job.repository),
        depends_on_ids: [ failed_step.id ],
        details: {
          "selected_rung" => "multisect",
          "merge_train_id" => train.id,
          "failed_step_id" => failed_step.id,
          "failed_step_kind" => failed_step.kind
        }
      )
      collect_step = Step.create!(
        workflow: @workflow,
        kind: "merge_train_multisect_collect",
        position: insertion_position + 1,
        placement_policy: Step::Kind.fetch("merge_train_multisect_collect").placement_policy_for(@workflow.job.repository),
        depends_on_ids: [ prepare_step.id ],
        details: { "round" => 0, "phase" => "prepare" }
      )

      failed_step.update!(next_step_id: prepare_step.id)
      prepare_step.update!(next_step_id: collect_step.id)
      collect_step.update!(next_step_id: continuation&.id)
      continuation&.update!(depends_on_ids: [ collect_step.id ])
      @workflow.artifacts = @workflow.artifacts.to_h.merge(
        Steps::MergeTrainMultisectStep::STARTED_ARTIFACT_KEY => Time.current.iso8601,
        "merge_train_multisect_selected_rung" => "multisect"
      )
      @workflow.reopen!
      @workflow.save!
    end

    job_log(@workflow.job, "merge_train: starting visible focused multisect attribution rung", kind: "system")
    StepDispatcher.create_run_and_enqueue(prepare_step, @workflow)
    true
  rescue StandardError => e
    Rails.logger.warn("[MergeTrainFailureHandler] merge_train_multisect failed: #{e.class}: #{e.message}")
    false
  end

  # nil when the rung may start; otherwise the reason it may not, in the same
  # order the guards used to run.
  def multisect_decline_reason(config)
    return "not configured in merge_train.failure_rungs" unless config&.failure_rungs&.include?("multisect")
    return "already started for this workflow" if @workflow.artifact(Steps::MergeTrainMultisectStep::STARTED_ARTIFACT_KEY).present?
    return "a result is already recorded" if @workflow.artifact(MergeTrainMultisect::ARTIFACT_KEY).present?
    return "no failed step to bisect from" unless failed_run&.step || @workflow.steps.where(state: "failed").order(:position).last

    unless @workflow.may_reopen?
      return "workflow cannot reopen" if @workflow.send(:latest_for_job?)

      return "workflow cannot reopen: a newer workflow has superseded it on #{@workflow.job&.slug}"
    end

    nil
  end

  def merge_train_config
    loaded = RepoDefaultBranchSyrusYml.for_job(@workflow.job)
    return nil unless loaded.loaded?

    loaded.config&.merge_train
  end

  # Gated on the rung as the failure-policy comment always claimed it was. The
  # rung was never asked, so `keep_fixes` preserved nothing `keep_assembly`
  # did not, and the branch was kept on every rung including `restart` --
  # whose entire purpose is to tear the assembly down.
  def preserve_branch_for_fix_replay?(train)
    return false if @cancelled
    return false unless resolved_failure_policy.preserve_branch_for_replay?

    MergeTrainFixReplay.eligible_source?(train)
  end

  def resolved_failure_policy
    @resolved_failure_policy ||= MergeTrainFailurePolicy.resolve(
      repository: @workflow.job&.repository,
      attempt_number: failure_policy_attempt_number,
      retry_classification: failure_policy_retry_classification
    ).tap do |rung|
      # A week of failed trains left no record of what the ladder decided --
      # not the rung, not why preservation was refused, not which multisect
      # guard declined. Tuning a ladder you cannot observe is guesswork, so
      # every decision this handler makes now says so once, on the Job.
      job_log(
        @workflow.job,
        "merge_train: failure rung #{rung.class.name} " \
        "(attempt #{failure_policy_attempt_number}, " \
        "classification #{failure_policy_retry_classification}, " \
        "failed step #{failed_step_kind.presence || 'unknown'}, " \
        "retryable=#{retryable_failure?}, preservable=#{preservable_failure?})"
      )
    end
  end

  def failure_policy_attempt_number
    run = failed_run
    return 1 unless run

    AutoRetryAttempt.budget_scope_for(
      job: run.job,
      agent_provider: run.agent_provider.presence || run.workflow&.agent_provider,
      failure_classification: failure_policy_retry_classification
    ).count + 1
  end

  def failure_policy_retry_classification
    failed_run&.run_failure_classification&.classification || failed_run&.agent_outcome.to_s.presence || "unknown"
  end

  def merge_train
    return @merge_train if defined?(@merge_train)

    id = @workflow.artifact("merge_train_id")
    @merge_train = id.present? ? MergeTrain.find_by(id: id) : nil
  end
end
