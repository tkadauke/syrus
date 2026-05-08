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
    create_run_and_enqueue(first, workflow,
                           parent_session_id: parent_session_id,
                           prompt: prompt)
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
      parent_session_id: parent_session_id,
      prompt: prompt
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

  private

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
  # PollAllRebasesJob's next 15-min tick. Schedule a focused
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
