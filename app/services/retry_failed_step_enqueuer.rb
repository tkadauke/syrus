class RetryFailedStepEnqueuer
  # Genuine last-resort case: the workflow workspace is gone, so there is no
  # in-place recovery left and Start Over really is the only path forward.
  WORKSPACE_CLEANED_UP_MESSAGE = "Workspace already cleaned up - use Start over.".freeze
  ACTIVE_WORK_LOCK_ERROR = "active_work_lock".freeze

  Result = Data.define(:run, :workflow, :step, :error) do
    def success? = run.present?
    def active_work_lock? = error.to_s.start_with?("#{ACTIVE_WORK_LOCK_ERROR}:")
  end

  def self.call(...) = new(...).call
  def self.failed_step_for(workflow)
    cancelled_loop = cancelled_grade_loop_restart_step_for(workflow)
    return cancelled_loop if cancelled_loop

    step = workflow.steps.where(state: "failed").reorder(position: :desc, id: :desc).detect { |candidate| !candidate.retry_until_barrier_superseded? } ||
      cancelled_publication_step_for(workflow)
    step = grade_loop_restart_step_for(step) if grade_loop_failure?(step)
    return unless step
    return if crosses_uncleared_retry_until_barrier?(step)

    step
  end

  def self.grade_loop_failure?(step)
    step&.loop_id.present? &&
      step.workflow.steps.where(loop_id: step.loop_id, kind: "grader_collect").exists?
  end

  def self.grade_loop_restart_step_for(step)
    return step if step.kind == "grader_fanout"

    step.workflow.steps
      .where(kind: "grader_fanout", loop_id: step.loop_id, iteration: step.iteration)
      .reorder(position: :asc, id: :asc)
      .first || step
  end

  def self.cancelled_grade_loop_restart_step_for(workflow)
    collectors = workflow.steps
      .where(kind: "grader_collect")
      .where.not(loop_id: nil)
      .reorder(position: :desc, id: :desc)
    inspected_loop_ids = {}

    collectors.each do |collector|
      next if inspected_loop_ids[collector.loop_id]

      inspected_loop_ids[collector.loop_id] = true
      next if collector.retry_until_barrier_superseded?

      iteration_steps = workflow.steps
        .where(loop_id: collector.loop_id, iteration: collector.iteration)
        .reorder(:position, :id)
        .to_a
      next unless iteration_steps.any? { |candidate| candidate.runs.any? || candidate.failed? || candidate.succeeded? }

      cancelled_required = iteration_steps.any? do |candidate|
        candidate.cancelled? && (candidate.kind != "grader" || candidate.details.to_h.fetch("required", true))
      end
      next unless cancelled_required

      fanout = iteration_steps.find { |candidate| candidate.kind == "grader_fanout" }
      return fanout if fanout
    end

    nil
  end
  private_class_method :grade_loop_failure?, :grade_loop_restart_step_for, :cancelled_grade_loop_restart_step_for

  # A fanout batch can fail more than one required grader at once; retrying
  # only the single Step returned by failed_step_for left every sibling
  # sitting in state: "failed" with no new Run, so grader_collect immediately
  # re-failed on the untouched siblings the moment the retried grader
  # finished -- a dead-end retry. Every other "grader" Step sharing this
  # one's loop_id/iteration and still failed needs the same reopen + Run.
  def self.failed_grader_siblings(step)
    return [] unless step&.kind == "grader"

    step.workflow.steps
      .where(kind: "grader", state: "failed", loop_id: step.loop_id, iteration: step.iteration)
      .where.not(id: step.id)
      .order(:position)
      .to_a
  end

  def self.crosses_uncleared_retry_until_barrier?(step)
    return false if step.loop_id.present?

    latest_retry_until_barriers_before(step).any? { |barrier| !barrier.succeeded? }
  end

  def self.retry_until_barrier_step?(step)
    step.loop_id.present? &&
      Step::Kind.fetch(step.kind).fail_policy == :loop_iteration
  rescue ArgumentError
    false
  end

  def self.latest_retry_until_barriers_before(step)
    step.workflow.steps
        .where("position < ?", step.position)
        .reorder(position: :desc, id: :desc)
        .each_with_object({}) do |candidate, barriers|
          next unless retry_until_barrier_step?(candidate)

          barriers[candidate.loop_id] ||= candidate
        end
        .values
        .reject(&:retry_until_barrier_superseded?)
  end

  def self.cancelled_publication_step_for(workflow)
    return unless workflow&.failed?
    return unless workflow.failure_reason == "pr_publication_missing_after_success" ||
      workflow.artifact("failure_reason") == "pr_publication_missing_after_success"

    publication_kinds = workflow.work_definition.review_publication_step_kinds
    return if publication_kinds.empty?

    publication_step = workflow.steps
      .where(kind: publication_kinds)
      .reorder(:position, :id)
      .first
    return unless publication_step&.cancelled? && publication_step.runs.none?

    workflow.steps
      .where(state: "cancelled")
      .where("position <= ?", publication_step.position)
      .where.missing(:runs)
      .reorder(:position, :id)
      .first
  end

  def initialize(workflow:, parent_session_id: nil, prompt: nil, agent_provider: nil, disable_session_resume: false)
    @workflow = workflow
    @parent_session_id = parent_session_id
    @prompt = prompt
    @agent_provider = agent_provider.to_s.presence
    @disable_session_resume = disable_session_resume
  end

  def call
    return failure("Workflow is not in a failed state.") unless workflow.failed?
    return failure(WORKSPACE_CLEANED_UP_MESSAGE) unless workflow.retry_available?

    failed_step = self.class.failed_step_for(workflow)
    return failure("No failed step to retry.") unless failed_step
    return rebuild_merge_train if terminal_merge_train_rebuild_required?

    remediation = remediation_for(failed_step)
    return rebuild_merge_train if remediation.rebuild_unit?
    return failure("Failed step requires a new workflow attempt.") unless remediation.resume_step?
    if (lock_error = active_work_lock_error)
      return failure(lock_error)
    end

    reopen_workflow_for_retry!
    if grade_loop_restart_retry?(failed_step)
      restart_step = restart_grade_loop!(failed_step)
      if workflow.landing_workflow?
        job = workflow.job
        job.update_columns(landing_failure_reason: nil) if job.landing_failure_reason.present?
      end

      run = create_run_for!(restart_step)
      return Result.new(run: run, workflow: workflow, step: restart_step, error: nil)
    end

    sibling_graders = self.class.failed_grader_siblings(failed_step)

    reopen_step!(failed_step)
    sibling_graders.each { |sibling| reopen_step!(sibling) }
    reopen_collect_barrier_after_grader!(failed_step)
    revive_cancelled_downstream_steps!(failed_step)

    if workflow.landing_workflow?
      job = workflow.job
      job.update_columns(landing_failure_reason: nil) if job.landing_failure_reason.present?
    end

    run = create_run_for!(failed_step)
    sibling_graders.each { |sibling| create_run_for!(sibling) }

    Result.new(run: run, workflow: workflow, step: failed_step, error: nil)
  rescue WorkUnits::Launcher::LockConflict => e
    failure("#{ACTIVE_WORK_LOCK_ERROR}: active WorkUnit ##{e.work_unit.id} already owns #{e.lock_key}")
  end

  private

  attr_reader :workflow, :parent_session_id, :prompt, :agent_provider, :disable_session_resume

  def retry_parent_session_id
    return Steps::Base::DISABLE_AGENT_RESUME if disable_session_resume

    parent_session_id
  end

  # Resolved through the one remediation rule rather than asking the work
  # definition's retry policy directly. The policy is still what answers --
  # it is tier 3 of that rule -- but going through the resolver is what lets a
  # step or template override take precedence later without this call site
  # learning about them.
  def remediation_for(failed_step)
    Remediation::Resolver.call(
      problem: problem_for(failed_step),
      step: failed_step,
      workflow: workflow
    )
  end

  def problem_for(failed_step)
    Problem::Kind.resolve(failed_step.details.to_h["failure_code"])&.then { |entry| Problem[entry.code] }
  end

  def active_work_lock_error
    lock_keys_for_retry.each do |lock_key|
      owner = WorkUnits::Ownership.active_unit_for_lock_key(lock_key)
      next unless owner
      next if same_runtime_lock_owner?(owner)

      return "#{ACTIVE_WORK_LOCK_ERROR}: active WorkUnit ##{owner.id} already owns #{lock_key}"
    end

    nil
  end

  def create_run_for!(step)
    step.runs.create!(
      job: workflow.job,
      trigger_kind: workflow.trigger_kind,
      agent_provider: agent_provider || workflow.agent_provider,
      iteration: step.iteration,
      parent_session_id: retry_parent_session_id,
      prompt: prompt
    )
  end

  def reopen_step!(step)
    if step.failed?
      step.reopen!
      step.save!
    elsif step.cancelled? && step.runs.none?
      step.update_columns(
        revived_cancelled_step_attributes(step)
      )
    else
      raise AASM::InvalidTransition, "Step #{step.id} cannot be reopened from #{step.state}"
    end
  end

  def grade_loop_restart_retry?(step)
    self.class.send(:grade_loop_failure?, step)
  end

  def restart_grade_loop!(fanout)
    loop_node = retry_until_loop_node_for(fanout)
    raise AASM::InvalidTransition, "Step #{fanout.id} is not in a retry-until grade loop" unless loop_node

    anchor = loop_restart_anchor_for(fanout)
    continuation = anchor.next_step
    insertion_position = anchor.position + 1
    new_loop_id = SecureRandom.uuid
    new_steps = []

    Step.transaction do
      supersede_grade_loop!(fanout, restart_loop_id: new_loop_id)
      cancel_superseded_grade_loop_active_descendants!(fanout.loop_id, restart_loop_id: new_loop_id)

      step_kinds = initial_retry_until_step_kinds(loop_node)
      workflow.steps.where("position >= ?", insertion_position).update_all(
        [ "position = position + ?", step_kinds.size ]
      )

      new_steps = step_kinds.map.with_index do |kind, index|
        Step.create!(
          workflow: workflow,
          kind: kind,
          position: insertion_position + index,
          iteration: 1,
          loop_id: new_loop_id,
          placement_policy: placement_policy_for(kind),
          details: { "manual_grade_loop_restart" => true, "restarted_from_loop_id" => fanout.loop_id }
        )
      end

      ([ anchor ] + new_steps).each_cons(2) { |step, next_step| step.update!(next_step_id: next_step.id) }
      new_steps.last.update!(next_step_id: continuation&.id)
      wire_restart_dependencies!(anchor: anchor, new_steps: new_steps, continuation: continuation)
      revive_cancelled_downstream_steps_after(new_steps.last)
      record_grade_loop_restart!(fanout, new_steps.first)
    end

    new_steps.first
  end

  def retry_until_loop_node_for(step)
    dispatcher = StepDispatcher.new(workflow, advancing_from: step)
    loop_node = dispatcher.send(:loop_node_for, step)
    return unless loop_node&.fetch("type", nil) == "retry_until"
    return unless Array(loop_node["check"]).map(&:to_s).include?("grader_collect")

    loop_node
  end

  def initial_retry_until_step_kinds(loop_node)
    if loop_node.fetch("repair_first", true)
      Array(loop_node["repair"]).map(&:to_s) + Array(loop_node["check"]).map(&:to_s)
    else
      Array(loop_node["check"]).map(&:to_s)
    end
  end

  def loop_restart_anchor_for(fanout)
    workflow.steps
      .where(loop_id: fanout.loop_id, iteration: fanout.iteration)
      .where("position >= ?", fanout.position)
      .reorder(position: :desc, id: :desc)
      .first || fanout
  end

  def supersede_grade_loop!(fanout, restart_loop_id:)
    workflow.steps.where(loop_id: fanout.loop_id).find_each do |step|
      details = step.details.to_h.merge(
        "superseded_by_manual_grade_loop_restart" => true,
        "manual_grade_loop_restart_loop_id" => restart_loop_id,
        "manual_grade_loop_restart_at" => Time.current.iso8601
      )
      if self.class.retry_until_barrier_step?(step)
        details[Step::RETRY_UNTIL_BARRIER_SUPERSEDED_DETAIL_KEY] = true
      end
      step.update_columns(details: details, updated_at: Time.current)
    end
  end

  def cancel_superseded_grade_loop_active_descendants!(loop_id, restart_loop_id:)
    now = Time.current
    old_steps = workflow.steps.where(loop_id: loop_id)
    active_runs = Run.where(step_id: old_steps.select(:id)).active.to_a
    active_run_ids = active_runs.map(&:id)

    request_superseded_process_kill!(active_run_ids)

    active_runs.each do |run|
      run.update_columns(state: "cancelled", finished_at: now, updated_at: now)
      RunResourceSummary.refresh_for(run.reload)
    end

    old_steps.where(state: Step::ACTIVE_STATES).find_each do |step|
      step.update_columns(
        state: "cancelled",
        finished_at: now,
        cancellation_reason: "manual_grade_loop_restart",
        details: step.details.to_h.merge(
          "cancelled_by" => "manual_grade_loop_restart",
          "manual_grade_loop_restart_loop_id" => restart_loop_id,
          "superseded_active_work_cancelled_at" => now.iso8601
        ),
        updated_at: now
      )
    end
  end

  def request_superseded_process_kill!(run_ids)
    return if run_ids.empty?

    SpawnedProcess.running.where(run_id: run_ids).find_each(&:request_kill!)
  rescue StandardError => e
    Rails.logger.warn("[RetryFailedStepEnqueuer] failed to request superseded grade-loop process kills for Workflow ##{workflow.id}: #{e.class}: #{e.message}")
  end

  def reopen_workflow_for_retry!
    workflow.reopen!
    clear_workflow_failure_reason!
    workflow.save!
    workflow.sync_work_unit_running! if workflow.running? && workflow.work_unit && !workflow.work_unit.running?
  end

  def clear_workflow_failure_reason!
    workflow.failure_reason = nil if workflow.respond_to?(:failure_reason=)
    artifacts = workflow.artifacts.to_h
    return unless artifacts.key?("failure_reason")

    workflow.artifacts = artifacts.except("failure_reason")
  end

  def placement_policy_for(kind)
    Step::Kind.fetch(kind).placement_policy_for(workflow.job.repository)
  end

  def wire_restart_dependencies!(anchor:, new_steps:, continuation:)
    ([ anchor ] + new_steps).each_cons(2) do |dependency, dependent|
      dependent.update!(depends_on_ids: [ dependency.id ])
    end

    return unless continuation

    ids = continuation.depends_on_step_ids
    if ids.empty?
      continuation.update!(depends_on_ids: [ new_steps.last.id ])
    elsif ids.include?(anchor.id)
      continuation.update!(depends_on_ids: ids.map { |id| id == anchor.id ? new_steps.last.id : id })
    end
  end

  def record_grade_loop_restart!(old_fanout, new_fanout)
    workflow.set_artifact!(
      "manual_grade_loop_restarts",
      Array(workflow.artifact("manual_grade_loop_restarts")) + [ {
        "restarted_at" => Time.current.iso8601,
        "from_loop_id" => old_fanout.loop_id,
        "from_iteration" => old_fanout.iteration,
        "new_loop_id" => new_fanout.loop_id,
        "new_step_id" => new_fanout.id
      } ]
    )
  end

  def lock_keys_for_retry
    workflow.work_definition.lock_keys_for(
      job: workflow.job,
      member_jobs: member_jobs_for_retry,
      artifacts: workflow.artifacts.to_h
    )
  end

  def member_jobs_for_retry
    unit = workflow.work_unit
    jobs = unit&.work_unit_members&.includes(:job)&.order(:id)&.map(&:job)&.compact
    jobs.presence || [ workflow.job ].compact
  end

  def same_runtime_lock_owner?(owner)
    unit = workflow.work_unit
    return false unless owner && unit
    return true if owner.id.to_i == unit.id.to_i

    owner.workflow_id.present? && owner.workflow_id.to_i == workflow.id.to_i
  end

  def revive_cancelled_downstream_steps!(failed_step)
    revive_cancelled_downstream_steps_after(failed_step)
  end

  def revive_cancelled_downstream_steps_after(step)
    cursor = downstream_start_after(step)
    while cursor
      if cursor.cancelled? && cursor.runs.none?
        cursor.update_columns(
          revived_cancelled_step_attributes(cursor)
        )
      end
      cursor = cursor.next_step
    end
  end

  CANCELLATION_DETAIL_KEYS = %w[
    cancelled_by
    cancelled_reason
    cancelled_workflow_id
    cancelled_workflow_state
    cancelled_source_step_id
    cancelled_source_step_kind
    manual_grade_loop_restart_loop_id
    superseded_active_work_cancelled_at
  ].freeze

  def revived_cancelled_step_attributes(step)
    {
      state: "queued",
      started_at: nil,
      finished_at: nil,
      cancellation_reason: nil,
      details: step.details.to_h.except(*CANCELLATION_DETAIL_KEYS),
      updated_at: Time.current
    }
  end

  # A grader Step's own `next_step` pointer is topology-dependent: under the
  # distributed-projection fanout it points straight at grader_collect, but
  # the default legacy fanout chains graders serially (g1 -> g2 -> ... ->
  # grader_collect) -- so the *primary* failed grader picked by
  # failed_grader_before_collect (the highest-position one that's still
  # failed) can have a later, already-succeeded sibling between it and
  # grader_collect. Walking `next_step` from that primary would land on the
  # sibling grader, not the collect barrier, and silently skip reopening it.
  # Looking the collect step up directly by loop_id/iteration is correct
  # under either topology.
  def downstream_start_after(failed_step)
    return failed_step.next_step unless failed_step.kind == "grader"

    collect_step_for(failed_step)&.next_step
  end

  def collect_step_for(failed_step)
    workflow.steps.find_by(
      kind: "grader_collect",
      loop_id: failed_step.loop_id,
      iteration: failed_step.iteration
    )
  end

  def reopen_collect_barrier_after_grader!(failed_step)
    return unless failed_step.kind == "grader"

    collect = collect_step_for(failed_step)
    return unless collect&.failed? || (collect&.cancelled? && collect.runs.none?)

    collect.update_columns(
      revived_cancelled_step_attributes(collect)
    )
  end

  def rebuild_merge_train
    train_id = workflow.artifact("merge_train_id")
    train = MergeTrain.find_by(id: train_id)
    return failure("Merge train record not found - contact an admin or operator to rebuild the merge train.") unless train

    WorkUnits::TerminalWorkflowSync.call(workflow)

    rebuild = rebuild_train(train)
    rebuilt_workflow = rebuild.workflow
    unless rebuilt_workflow
      reason = rebuild_blocker_reason(train).presence ||
        "merge-train dispatch was blocked by a concurrent state change"
      return failure("#{train_rebuild_label(train)} is not ready for a merge-train rebuild: #{reason}.")
    end

    run = rebuilt_workflow.runs.order(:created_at).last
    return failure("Merge-train rebuild did not enqueue a run.") unless run

    Result.new(run: run, workflow: rebuilt_workflow, step: run.step, error: nil)
  end

  def rebuild_train(train)
    if train.bundle_backed?
      LandingRetrier.rebuild_job_bundle!(train.repository, source_train: train)
    else
      LandingRetrier.rebuild_epic_merge_train!(train.epic, source_train: train)
    end
  end

  def rebuild_blocker_reason(train)
    if train.bundle_backed?
      JobBundleDispatcher.blocker_reason(train.repository, bypass_cooldown: true)
    else
      MergeTrainDispatcher.blocker_reason(train.epic, bypass_cooldown: true)
    end
  end

  def train_rebuild_label(train)
    train.bundle_backed? ? "Job bundle" : "Epic"
  end

  def terminal_merge_train_rebuild_required?
    return false unless workflow.trigger_kind == "merge_train"

    train_id = workflow.artifact("merge_train_id")
    return false if train_id.blank?

    train = MergeTrain.find_by(id: train_id)
    train&.state.in?(%w[failed cancelled])
  end

  def failure(message)
    Result.new(run: nil, workflow: workflow, step: nil, error: message)
  end
end
