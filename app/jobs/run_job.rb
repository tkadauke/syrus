class RunJob < ApplicationJob
  # Dedicated `runs` queue with its own SQ worker — see
  # config/queue.yml. RunJobs are minutes-long agent invocations;
  # putting them on the shared `default` queue starves Turbo
  # broadcasts and the recurring reaper/pollers, which makes the
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
  #      parent Workflow / Step is already terminal (something else
  #      reaped or cancelled this chain).
  #   2. Re-entrancy guard: a Run found in `running` state on entry
  #      means the prior worker died mid-perform — fail it with
  #      `worker_died` so the operator can use Retry/Resume.
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
  #   6. On failure: capture a diagnostic, fail Run + Step (which
  #      triggers Workflow.fail via Step's after_update_commit, so
  #      the workspace cleans up via Workflow's terminal-state
  #      callback).
  # When the operator console pauses runs, fresh perform-attempts
  # re-enqueue themselves with a delay rather than starting work.
  # The Run stays in `queued` (or whatever state it was in); the
  # next attempt rechecks. When unpaused, work proceeds. Cost
  # while paused: 1 re-enqueue per Run per RUNS_PAUSED_RETRY_DELAY,
  # which is fine for a kill-switch state that's typically minutes,
  # not days.
  RUNS_PAUSED_RETRY_DELAY = 30.seconds

  def perform(run_id)
    if AppSetting.runs_paused?
      Rails.logger.info("[RunJob] runs paused — deferring Run ##{run_id} by #{RUNS_PAUSED_RETRY_DELAY}")
      self.class.set(wait: RUNS_PAUSED_RETRY_DELAY).perform_later(run_id)
      return
    end

    @run = ::Run.find(run_id)
    Thread.current[:syrus_current_run] = @run
    Thread.current[:syrus_in_run_job] = true
    return if @run.terminal?

    @step = @run.step
    @workflow = @step&.workflow
    @job = @run.job

    loop do
      perform_step
      next_run = next_inline_run
      break unless next_run
      @run = next_run
      @step = @run.step
      @handler = nil
      Thread.current[:syrus_current_run] = @run
    end
  rescue StandardError => e
    handle_failure(e)
    raise
  ensure
    Thread.current[:syrus_current_run] = nil
    Thread.current[:syrus_in_run_job] = nil
  end

  private

  def perform_step
    if @workflow.nil? || @step.nil?
      raise "Run ##{@run.id} has no Step / Workflow — backfill must run before legacy Runs can execute"
    end

    if @workflow.terminal?
      log("workflow ##{@workflow.id} already terminal (#{@workflow.state}); abandoning run")
      @run.cancel! if @run.may_cancel?
      @run.save!
      return
    end

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
      @run.agent_outcome = "worker_died"
      @run.fail!
      @run.save!
      @step.fail! if @step.may_fail?
      @step.save!
      @workflow.record_run_failure!
      log("run abandoned — worker died mid-execution; use Retry to try again")
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

    @run.succeed!
    @run.save!
    @step.succeed!
    @step.save!
    log("step #{@step.kind} done (workflow ##{@workflow.id})")
  end

  # Snapshot the diagnostic, fail the Run + Step, and let Step's
  # after_update_commit fail the Workflow (which fires its own
  # workspace cleanup callback). Failure accounting is per-Workflow;
  # a flaky CiFailure burst doesn't pull a Job's clean Initial down
  # with it.
  def handle_failure(exception)
    log("FAIL: #{exception.class}: #{exception.message}")

    if @run
      CaptureRunDiagnostic.capture(@run, exception, workspace: handler_workspace)
    end

    if @run&.may_fail?
      @run.fail!
      @run.save!
    end

    if @step&.may_fail?
      @step.fail!
      @step.save!
      @workflow&.record_run_failure!
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

  # Append a transcript chunk + bump the heartbeat. Resilient to blank
  # input — incoming streams (claude's stream-json, git stdout/stderr,
  # tool output) can legitimately produce empty lines, and JobLog
  # enforces presence on `chunk`. A blank chunk would crash the run
  # mid-stream. Empty chunks still bump the heartbeat (upstream is
  # producing output → sign of life), they just don't get persisted
  # as a row. Same contract as Steps::Base#log.
  def log(chunk, kind: nil)
    text = chunk.to_s
    if text.strip.empty?
      @run.update_column(:last_heartbeat_at, Time.current) if @run.running?
      return
    end
    next_seq = (@run.job_logs.maximum(:sequence) || -1) + 1
    @run.job_logs.create!(chunk: text, sequence: next_seq, kind: kind)
    @run.update_column(:last_heartbeat_at, Time.current) if @run.running?
  end
end
