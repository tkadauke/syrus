class RunJob < ApplicationJob
  # Dedicated `runs` queue with its own SQ worker — see
  # config/queue.yml. RunJobs are minutes-long agent invocations;
  # putting them on the shared `default` queue starves app events
  # and the recurring reaper/pollers, which makes the
  # UI feel frozen during heavy load and (in the worst case)
  # leaves zombie Runs stuck "running" because ReapStaleRunsJob
  # can't get a thread. Splitting queues keeps short jobs fast.
  queue_as :runs

  # One Run at a time per Job. Per-Job (not per-repo) is the right
  # granularity: the Workflow's per-Workflow workspace at
  # $SYRUS_DATA_ROOT/workflows/<workflow_id>/ is shared across the
  # chain's steps, but two concurrent Workflows on the same Job
  # would race on that path. The collision risk is *within* a Job;
  # the per-Job key prevents two Runs (same Workflow's next step or
  # a parallel Workflow) from interleaving.
  limits_concurrency to: 1, key: ->(run_id) {
    "job:#{::Run.where(id: run_id).pick(:job_id)}"
  }

  discard_on ActiveRecord::RecordNotFound

  # Test seam — let specs swap in a fake runner without exec'ing claude.
  class << self
    attr_accessor :agent_runner
  end

  # Every Run in the new model belongs to a Step (via `runs.step_id`),
  # so RunJob's job is to:
  #
  #   1. Pre-flight: skip already-terminal Runs, abort if the
  #      parent Workflow is already terminal (something else reaped
  #      or cancelled this chain).
  #   2. Re-entrancy guard: a Run found in `running` state on entry
  #      means the prior worker died mid-perform — fail it with
  #      `worker_died` so the operator can use Retry.
  #   3. Bring Workflow + Step + Run all to `running`.
  #   4. Dispatch to the per-kind handler in Steps::*. Handlers do
  #      not manage state — they just do the work or raise.
  #   5. On success: succeed Run + Step. Step.after_update_commit
  #      fires StepDispatcher.advance_from synchronously, which
  #      creates the next Step's Run inline (Run#enqueue_run_job
  #      sees Thread.current[:syrus_in_run_job] and skips the
  #      perform_later — the loop below picks the new Run up
  #      directly so the worker drives the entire Workflow chain
  #      depth-first instead of bouncing through SQ between steps).
  #   6. On failure: capture a diagnostic and fail the Run. Run's
  #      after_update_commit cascades into StepDispatcher.fail_from,
  #      which either continues a grade loop or hard-fails the
  #      Workflow.
  # When the operator console pauses runs, fresh perform-attempts
  # re-enqueue themselves with a delay rather than starting work.
  # The Run stays in `queued` (or whatever state it was in); the
  # next attempt rechecks. When unpaused, work proceeds. Cost
  # while paused: 1 re-enqueue per Run per RUNS_PAUSED_RETRY_DELAY,
  # which is fine for a kill-switch state that's typically minutes,
  # not days.
  RUNS_PAUSED_RETRY_DELAY = 30.seconds
  AGENT_CONCURRENCY_RETRY_DELAY = 15.seconds

  def perform(run_id)
    if AppSetting.runs_paused?
      Rails.logger.info("[RunJob] runs paused — deferring Run ##{run_id} by #{RUNS_PAUSED_RETRY_DELAY}")
      defer_run(run_id, RUNS_PAUSED_RETRY_DELAY)
      return
    end

    return if defer_for_agent_concurrency?(run_id)

    @run = ::Run.find(run_id)
    Thread.current[:syrus_current_run] = @run
    Thread.current[:syrus_in_run_job] = true
    return if @run.terminal?

    @step = @run.step
    @workflow = @step&.workflow
    @job = @run.job

    # Record the worker pod driving this workflow so a later reopen ("Retry
    # from failed step") or post-crash re-enqueue can be routed back to the
    # pod holding the on-disk workspace (see Run#resume_worker_queue).
    @workflow&.record_worker_hostname!

    @shutdown_requested = false
    prior_trap = Signal.trap("TERM") do
      @shutdown_requested = true
      prior_trap.call if prior_trap.respond_to?(:call)
    end

    loop do
      break if @shutdown_requested
      perform_step
      next_run = next_inline_run
      break unless next_run
      if @shutdown_requested
        Rails.logger.info("[RunJob] SIGTERM — yielding at step boundary for Run ##{@run.id}, successor Run ##{next_run.id} will be re-enqueued by reaper")
        break
      end
      @run = next_run
      @step = @run.step
      @handler = nil
      Thread.current[:syrus_current_run] = @run
    end
  rescue StandardError => e
    handle_failure(e)
    if workflow_controlled_failure?
      continue_inline_after_controlled_failure
    else
      raise
    end
  ensure
    Signal.trap("TERM", prior_trap) if prior_trap
    Thread.current[:syrus_current_run] = nil
    Thread.current[:syrus_in_run_job] = nil
  end

  private

  # Re-enqueue this Run after a delay, preserving its Job's SolidQueue priority
  # AND the current queue. Preserving the queue matters for the per-worker
  # resume queue: a deferred resume run must stay pinned to the worker holding
  # the workspace, not fall back to the class-default `:runs` queue on any pod.
  # Used by the runs-paused and agent-concurrency gates.
  def defer_run(run_id, delay)
    sq_priority = ::Run.joins(:job).where(id: run_id).pick("jobs.priority")
    sq_num = ::Job::PRIORITY_TO_SQ.fetch(sq_priority.to_s, ::Job::PRIORITY_TO_SQ["medium"])
    self.class.set(queue: queue_name, wait: delay, priority: sq_num).perform_later(run_id)
  end

  # Global, cluster-wide cap on concurrent agent Runs (the `:runs` queue),
  # admin-configured via AppSetting.max_concurrent_agent_runs. SolidQueue's
  # per-job concurrency key (job:<id>) is already used for per-Job
  # serialization, so this is a best-effort DB-counted gate rather than a
  # second SolidQueue semaphore: if the cap is already met, this Run bounces
  # back to the queue with a short delay. DB-counted so it holds across worker
  # pods (per-pod JOB_CONCURRENCY only bounds a single pod). Best-effort — a
  # couple extra may slip through under contention; it's a cost/rate ceiling,
  # not a hard lock. 0 = unlimited. Main-branch graders also run on `:runs` and
  # are capped. Landing/merge Runs are not capped (different queues, isolated
  # pools).
  def defer_for_agent_concurrency?(run_id)
    limit = AppSetting.max_concurrent_agent_runs
    return false if limit <= 0

    run = ::Run.find_by(id: run_id)
    return false unless run && !run.terminal? && run.agent_queue?

    active = ::Run.running_agent_runs.where.not(id: run_id).count
    return false if active < limit

    Rails.logger.info("[RunJob] agent concurrency #{active}/#{limit} reached — deferring Run ##{run_id} by #{AGENT_CONCURRENCY_RETRY_DELAY.inspect}")
    defer_run(run_id, AGENT_CONCURRENCY_RETRY_DELAY)
    true
  end

  def perform_step
    if @workflow.nil? || @step.nil?
      raise "Run ##{@run.id} has no Step / Workflow — backfill must run before legacy Runs can execute"
    end

    unless execution_owner_consistent?
      log("execution owner mismatch; refusing to run")
      fail_run_without_validation!("execution_owner_mismatch")
      if @step.may_fail?
        @step.fail!
        @step.save!
      end
      return
    end

    if @workflow.terminal?
      log("#{@workflow.slug} already terminal (#{@workflow.state}); abandoning run")
      @run.cancel! if @run.may_cancel?
      @run.save!
      return
    end

    return if cancel_ineligible_retry_workflow!

    if @step.terminal?
      log("step ##{@step.id} already terminal (#{@step.state}); abandoning run")
      @run.cancel! if @run.may_cancel?
      @run.save!
      return
    end

    if @run.running?
      # Worker died mid-perform on a prior attempt (or SQ re-claimed
      # us after a process prune). Fail with worker_died so the
      # operator gets a Retry button on the dashboard.
      if (reconciliation = RunCompletionReconciler.call(@run)).reconciled?
        log("run reconciled on re-entry: #{reconciliation.reason}")
        return
      end

      @run.agent_outcome = "worker_died"
      @run.fail!
      @run.save!
      # cascade_failure_to_step! may have created an in-place retry run when
      # the worker_died budget isn't exhausted. Only fail the step explicitly
      # when no active retry run was queued by the callback.
      @step.reload
      if @step.runs.where.not(id: @run.id).active.exists?
        log("run abandoned — worker died mid-execution; retrying in-place automatically")
      else
        @step.fail! if @step.may_fail?
        @step.save!
        @workflow.record_run_failure!
        log("run abandoned — worker died mid-execution; use Retry to try again")
      end
      return
    end

    if workflow_starting? && (merged_pr = merged_pull_request)
      succeed_workflow_for_merged_pull_request!(merged_pr)
      return
    end

    @workflow.start! if @workflow.may_start?
    @workflow.save!
    @step.start! if @step.may_start?
    @step.save!
    @run.start!
    @run.save!
    @job.update!(started_at: Time.current) if @job.started_at.nil?

    target = @job.cron? ? "scheduled task ##{@job.scheduled_task_id}" : "#{@job.repository.slug}##{@job.issue_number}"
    log("starting #{@workflow.trigger_kind} run #{@run.id} step #{@step.kind} for #{target}")

    @handler = Steps.handler_for(@step.kind).new(@run)
    @handler.call

    # A reaper, operator stop, or another state propagator can make
    # this Run/Step/Workflow terminal while the handler is still
    # executing. Reload before deciding success so we don't overwrite
    # that terminal state from stale in-memory records.
    @run.reload
    @step.reload
    @workflow.reload

    return if @run.terminal? || @step.terminal? || @workflow.terminal?

    @run.succeed!
    @run.save!
    @step.succeed!
    @step.save!
    log("step #{@step.kind} done (#{@workflow.slug})")
  end

  def cancel_ineligible_retry_workflow!
    return false unless @workflow.trigger_kind == "retry"

    eligibility = RetryWorkflowEligibility.call(job: @job, workflow: @workflow)
    return false if eligibility.eligible?

    log("retry workflow cancelled: #{eligibility.message}")
    @workflow.artifacts = (@workflow.artifacts || {}).merge(
      "retry_cancelled_reason" => eligibility.code,
      "retry_cancelled_at" => Time.current.iso8601
    )
    @workflow.cancel! if @workflow.may_cancel?
    @workflow.save!
    true
  end

  # Snapshot the diagnostic, fail the Run, and let Run/Step
  # after_update_commit fail the Step/Workflow (which fires its own
  # workspace cleanup callback). Failure accounting is per-Workflow;
  # a flaky CiFailure burst doesn't pull a Job's clean Initial down
  # with it.
  def handle_failure(exception)
    log("FAIL: #{exception.class}: #{exception.message}")

    if @run
      CaptureRunDiagnostic.capture(@run, exception, workspace: handler_workspace)
    end

    # Discard any in-memory attributes we couldn't persist. If the
    # original exception was a column-size violation
    # (ActiveRecord::ValueTooLong on `prompt` or `agent_pr_body`,
    # say) or anything else that raised mid-update, the giant
    # unsaved value is still attached to @run. A naive `fail! → save!`
    # below would try to persist it again, raise again, and the
    # Run/Step/Workflow/Job would stay wedged at :running with no
    # cascade ever firing.
    #
    # restore_attributes reverts ONLY the dirty (unpersisted)
    # attributes — keeps the in-memory record + its association
    # caches intact, unlike reload which would reset both. That
    # distinction matters for the loop-controlled grade path, where
    # the perform loop later reads @step (a sibling ivar) and would
    # be sensitive to a reload-driven association reset.
    @run&.restore_attributes

    if @run&.may_fail?
      @run.fail!
      @run.save!
    end

    record_landing_failure!(exception)
    @workflow&.record_run_failure! unless workflow_controlled_failure?
  end

  def record_landing_failure!(exception)
    return unless @workflow&.trigger_kind == "auto_merge"
    return unless @job&.landing?
    return if workflow_controlled_failure?

    LandingFailureHandler.call(job: @job, reason: "#{exception.class}: #{exception.message}", run: @run)
  end

  def execution_owner_consistent?
    @run.user_id == @job.user_id && @workflow.user_id == @job.user_id
  end

  def fail_run_without_validation!(outcome)
    @run.update_columns(
      agent_outcome: outcome,
      state: "failed",
      finished_at: Time.current,
      updated_at: Time.current
    )
  end

  # A failure is "workflow-controlled" when the dispatcher's per-kind
  # fail logic takes over (advances to next sibling for graders,
  # iterates for grader_collect / grade, or expands a declared
  # Try failure branch) rather than failing the workflow. RunJob
  # must swallow these so the outer perform loop can continue inline
  # on the next Step's Run.
  def workflow_controlled_failure?
    loop_controlled_grade_failure? || dispatcher_continued_workflow?
  end

  def loop_controlled_grade_failure?
    return false unless @step&.loop_id.present?
    %w[ grade grader grader_collect ].include?(@step.kind)
  end

  def dispatcher_continued_workflow?
    return false unless @workflow
    return false if @workflow.reload.terminal?

    next_inline_run.present?
  end

  def continue_inline_after_controlled_failure
    loop do
      break if @shutdown_requested
      next_run = next_inline_run
      break unless next_run
      if @shutdown_requested
        Rails.logger.info("[RunJob] SIGTERM — yielding at step boundary for Run ##{@run.id}, successor Run ##{next_run.id} will be re-enqueued by reaper")
        break
      end

      @run = next_run
      @step = @run.step
      @handler = nil
      Thread.current[:syrus_current_run] = @run

      begin
        perform_step
      rescue StandardError => e
        handle_failure(e)
        raise unless workflow_controlled_failure?
      end
    end
  end

  # The handler's WorkflowWorkspace, only when the handler had a
  # chance to instantiate one (i.e. the step actually started). Pre-
  # start failures (terminal-workflow guards, validation errors)
  # don't have a workspace — CaptureRunDiagnostic logs that as
  # "no workspace (Run failed before setup completed)".
  def handler_workspace
    return nil unless @handler
    @handler.send(:workspace)
  rescue StandardError
    nil
  end

  # After perform_step succeeds, Step.after_update_commit's
  # advance_next_step! has already fired StepDispatcher.advance_from
  # synchronously. The dispatcher either created a new Run on the
  # next runnable Step (Run#enqueue_run_job suppressed via
  # Thread.current[:syrus_in_run_job]) OR transitioned the Workflow
  # to succeeded (chain end).
  #
  # Pick up the newly-created Run if any so the worker can process it
  # in this same invocation. Returns nil when the chain is done — the
  # outer loop breaks and SQ frees the worker for the next job.
  def next_inline_run
    return nil if @workflow.reload.terminal?
    cursor = @step.next_step
    while cursor
      queued = cursor.runs.where(state: "queued").order(:created_at).last
      return queued if queued
      cursor = cursor.next_step
    end
    nil
  end

  def workflow_starting?
    @workflow.queued? && @step.id == @workflow.first_step&.id
  end

  def merged_pull_request
    pr_number = @job.pr_number.presence || @job.external_pr_number.presence
    return nil if pr_number.blank?

    pr_repo = @job.effective_pr_repository
    pr = GithubClient.for(repository: pr_repo, user: @job.user).pull_request(pr_repo.slug, pr_number, bypass_cache: true)
    return nil unless pr.merged == true

    {
      number: pr_number,
      closure_reason: @job.pr_number.present? ? "pr_merged" : "external_pr_merged"
    }
  end

  def succeed_workflow_for_merged_pull_request!(merged_pr)
    @workflow.start! if @workflow.may_start?
    @workflow.save!
    @step.start! if @step.may_start?
    @step.save!
    @run.start! if @run.may_start?
    @run.save!
    @job.update!(started_at: Time.current) if @job.started_at.nil?

    log("pull request already merged (PR ##{merged_pr[:number]}); " \
        "marking #{@workflow.slug} succeeded and closing job")
    cancel_downstream_steps!(reason: "pull request already merged")

    @run.succeed!
    @run.save!
    @step.succeed!
    @step.save!

    # Step's after_update_commit normally finishes the workflow via
    # StepDispatcher. Keep this explicit as a backstop for callers
    # that execute inside a transaction where after_commit is delayed.
    @workflow.reload
    if @workflow.may_succeed?
      @workflow.succeed!
      @workflow.save!
    end

    @job.reload.cancel_active_runs_and_close!(merged_pr[:closure_reason]) if @job.open?
  end

  def cancel_downstream_steps!(reason:)
    Step.suppress_cancel_cascade do
      cursor = @step.next_step
      while cursor
        if cursor.may_cancel?
          log("[#{@step.kind}] cancelling downstream step ##{cursor.id} (#{cursor.kind}): #{reason}")
          cursor.cancel!
          cursor.save!
        end
        cursor = cursor.next_step
      end
    end
  end

  # Append a transcript chunk + bump the heartbeat. Resilient to blank
  # input — incoming streams (claude's stream-json, git stdout/stderr,
  # tool output) can legitimately produce empty lines, and JobLog
  # enforces presence on `chunk`. A blank chunk would crash the run
  # mid-stream. Empty chunks still bump the heartbeat (upstream is
  # producing output → sign of life), they just don't get persisted
  # as a row. Same contract as Steps::Base#log.
  def log(chunk, kind: nil, **)
    text = chunk.to_s
    if text.strip.empty?
      @run.update_column(:last_heartbeat_at, Time.current) if @run.running?
      return
    end
    JobLog.append!(run: @run, chunk: text, kind: kind)
    @run.update_column(:last_heartbeat_at, Time.current) if @run.running?
  end
end
