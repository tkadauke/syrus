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
    return unless workflow.job.stack_ready_for_execution?
    return unless workflow.job.ready_for_execution?

    run = create_run_and_enqueue(first, workflow,
                                 parent_session_id: parent_session_id,
                                 prompt: prompt)
    workflow.job.log_pending_dependency_warnings!
    log_prepare_skip(run, workflow)
    run
  end

  # Single point that creates a Run on a Step. Run's
  # after_create_commit auto-enqueues RunJob, so we don't enqueue
  # explicitly. trigger_kind is denormalized from Workflow until
  # commit 9's cleanup migration drops Run.trigger_kind entirely.
  def self.create_run_and_enqueue(step, workflow, parent_session_id: nil, prompt: nil)
    step.runs.create!(
      job: workflow.job,
      trigger_kind: workflow.trigger_kind,
      agent_provider: workflow.agent_provider,
      iteration: step.iteration,
      parent_session_id: parent_session_id,
      prompt: prompt
    )
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
    next_step = find_next_runnable
    if next_step
      # Idempotency: cascade_failure_to_step fires fail_from twice
      # (once from Step#fail_workflow!, once explicitly from
      # Run#cascade_failure_to_step). For grader Steps that
      # advance-on-fail, both calls would try to create a Run on
      # the same next_step. Skip if already materialized.
      return if next_step.runs.any?

      self.class.create_run_and_enqueue(next_step, @workflow)
    else
      finish_workflow!
    end
  end

  def fail!
    return if @workflow.terminal?

    # Per-kind failure policy:
    #   "grader"          → silent: advance to next sibling. All graders in
    #                       an iteration run regardless of individual outcome;
    #                       grader_collect aggregates the decision.
    #   "grader_collect"  → loop iteration (Phase B's loop terminal kind).
    #   "grade"           → loop iteration (legacy single-Step grader kept
    #                       for backwards compat with existing workflows).
    #   default           → workflow fails (existing behavior).
    case @from_step&.kind
    when "grader"
      advance!
    when "grader_collect", "grade"
      handle_loop_iteration
    else
      hard_fail_workflow!
    end
  end

  private

  def handle_loop_iteration
    loop_node = loop_node_for(@from_step)
    return hard_fail_workflow! unless loop_node

    if @from_step.iteration < loop_max_iterations(loop_node)
      enqueue_next_loop_iteration!(loop_node)
    else
      exhaust_loop!
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

    Array(@workflow.chain_template).find { |node| loop_node_matches?(node, actual_kinds) }
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

      self.class.create_run_and_enqueue(new_steps.first, @workflow, parent_session_id: prior_iteration_session_id)
    end
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
    prior_iteration_agent_step&.latest_run&.claude_session&.session_id
  end

  def prior_iteration_agent_step
    loop_node = loop_node_for(@from_step)
    agent_step_kind =
      if loop_node
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
      return cursor if cursor.state == "queued"
      cursor = cursor.next_step
    end
    nil
  end

  # Mergeability cached on the Job is now stale post-push (or a
  # PR just opened); badge says "needs rebase" until
  # PollAllMergeStatesJob's next tick. Schedule a focused
  # PollRebaseJob with a short delay so GitHub has time to
  # recompute, then the cache update broadcasts a refresh and the
  # show page morphs the badge live.
  MERGEABILITY_RECHECK_DELAY = 30.seconds

  def finish_workflow!
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

    @workflow.steps.where(kind: %w[ pr_open push force_push stack_force_push ]).where(state: "succeeded").exists?
  end

  def schedule_mergeability_recheck
    job = @workflow.job
    return unless job.pr_number.present? || job.external_pr_number.present?
    PollRebaseJob.set(wait: MERGEABILITY_RECHECK_DELAY).perform_later(job.id)
  end

  def schedule_auto_merge_recheck
    job = @workflow.job
    return unless pushed_workflow?
    return unless job.repository.auto_merge_enabled?
    return unless job.pending_auto_merge?

    PollMergeStateJob.set(wait: MERGEABILITY_RECHECK_DELAY).perform_later(job.id)
  end
end
