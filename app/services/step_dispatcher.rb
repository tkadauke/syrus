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
  # this is a no-op (e.g. Resume that pre-creates a Run with a
  # parent_session_id before calling start_workflow).
  def self.start_workflow(workflow, parent_session_id: nil, prompt: nil)
    first = workflow.first_step
    return unless first
    return if first.runs.any?
    return unless workflow.job.dependencies_satisfied?

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

  def self.handle_failed_step(step)
    new(step.workflow, advancing_from: step).handle_failed_step
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
    run.job_logs.create!(
      chunk: message,
      sequence: (run.job_logs.maximum(:sequence) || -1) + 1,
      kind: "system"
    )
  end

  def initialize(workflow, advancing_from: nil)
    @workflow = workflow
    @from_step = advancing_from
  end

  def advance!
    next_step = find_next_runnable
    if next_step
      self.class.create_run_and_enqueue(next_step, @workflow)
    else
      finish_workflow!
    end
  end

  def handle_failed_step
    return false unless loop_grade_step?(@from_step)

    loop_node = loop_node_for(@from_step)
    return false unless loop_node

    if @from_step.iteration < loop_max_iterations(loop_node)
      enqueue_next_loop_iteration!(loop_node)
    else
      exhaust_loop!
    end
    true
  end

  private

  def loop_grade_step?(step)
    step&.loop_id.present? && step.kind == "grade"
  end

  def loop_node_for(step)
    loop_kinds = @workflow.steps.where(loop_id: step.loop_id, iteration: step.iteration)
                          .order(:position).pluck(:kind)

    Array(@workflow.chain_template).find do |node|
      node["type"] == "loop" && Array(node["steps"]).map(&:to_s) == loop_kinds
    end
  end

  def loop_max_iterations(loop_node)
    loop_node["max_iterations"].presence || AppSetting.grade_max_iterations
  end

  def enqueue_next_loop_iteration!(loop_node)
    current_grade = @from_step
    continuation = current_grade.next_step
    insertion_position = current_grade.position + 1
    next_iteration = current_grade.iteration + 1
    next_run = nil

    Step.transaction do
      loop_step_count = loop_node.fetch("steps").size
      @workflow.steps.where(position: insertion_position..).order(position: :desc).each do |step|
        step.update!(position: step.position + loop_step_count)
      end

      previous = current_grade
      new_steps = loop_node.fetch("steps").map.with_index do |kind, index|
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

      next_run = self.class.create_run_and_enqueue(new_steps.first, @workflow, parent_session_id: prior_iteration_session_id)
    end

    enqueue_loop_run_after_inline_failure(next_run)
  end

  def exhaust_loop!
    @workflow.set_artifact!("failure_reason", "loop_exhausted")
    return unless @workflow.may_fail?

    @workflow.fail!
    @workflow.save!
  end

  def enqueue_loop_run_after_inline_failure(run)
    return unless run && Thread.current[:syrus_in_run_job]

    RunJob.set(priority: @workflow.job.solid_queue_priority).perform_later(run.id)
  end

  def prior_iteration_session_id
    prior_iteration_agent_step&.latest_run&.claude_session&.session_id
  end

  def prior_iteration_agent_step
    loop_node = loop_node_for(@from_step)
    agent_step_kind = Array(loop_node&.fetch("steps", [])).find do |kind|
      Step::AGENTIC_KINDS.include?(kind.to_s)
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
    schedule_mergeability_recheck
  end

  def schedule_mergeability_recheck
    job = @workflow.job
    return unless job.pr_number.present? || job.external_pr_number.present?
    PollRebaseJob.set(wait: MERGEABILITY_RECHECK_DELAY).perform_later(job.id)
  end
end
