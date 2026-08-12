class StepDispatcher
  # When a Step transitions to `succeeded`, find the next runnable
  # step in its workflow's chain and create a Run on it. If there
  # is no next runnable step (chain end OR all downstream steps
  # cancelled), transition the Workflow itself to succeeded.
  #
  # Wired up via Step#after_update_commit when state → succeeded.
  def self.advance_from(step)
    new(step.workflow, advancing_from: step).advance!
  end

  # Kick off a freshly-instantiated Workflow. Caller (Job#after_
  # create_commit for issue Jobs, polling jobs for follow-up
  # workflows) instantiates Workflows::* in a transaction; once
  # the transaction commits, calls this to create the first Run
  # and let SQ pick it up.
  #
  # Idempotent — if the workflow's first step already has a Run,
  # this is a no-op.
  def self.start_workflow(workflow, parent_session_id: nil, prompt: nil)
    first = workflow.first_step
    return unless first
    return if first.runs.any?

    if workflow.job.closed?
      cancel_unstartable_closed_job_workflow!(workflow)
      return
    end

    if Feature.coding_mode_enabled? && workflow.job.coding?
      Rails.logger.info(
        "[StepDispatcher] workflow #{workflow.id} (#{workflow.trigger_kind}) held: " \
        "job #{workflow.job_id} in coding state (linked_chat_id=#{workflow.job.linked_chat_id})"
      )
      return
    end

    if (blocking_workflow = EpicWorkflowLock.blocking_workflow_for(workflow))
      if workflow.epic_wide?
        cancel_unstartable_epic_workflow_conflict!(workflow, blocking_workflow)
      else
        record_start_blocked!(
          workflow,
          EPIC_WIDE_BLOCK_REASON,
          backoff: START_BLOCKED_BACKOFF,
          details: {
            "blocking_workflow_id" => blocking_workflow.id,
            "blocking_workflow_slug" => blocking_workflow.slug,
            "blocking_trigger_kind" => blocking_workflow.trigger_kind
          }
        )
        WorkflowPhaseAdmissionJob.set(wait: START_BLOCKED_BACKOFF, priority: workflow.job.solid_queue_priority).perform_later(workflow.id)
        warn_if_stuck_queued(workflow, "#{EPIC_WIDE_BLOCK_REASON}: #{blocking_workflow.slug}")
      end
      return
    end
    clear_start_blocked!(workflow, EPIC_WIDE_BLOCK_REASON)

    if manually_paused?(workflow)
      record_manual_pause!(workflow)
      warn_if_stuck_queued(workflow, MANUAL_PAUSE_REASON)
      return
    end
    clear_start_blocked!(workflow, MANUAL_PAUSE_REASON)

    if workflow.job.dependencies_failed_for_execution?
      return fail_unstartable_landing_workflow!(workflow, "landing start blocked: dependency failed") if workflow.landing_workflow?

      cancel_unstartable_rebase_workflow!(workflow, DEPENDENCY_FAILED_BLOCK_REASON)
      unless RebaseWorkflowSelector::TRIGGER_KINDS.include?(workflow.trigger_kind)
        record_start_blocked!(workflow, DEPENDENCY_FAILED_BLOCK_REASON, backoff: START_BLOCKED_BACKOFF) unless start_blocked_backoff_active?(workflow, DEPENDENCY_FAILED_BLOCK_REASON)
      end
      warn_if_stuck_queued(workflow, DEPENDENCY_FAILED_BLOCK_REASON)
      return
    end
    clear_start_blocked!(workflow, DEPENDENCY_FAILED_BLOCK_REASON)

    unless merge_train_workflow?(workflow)
      stack_resolution = JobStackResolver.new(workflow.job, workflow: workflow).resolve!
      unless stack_resolution.ready?
        return fail_unstartable_landing_workflow!(workflow, "landing start blocked: stack dependencies not ready") if workflow.landing_workflow?

        reason = stack_resolution.reason || STACK_BLOCK_REASON
        cancel_unstartable_rebase_workflow!(workflow, reason)
        unless RebaseWorkflowSelector::TRIGGER_KINDS.include?(workflow.trigger_kind)
          record_start_blocked!(workflow, reason, backoff: START_BLOCKED_BACKOFF, details: stack_resolution.blocker) unless start_blocked_backoff_active?(workflow, reason)
        end
        warn_if_stuck_queued(workflow, reason)
        return
      end
      record_stack_resolution_artifacts!(workflow, stack_resolution)
    end
    clear_start_blocked!(workflow, STACK_BLOCK_REASON)
    clear_start_blocked!(workflow, FAN_IN_BLOCK_REASON)

    unless workflow.job.ready_for_execution?
      reason = if workflow.job.blocked_by_epic_before_execution?
        "landing start blocked: waiting for Epic to release"
      else
        "landing start blocked: job not ready for execution"
      end
      return fail_unstartable_landing_workflow!(workflow, reason) if workflow.landing_workflow?

      cancel_unstartable_rebase_workflow!(workflow, JOB_BLOCK_REASON)
      unless RebaseWorkflowSelector::TRIGGER_KINDS.include?(workflow.trigger_kind)
        record_start_blocked!(workflow, JOB_BLOCK_REASON, backoff: START_BLOCKED_BACKOFF) unless start_blocked_backoff_active?(workflow, JOB_BLOCK_REASON)
      end
      warn_if_stuck_queued(workflow, JOB_BLOCK_REASON)
      return
    end
    clear_start_blocked!(workflow, JOB_BLOCK_REASON)

    if main_health_blocking?(workflow)
      reason = MAIN_HEALTH_BLOCK_REASON
      return if start_blocked_backoff_active?(workflow, reason)

      record_start_blocked!(workflow, reason, backoff: START_BLOCKED_BACKOFF)
      warn_if_stuck_queued(workflow, reason)
      return
    end
    clear_start_blocked!(workflow, MAIN_HEALTH_BLOCK_REASON)

    if urgent_blocking?(workflow)
      reason = URGENT_BLOCK_REASON
      return if start_blocked_backoff_active?(workflow, reason)

      record_start_blocked!(workflow, reason, backoff: START_BLOCKED_BACKOFF)
      warn_if_stuck_queued(workflow, reason)
      return
    end
    clear_start_blocked!(workflow, URGENT_BLOCK_REASON)

    provider_pause = ProviderAvailabilityPause.call(workflow: workflow)
    if provider_pause.pause?
      backoff = provider_pause.retry_at ? provider_pause.retry_at - Time.current : START_BLOCKED_BACKOFF
      record_pause!(
        workflow,
        PROVIDER_AVAILABILITY_BLOCK_REASON,
        backoff: [ backoff, START_BLOCKED_BACKOFF.to_i ].max.seconds,
        details: provider_pause.details
      )
      WorkflowPhaseAdmissionJob.set(wait_until: provider_pause.retry_at, priority: workflow.job.solid_queue_priority).perform_later(workflow.id)
      schedule_landing_queue_recheck!(workflow, [ provider_pause.retry_at - Time.current, START_BLOCKED_BACKOFF.to_i ].max.seconds) if workflow.landing_workflow?
      warn_if_stuck_queued(workflow, "#{PROVIDER_AVAILABILITY_BLOCK_REASON}: #{provider_pause.reason}")
      return
    end
    clear_start_blocked!(workflow, PROVIDER_AVAILABILITY_BLOCK_REASON)

    admission = WorkflowAdmissionBudget.call(workflow: workflow)
    unless admission.admit?
      reason = ADMISSION_BLOCK_REASON
      backoff = admission.delay_until ? admission_backoff(admission) : START_BLOCKED_BACKOFF

      if workflow.landing_workflow?
        details = admission.artifact
        block_landing_for_admission!(
          workflow,
          backoff: backoff,
          details: details,
          extra_artifacts: {
            "workflow_admission_decision" => details,
            "workflow_admission_decided_at" => Time.current.iso8601
          }
        )
        warn_if_stuck_queued(workflow, "#{reason}: #{admission.reason}")
        return
      end

      return if start_blocked_backoff_active?(workflow, reason)

      record_start_blocked!(
        workflow,
        reason,
        backoff: backoff,
        details: admission.artifact
      )
      WorkflowPhaseAdmissionJob.set(wait: backoff, priority: workflow.job.solid_queue_priority).perform_later(workflow.id)
      warn_if_stuck_queued(workflow, "#{reason}: #{admission.reason}")
      return
    end
    record_admission_decision!(workflow, admission)
    clear_start_blocked!(workflow, ADMISSION_BLOCK_REASON)

    run = create_run_and_enqueue(first, workflow,
                                 parent_session_id: parent_session_id,
                                 prompt: prompt,
                                 check_phase_admission: false)
    workflow.job.log_pending_dependency_warnings!
    log_prepare_skip(run, workflow)
    run
  end

  # Rebase and stack-rebase workflows must proceed even when main is broken —
  # they may be part of the recovery path. main_grader IS the health-check
  # workflow, so it must never be blocked by the state it is trying to measure.
  # The fix-main direct job must also be exempt: it IS the recovery agent.
  MAIN_HEALTH_EXEMPT_TRIGGERS = %w[ rebase stack_rebase main_grader ].freeze
  URGENT_EXEMPT_TRIGGERS = %w[ main_grader ].freeze
  MAIN_HEALTH_BLOCK_REASON = "main_branch_broken"
  URGENT_BLOCK_REASON = "urgent_job_active"
  DEPENDENCY_FAILED_BLOCK_REASON = "dependency_failed"
  STACK_BLOCK_REASON = "stack_dependencies_not_ready"
  FAN_IN_BLOCK_REASON = JobStackResolver::FAN_IN_BLOCK_REASON
  JOB_BLOCK_REASON = "job_not_ready_for_execution"
  ADMISSION_BLOCK_REASON = "workflow_admission_budget"
  PROVIDER_AVAILABILITY_BLOCK_REASON = "provider_availability"
  EPIC_WIDE_BLOCK_REASON = EpicWorkflowLock::BLOCK_REASON
  PAUSE_REASON_ADMISSION = ADMISSION_BLOCK_REASON
  PAUSE_REASON_RESOURCE_SAFETY = "resource_safety"
  MANUAL_PAUSE_REASON = "manual_pause"
  PHASE_ADMISSION_RECHECK_DELAY = 10.minutes
  START_BLOCKED_BACKOFF = 5.minutes

  def self.manually_paused?(workflow)
    workflow.job.manual_paused?
  end

  def self.main_health_blocking?(workflow)
    return false if MAIN_HEALTH_EXEMPT_TRIGGERS.include?(workflow.trigger_kind)
    return false if MainHealthChangedService.fix_main_job?(workflow.job)

    repository = workflow.job.repository
    return false unless repository.main_branch_health_enabled?

    repository.landing_paused? && repository.main_health_broken?
  end

  def self.merge_train_workflow?(workflow)
    workflow.trigger_kind == "merge_train" && workflow.artifact("merge_train_id").present?
  end

  def self.urgent_blocking?(workflow)
    return false if URGENT_EXEMPT_TRIGGERS.include?(workflow.trigger_kind)
    return false if workflow.job.priority == "urgent"

    workflow.job.repository.jobs
      .where(priority: "urgent")
      .where.not(state: "closed")
      .exists?
  end

  def self.start_blocked_backoff_active?(workflow, reason)
    return false unless workflow.artifact("start_blocked_reason") == reason

    next_check_at = parse_artifact_time(workflow.artifact("start_blocked_next_check_at"))
    next_check_at.present? && next_check_at.future?
  end

  def self.record_start_blocked!(workflow, reason, backoff:, details: nil)
    now = Time.current
    current = workflow.artifacts || {}
    same_reason = current["start_blocked_reason"] == reason
    blocked_since = same_reason ? current["start_blocked_at"] : nil
    current_count = same_reason ? current["start_blocked_count"].to_i : 0
    artifacts = current.merge(
        "start_blocked_reason" => reason,
        "start_blocked_at" => blocked_since.presence || now.iso8601,
        "start_blocked_last_seen_at" => now.iso8601,
        "start_blocked_next_check_at" => (now + backoff).iso8601,
        "start_blocked_count" => current_count + 1
      )
    if details.present?
      artifacts["start_blocked_details"] = details
    else
      artifacts.delete("start_blocked_details")
    end
    workflow.update!(artifacts: artifacts)
  end

  def self.record_admission_decision!(workflow, decision)
    artifacts = workflow.artifacts.to_h.merge(
      "workflow_admission_decision" => decision.artifact,
      "workflow_admission_decided_at" => Time.current.iso8601
    )
    artifacts["workflow_admission_override"] = decision.artifact if decision.override
    workflow.update!(artifacts: artifacts)
  end

  def self.admission_backoff(admission)
    [ admission.delay_until - Time.current, START_BLOCKED_BACKOFF.to_i ].max.seconds
  end

  def self.record_stack_resolution_artifacts!(workflow, resolution)
    return if resolution.artifacts.blank?

    artifacts = workflow.artifacts.to_h.merge(resolution.artifacts)
    prepared = resolution.artifacts["prepared_stack_base"]
    if prepared.is_a?(Hash) && prepared["branch_name"].present?
      artifacts[RebaseTarget::BASE_BRANCH_ARTIFACT] = prepared["branch_name"]
      artifacts[RebaseTarget::BASE_SHA_ARTIFACT] = prepared["head_sha"] if prepared["head_sha"].present?
    end
    workflow.update!(artifacts: artifacts)
  end

  def self.cancel_unstartable_closed_job_workflow!(workflow)
    workflow.artifacts = (workflow.artifacts || {}).merge(
      "start_cancelled_reason" => "job_closed",
      "start_cancelled_at" => Time.current.iso8601
    )
    workflow.cancel! if workflow.may_cancel?
    workflow.save!
    Rails.logger.info("[StepDispatcher] workflow #{workflow.id} (#{workflow.trigger_kind}) cancelled: job #{workflow.job_id} is closed")
  end

  def self.clear_start_blocked!(workflow, reason)
    return unless workflow.artifact("start_blocked_reason") == reason

    cleared = (workflow.artifacts || {}).except(
      "start_blocked_reason",
      "start_blocked_at",
      "start_blocked_last_seen_at",
      "start_blocked_next_check_at",
      "start_blocked_count",
      "start_blocked_details",
      "pause_reason",
      "pause_kind",
      "pause_started_at",
      "pause_last_seen_at",
      "pause_next_check_at",
      "pause_details"
    )
    workflow.update!(artifacts: cleared)
  end

  def self.parse_artifact_time(value)
    Time.iso8601(value.to_s)
  rescue ArgumentError, TypeError
    nil
  end

  def self.cancel_unstartable_rebase_workflow!(workflow, reason)
    return unless RebaseWorkflowSelector::TRIGGER_KINDS.include?(workflow.trigger_kind)

    workflow.artifacts = (workflow.artifacts || {}).merge(
      "start_blocked_reason" => reason,
      "start_blocked_at" => Time.current.iso8601
    )
    workflow.cancel! if workflow.may_cancel?
    workflow.save!
    nil
  end

  def self.cancel_unstartable_epic_workflow_conflict!(workflow, blocking_workflow)
    workflow.artifacts = (workflow.artifacts || {}).merge(
      "start_cancelled_reason" => EPIC_WIDE_BLOCK_REASON,
      "start_cancelled_at" => Time.current.iso8601,
      "start_cancelled_details" => {
        "blocking_workflow_id" => blocking_workflow.id,
        "blocking_workflow_slug" => blocking_workflow.slug,
        "blocking_trigger_kind" => blocking_workflow.trigger_kind
      }
    )
    workflow.cancel! if workflow.may_cancel?
    workflow.save!
    Rails.logger.info(
      "[StepDispatcher] workflow #{workflow.id} (#{workflow.trigger_kind}) cancelled: " \
      "Epic-wide workflow #{blocking_workflow.id} (#{blocking_workflow.trigger_kind}) is already active"
    )
  end

  def self.fail_unstartable_landing_workflow!(workflow, reason, details: nil, next_check_at: nil, extra_artifacts: {})
    artifacts = (workflow.artifacts || {}).merge(
      "failure_reason" => reason,
      "start_blocked_reason" => reason,
      "start_blocked_at" => Time.current.iso8601
    ).merge(extra_artifacts)
    artifacts["start_blocked_details"] = details if details.present?
    artifacts["start_blocked_next_check_at"] = next_check_at.iso8601 if next_check_at.present?
    workflow.artifacts = artifacts
    workflow.failure_reason = reason
    workflow.fail! if workflow.may_fail?
    workflow.save!
    nil
  end

  def self.block_landing_for_admission!(workflow, backoff:, details: nil, extra_artifacts: {})
    now = Time.current
    reason = "landing start blocked: workflow admission budget"
    artifacts = (workflow.artifacts || {}).merge(
      "start_blocked_reason" => reason,
      "start_blocked_at" => workflow.artifact("start_blocked_at").presence || now.iso8601,
      "start_blocked_last_seen_at" => now.iso8601,
      "start_blocked_next_check_at" => (now + backoff).iso8601
    ).merge(extra_artifacts)
    artifacts["start_blocked_details"] = details if details.present?
    workflow.update!(artifacts: artifacts)
    WorkflowPhaseAdmissionJob.set(wait: backoff, priority: workflow.job.solid_queue_priority).perform_later(workflow.id)
    schedule_landing_queue_recheck!(workflow, backoff)
    nil
  end

  def self.schedule_landing_queue_recheck!(workflow, backoff)
    LandingQueueProcessorJob
      .set(wait: backoff, priority: workflow.job.solid_queue_priority)
      .perform_later
  end

  def self.warn_if_stuck_queued(workflow, reason)
    return if RebaseWorkflowSelector::TRIGGER_KINDS.include?(workflow.trigger_kind)
    return unless workflow.queued?

    Rails.logger.warn(
      "[StepDispatcher] workflow #{workflow.id} (#{workflow.trigger_kind}) left queued with 0 runs: " \
      "#{reason} job_id=#{workflow.job_id}"
    )
  end

  # Single point that creates a Run on a Step. Run's
  # after_create_commit auto-enqueues RunJob, so we don't enqueue
  # explicitly. trigger_kind is denormalized from Workflow until
  # commit 9's cleanup migration drops Run.trigger_kind entirely.
  def self.create_run_and_enqueue(step, workflow, parent_session_id: nil, prompt: nil, check_phase_admission: true)
    if check_phase_admission && provider_availability_deferred?(step, workflow)
      return nil
    end

    if check_phase_admission && phase_admission_deferred?(step, workflow)
      return nil
    end

    step.runs.create!(
      job: workflow.job,
      trigger_kind: workflow.trigger_kind,
      agent_provider: workflow.agent_provider,
      iteration: step.iteration,
      parent_session_id: parent_session_id,
      prompt: prompt
    )
  end

  def self.provider_availability_deferred?(step, workflow)
    return false if step.runs.any?

    provider_pause = ProviderAvailabilityPause.call(workflow: workflow)
    unless provider_pause.pause?
      clear_start_blocked!(workflow, PROVIDER_AVAILABILITY_BLOCK_REASON)
      return false
    end

    backoff = provider_pause.retry_at ? provider_pause.retry_at - Time.current : PHASE_ADMISSION_RECHECK_DELAY
    details = provider_pause.details.merge(
      "phase_step_id" => step.id,
      "phase_step_kind" => step.kind,
      "phase_step_position" => step.position
    )
    record_pause!(
      workflow,
      PROVIDER_AVAILABILITY_BLOCK_REASON,
      backoff: [ backoff, PHASE_ADMISSION_RECHECK_DELAY.to_i ].max.seconds,
      details: details
    )
    append_provider_availability_deferral_log!(workflow, step, provider_pause)
    WorkflowPhaseAdmissionJob.set(wait_until: provider_pause.retry_at, priority: workflow.job.solid_queue_priority).perform_later(workflow.id, step.id)
    true
  end

  def self.phase_admission_deferred?(step, workflow)
    return false if step.runs.any?

    admission = WorkflowAdmissionBudget.call(workflow: workflow, step: step)
    if admission.admit?
      record_admission_decision!(workflow, admission)
      clear_start_blocked!(workflow, ADMISSION_BLOCK_REASON)
      return false
    end
    return false if whole_workflow_policy_ignores_phase_delay?(admission)

    backoff = admission.delay_until ? admission_backoff(admission) : PHASE_ADMISSION_RECHECK_DELAY
    details = admission.artifact.merge(
      "phase_step_id" => step.id,
      "phase_step_kind" => step.kind,
      "phase_step_position" => step.position
    )
    hard_pause = hard_resource_pause?(admission)
    if workflow.landing_workflow? && !hard_pause
      append_phase_deferral_log!(workflow, step, admission)
      block_landing_for_admission!(
        workflow,
        backoff: backoff,
        details: details,
        extra_artifacts: {
          "workflow_admission_decision" => details,
          "workflow_admission_decided_at" => Time.current.iso8601
        }
      )
      return true
    end

    pause_reason = hard_pause ? PAUSE_REASON_RESOURCE_SAFETY : PAUSE_REASON_ADMISSION
    record_pause!(workflow, pause_reason, backoff: backoff, details: details)
    append_phase_deferral_log!(workflow, step, admission)
    WorkflowPhaseAdmissionJob.set(wait: backoff, priority: workflow.job.solid_queue_priority).perform_later(workflow.id, step.id)
    true
  end

  def self.whole_workflow_policy_ignores_phase_delay?(admission)
    !AppSetting.workflow_admission_phase_aware? && !hard_resource_pause?(admission)
  end

  def self.hard_resource_pause?(admission)
    admission.requires_override? && admission.reason.to_s.in?(%w[worker_memory_exhausted worker_disk_exhausted])
  end

  def self.record_pause!(workflow, reason, backoff:, details: nil)
    now = Time.current
    current = workflow.artifacts || {}
    started_at = current["pause_reason"] == reason ? current["pause_started_at"] : nil
    pause_kind = case reason
    when PAUSE_REASON_RESOURCE_SAFETY then "hard_resource_pressure"
    when PROVIDER_AVAILABILITY_BLOCK_REASON then "provider_availability"
    else "workflow_admission"
    end
    artifacts = current.merge(
      "pause_reason" => reason,
      "pause_kind" => pause_kind,
      "pause_started_at" => started_at.presence || now.iso8601,
      "pause_last_seen_at" => now.iso8601,
      "pause_next_check_at" => (now + backoff).iso8601,
      "start_blocked_reason" => reason,
      "start_blocked_at" => current["start_blocked_at"].presence || now.iso8601,
      "start_blocked_last_seen_at" => now.iso8601,
      "start_blocked_next_check_at" => (now + backoff).iso8601
    )
    if details.present?
      artifacts["pause_details"] = details
      artifacts["start_blocked_details"] = details
    else
      artifacts.delete("pause_details")
      artifacts.delete("start_blocked_details")
    end
    workflow.update!(artifacts: artifacts)
  end

  def self.record_manual_pause!(workflow, step: nil)
    now = Time.current
    current = workflow.artifacts || {}
    details = {
      "action" => "manual_unpause_required",
      "reason" => MANUAL_PAUSE_REASON
    }
    details["phase_step_id"] = step.id if step
    details["phase_step_kind"] = step.kind if step
    details["phase_step_position"] = step.position if step

    artifacts = current.merge(
      "pause_reason" => MANUAL_PAUSE_REASON,
      "pause_kind" => "manual",
      "pause_started_at" => current["pause_reason"] == MANUAL_PAUSE_REASON ? current["pause_started_at"] : now.iso8601,
      "pause_last_seen_at" => now.iso8601,
      "pause_details" => details,
      "start_blocked_reason" => MANUAL_PAUSE_REASON,
      "start_blocked_at" => current["start_blocked_reason"] == MANUAL_PAUSE_REASON ? current["start_blocked_at"] : now.iso8601,
      "start_blocked_last_seen_at" => now.iso8601,
      "start_blocked_details" => details
    ).except("pause_next_check_at", "start_blocked_next_check_at")
    workflow.update!(artifacts: artifacts)
  end

  def self.append_phase_deferral_log!(workflow, step, admission)
    run = step.previous_step&.latest_run ||
      Run.joins(:step).where(steps: { workflow_id: workflow.id }).order(:created_at).last
    return unless run

    label = hard_resource_pause?(admission) ? "resource safety paused" : "workflow admission delayed"
    JobLog.append!(
      run: run,
      kind: "system",
      chunk: "#{label} before #{step.kind}: #{admission.reason}"
    )
  end

  def self.append_provider_availability_deferral_log!(workflow, step, provider_pause)
    run = step.previous_step&.latest_run ||
      Run.joins(:step).where(steps: { workflow_id: workflow.id }).order(:created_at).last
    return unless run

    JobLog.append!(
      run: run,
      kind: "system",
      chunk: "provider availability paused before #{step.kind}: #{provider_pause.reason}"
    )
  end

  def self.resume_deferred_phase(workflow_id, step_id = nil)
    workflow = Workflow.find_by(id: workflow_id)
    return unless workflow&.queued? || workflow&.running?
    return if manually_paused?(workflow)

    step = step_id ? workflow.steps.find_by(id: step_id) : next_queued_step_without_run(workflow)
    return unless step&.queued?
    return if step.runs.any?

    if step.id == workflow.first_step&.id
      start_workflow(workflow)
    elsif (previous = step.previous_step)&.succeeded?
      advance_from(previous)
    end
  end

  def self.next_queued_step_without_run(workflow)
    workflow.steps.order(:position).detect { |candidate| candidate.queued? && candidate.runs.none? }
  end

  def self.fail_from(step)
    new(step.workflow, advancing_from: step).fail!
  end

  def self.log_prepare_skip(run, workflow)
    reason = workflow.artifact("prepare_skipped_reason")
    return unless reason

    message = case reason
    when "repository_configuration"
      "prepare skipped via repository configuration"
    when "issue_label"
      "prepare skipped via '#{Workflows::SKIP_PREPARE_LABEL}' label"
    else
      "prepare skipped"
    end
    JobLog.append!(run: run, chunk: message, kind: "system")
  end

  def initialize(workflow, advancing_from: nil)
    @workflow = workflow
    @from_step = advancing_from
  end

  def advance!
    return if handle_successful_adversarial_loop_iteration

    next_step = find_next_runnable
    if next_step
      # Idempotency: cascade_failure_to_step fires fail_from twice
      # (once from Step#fail_workflow!, once explicitly from
      # Run#cascade_failure_to_step). For grader Steps that
      # advance-on-fail, both calls would try to create a Run on
      # the same next_step. Skip if already materialized.
      return if next_step.runs.any?
      return if manually_paused_before_next_step?(next_step)

      self.class.create_run_and_enqueue(next_step, @workflow)
    else
      finish_workflow!
    end
  end

  def fail!
    return if @workflow.terminal?

    case @from_step && Step::Kind.fetch(@from_step.kind).fail_policy
    when :advance
      advance!
    when :loop_iteration
      handle_loop_iteration
    else
      return if handle_try_failure

      hard_fail_workflow!
    end
  end

  private

  def handle_successful_adversarial_loop_iteration
    return false unless @from_step&.kind == "adversarial_review"
    return false unless @from_step.loop_id.present?

    loop_node = loop_node_for(@from_step)
    return false unless loop_node&.fetch("type") == "loop"
    return false unless loop_step_kinds(loop_node).last == "adversarial_review"

    if last_adversarial_review_approved?
      cancel_and_skip_to_next!(implement_step: @from_step.next_step)
      true
    elsif @from_step.iteration < loop_max_iterations(loop_node)
      enqueue_next_loop_iteration!(loop_node)
      true
    else
      false
    end
  end

  def last_adversarial_review_approved?
    @workflow.artifacts
      &.dig("adversarial_review_iterations")
      &.last
      &.fetch("verdict", nil) == "approved"
  end

  def cancel_and_skip_to_next!(implement_step:)
    return unless implement_step
    continuation = implement_step.next_step

    Step.transaction do
      Step.suppress_cancel_cascade do
        if implement_step.may_cancel?
          implement_step.cancellation_reason = "adversarial_review_approved"
          implement_step.cancel!
          implement_step.save!
        end
      end

      if continuation&.queued? && continuation.runs.none? && !manually_paused_before_next_step?(continuation)
        self.class.create_run_and_enqueue(continuation, @workflow)
      end
    end
  end

  def handle_loop_iteration
    loop_node = loop_node_for(@from_step)
    return hard_fail_workflow! unless loop_node

    if @from_step.iteration < loop_max_iterations(loop_node)
      enqueue_next_loop_iteration!(loop_node)
    elsif @from_step.succeeded?
      advance_to_next_runnable!
    else
      exhaust_loop!
    end
  end

  def advance_to_next_runnable!
    next_step = find_next_runnable
    if next_step
      # Idempotency: cascade_failure_to_step fires fail_from twice
      # (once from Step#fail_workflow!, once explicitly from
      # Run#cascade_failure_to_step). For grader Steps that
      # advance-on-fail, both calls would try to create a Run on
      # the same next_step. Skip if already materialized.
      return if next_step.runs.any?
      return if manually_paused_before_next_step?(next_step)

      self.class.create_run_and_enqueue(next_step, @workflow)
    else
      finish_workflow!
    end
  end

  def loop_node_for(step)
    # Dynamically-inserted `grader` Steps aren't part of the static
    # chain_template — Steps::GraderFanout inserts them at run time.
    # Drop them before comparing so the template "[implement,
    # grader_fanout, grader_collect]" matches the actual materialized
    # "[implement, grader_fanout, grader_a, grader_b, …, grader_collect]".
    actual_kinds = @workflow.steps
                            .where(loop_id: step.loop_id, iteration: step.iteration)
                            .order(:position)
                            .pluck(:kind)
                            .reject { |k| k == "grader" }

    workflow_template_nodes.find { |node| loop_node_matches?(node, actual_kinds) }
  end

  def loop_node_matches?(node, actual_kinds)
    case node["type"]
    when "loop"
      Array(node["steps"]).map(&:to_s) == actual_kinds
    when "retry_until"
      check_steps = Array(node["check"]).map(&:to_s)
      actual_kinds == check_steps || actual_kinds == loop_step_kinds(node)
    else
      false
    end
  end

  def loop_max_iterations(loop_node)
    loop_node["max_iterations"].presence || AppSetting.grade_max_iterations
  end

  def loop_step_kinds(loop_node)
    case loop_node["type"]
    when "loop"
      Array(loop_node["steps"]).map(&:to_s)
    when "retry_until"
      Array(loop_node["repair"]).map(&:to_s) + Array(loop_node["check"]).map(&:to_s)
    else
      []
    end
  end

  def handle_try_failure
    try_node = try_node_for(@from_step)
    return false unless try_node

    failure_code = try_failure_code(@from_step)
    branch_nodes = Array(try_node.dig("on_failure", failure_code))
    return false if failure_code.blank? || branch_nodes.empty?

    if @from_step.details.to_h["try_branch_expanded"]
      return true
    end

    enqueue_try_failure_branch!(branch_nodes, failure_code)
    true
  end

  def try_node_for(step)
    try_id = step.details.to_h["try_id"]
    workflow_template_nodes.find do |node|
      next false unless node["type"] == "try"
      next false unless node["step"].to_s == step.kind

      try_id.blank? || node["id"] == try_id
    end
  end

  def try_failure_code(step)
    step.details.to_h["failure_code"].presence
  end

  def enqueue_try_failure_branch!(branch_nodes, failure_code)
    continuation = @from_step.next_step
    insertion_position = @from_step.position + 1

    Step.transaction do
      step_count = branch_nodes.sum { |node| materialized_step_kinds_for(node).size }
      shift_steps_after_branch!(from_position: insertion_position, by: step_count)
      new_steps = materialize_branch_steps!(branch_nodes, insertion_position)

      ([ @from_step ] + new_steps).each_cons(2) { |step, next_step| step.update!(next_step_id: next_step.id) }
      new_steps.last.update!(next_step_id: continuation&.id)

      @from_step.update!(
        details: @from_step.details.to_h.merge(
          "try_branch_expanded" => true,
          "try_branch_failure_code" => failure_code
        )
      )
      self.class.create_run_and_enqueue(new_steps.first, @workflow) unless manually_paused_before_next_step?(new_steps.first)
    end
  end

  def materialize_branch_steps!(branch_nodes, insertion_position)
    position = insertion_position
    branch_nodes.flat_map do |node|
      step_kinds = materialized_step_kinds_for(node)
      loop_id = %w[ loop retry_until ].include?(node["type"]) ? SecureRandom.uuid : nil

      step_kinds.map do |kind|
        step = Step.create!(
          workflow: @workflow,
          kind: kind,
          position: position,
          iteration: 1,
          loop_id: loop_id
        )
        position += 1
        step
      end
    end
  end

  def materialized_step_kinds_for(node)
    case node["type"]
    when "step"
      [ node.fetch("kind") ]
    when "loop"
      Array(node["steps"]).map(&:to_s)
    when "retry_until"
      if node.fetch("repair_first", true)
        Array(node["repair"]).map(&:to_s) + Array(node["check"]).map(&:to_s)
      else
        Array(node["check"]).map(&:to_s)
      end
    else
      raise ArgumentError, "unsupported workflow branch node: #{node.inspect}"
    end
  end

  def shift_steps_after_branch!(from_position:, by:)
    @workflow.steps.where("position >= ?", from_position).where.not(id: @from_step.id).update_all(
      [ "position = position + ?", by ]
    )
  end

  def workflow_template_nodes
    Array(@workflow.chain_template).flat_map { |node| flatten_template_node(node) }
  end

  def flatten_template_node(node)
    case node["type"]
    when "try"
      branch_nodes = node.fetch("on_failure", {}).values.flat_map { |nodes| Array(nodes) }
      [ node ] + branch_nodes.flat_map { |branch_node| flatten_template_node(branch_node) }
    else
      [ node ]
    end
  end

  def enqueue_next_loop_iteration!(loop_node)
    current_grade = @from_step
    return if next_loop_iteration_already_materialized?(current_grade)

    continuation = current_grade.next_step
    insertion_position = current_grade.position + 1
    next_iteration = current_grade.iteration + 1
    loop_steps = loop_step_kinds(loop_node)
    Step.transaction do
      loop_step_count = loop_steps.size
      @workflow.steps.where("position >= ?", insertion_position).update_all(
        [ "position = position + ?", loop_step_count ]
      )

      previous = current_grade
      new_steps = loop_steps.map.with_index do |kind, index|
        Step.create!(
          workflow: @workflow,
          kind: kind,
          position: insertion_position + index,
          iteration: next_iteration,
          loop_id: current_grade.loop_id
        )
      end

      ([ previous ] + new_steps).each_cons(2) { |step, next_step| step.update!(next_step_id: next_step.id) }
      new_steps.last.update!(next_step_id: continuation&.id)

      unless manually_paused_before_next_step?(new_steps.first)
        self.class.create_run_and_enqueue(new_steps.first, @workflow, parent_session_id: prior_iteration_session_id)
      end
    end
  end

  def manually_paused_before_next_step?(step)
    return false unless self.class.manually_paused?(@workflow)

    self.class.record_manual_pause!(@workflow, step: step)
    true
  end

  def next_loop_iteration_already_materialized?(current_grade)
    next_step = current_grade.next_step
    next_step&.loop_id == current_grade.loop_id &&
      next_step.iteration == current_grade.iteration + 1
  end

  def exhaust_loop!
    cancel_post_loop_steps!("loop_exhausted_after_grader_failure")
    @workflow.increment!(:failure_count)
    hard_fail_workflow!("loop_exhausted_after_grader_failure")
  end

  def cancel_post_loop_steps!(reason)
    Step.suppress_cancel_cascade do
      cursor = @from_step.next_step
      while cursor
        if cursor.may_cancel?
          cursor.cancellation_reason = reason
          cursor.cancel!
          cursor.save!
        end
        cursor = cursor.next_step
      end
    end
  end

  def hard_fail_workflow!(reason = nil)
    if reason
      @workflow.failure_reason = reason
      @workflow.artifacts = (@workflow.artifacts || {}).merge("failure_reason" => reason)
    end
    return unless @workflow.may_fail?

    @workflow.fail!
    @workflow.save!
  end

  def prior_iteration_session_id
    prior_iteration_agent_step&.latest_run&.provider_session&.session_id
  end

  def prior_iteration_agent_step
    loop_node = loop_node_for(@from_step)
    agent_step_kind =
      if loop_node
        # In adversarial loops, both implement and adversarial_review are agentic.
        # Resuming the first agentic loop kind keeps implementer sessions chained;
        # the reviewer handler separately finds prior adversarial_review sessions.
        loop_step_kinds(loop_node).find { |kind| Step::AGENTIC_KINDS.include?(kind.to_s) }
      end
    return nil unless agent_step_kind

    @workflow.steps.find_by(
      loop_id: @from_step.loop_id,
      iteration: @from_step.iteration,
      kind: agent_step_kind
    )
  end

  # Linear chain walk: starting at `@from_step.next_step`, find
  # the first step in `queued` state. Skips cancelled / succeeded /
  # failed steps en route — the chain can have cancelled gaps when
  # an upstream step calls cancel_downstream! (e.g.
  # Steps::AutoRebase on a clean rebase). v3's graph version walks
  # edges instead of next_step pointers.
  def find_next_runnable
    # If we're advancing FROM a step, look at its successor (which
    # may be nil — that's "end of chain"). If we're not advancing
    # from anywhere (start_workflow case), look at the first step.
    cursor = @from_step ? @from_step.next_step : @workflow.first_step
    while cursor
      if cursor.state == "queued"
        if skippable_queued_step?(cursor)
          skip_queued_step!(cursor)
        else
          return cursor
        end
      end
      cursor = cursor.next_step
    end
    nil
  end

  def skippable_queued_step?(step)
    artifact_key = Step::Kind.fetch(step.kind).skip_if_artifact
    artifact_key && @workflow.artifact(artifact_key).present?
  rescue ArgumentError
    false
  end

  def skip_queued_step!(step)
    now = Time.current
    details = step.details.to_h.merge(
      "skipped" => true,
      "skip_reason" => "test_plan_already_submitted"
    )

    step.update_columns(
      state: "succeeded",
      started_at: now,
      finished_at: now,
      details: details,
      updated_at: now
    )

    Rails.logger.info(
      "[StepDispatcher] workflow #{@workflow.id} skipped step #{step.id} " \
      "(#{step.kind}): test plan already submitted"
    )
  end

  # Mergeability cached on the Job is now stale post-push (or a
  # PR just opened); badge says "needs rebase" until
  # PollAllMergeStatesJob's next tick. Schedule a focused
  # PollRebaseJob with a short delay so GitHub has time to
  # recompute, then the cache update broadcasts a refresh and the
  # show page morphs the badge live.
  MERGEABILITY_RECHECK_DELAY = 30.seconds

  def finish_workflow!
    return if @workflow.live_descendants?
    return unless @workflow.may_succeed?

    @workflow.succeed!
    @workflow.save!
    StackRebaseCoordinator.parent_amended(@workflow.job) if pushed_workflow? && @workflow.trigger_kind != "stack_rebase"
    schedule_mergeability_recheck
    schedule_auto_merge_recheck
  end

  def pushed_workflow?
    job = @workflow.job
    return false unless job.open? && job.pr_number.present?

    @workflow.steps.where(kind: %w[ pr_open push push_after_rebase force_push stack_force_push ]).where(state: "succeeded").exists?
  end

  def schedule_mergeability_recheck
    job = @workflow.job
    return unless job.pr_number.present? || job.external_pr_number.present?
    PollRebaseJob.set(wait: MERGEABILITY_RECHECK_DELAY).perform_later(job.id)
  end

  def schedule_auto_merge_recheck
    job = @workflow.job
    return unless pushed_workflow?
    return unless job.auto_merge_enabled?
    return unless job.pending_auto_merge?

    PollMergeStateJob.set(wait: MERGEABILITY_RECHECK_DELAY).perform_later(job.id)
  end
end
