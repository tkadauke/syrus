class ReapStaleRunsJob < ApplicationJob
  include SkipIfPending

  queue_as :default

  # Three reaping signals, in order of confidence/speed:
  #
  # 1. SolidQueue thinks the worker died — the SQ::Job for
  #    this Run is in failed_execution with a `ProcessPrunedError`.
  #    SQ's supervisor doesn't fail-claimed-executions casually, but
  #    production has shown this can still be a false positive under
  #    heartbeat starvation or DB contention while the agent subprocess
  #    continues streaming. Reap only when there is no fresh Run activity
  #    and no still-running SpawnedProcess for that Run.
  #
  # 2. Orphaned-Run detection — Run is :running but no SQ::Job
  #    exists for it (not pending, not claimed, not failed). This is
  #    the wedge that bit Job 360: RunJob's handle_failure raised on
  #    a dirty-attribute save retry, SQ recorded that as a clean
  #    finish (job row finished_at set, no failed_execution row),
  #    and the Run sat at :running orphaned. With no SQ::Job
  #    referencing the Run, there's no worker that can ever resume
  #    it; reap on the next pass. Grace period of 2 min for the
  #    "Run just created, SQ::Job not yet committed" race.
  #
  # 3. Heartbeat-stale (backstop). The Run's own
  #    `last_heartbeat_at` (bumped by RunJob.log on every transcript
  #    chunk) hasn't moved in Run::STALE_HEARTBEAT_THRESHOLD (30
  #    min). Catches the rare case where the worker is alive but
  #    the agent itself is wedged.
  #
  # Why we don't just use SQ claim state as the primary signal: SQ
  # will prune a *live* worker whose SQ-heartbeat thread starves
  # under DB contention — false-positive class that bit us before
  # PR #50. The signal we trust in path 1 is
  # `failed_execution + ProcessPrunedError` specifically, NOT "no
  # live claim." Path 2 uses a different signal — *no* SQ::Job at
  # all for the Run — which is unambiguous: a Run that's
  # :running with no enqueued/active job is by definition
  # orphaned.
  ORPHAN_RUN_GRACE_PERIOD = 2.minutes
  WORKER_DEATH_ACTIVITY_GRACE_PERIOD = ORPHAN_RUN_GRACE_PERIOD
  MISSED_AUTO_RETRY_LOOKBACK = 24.hours

  def perform
    reap_runs_with_pruned_workers     # fast path
    reap_orphaned_running_runs        # ~3-min path
    reap_runs_with_stale_heartbeat    # 30-min backstop
    requeue_orphaned_queued_runs      # inline-drive successor never enqueued
    start_orphaned_queued_workflows   # workflow committed, first Run never created
    cancel_unstarted_terminal_queued_steps
    fail_orphaned_workflows_with_failed_hard_stop
    finish_orphaned_terminal_workflows
    reconcile_missed_worker_died_auto_retries
  end

  private

  # Find SolidQueue::Jobs for class_name=RunJob whose only execution
  # row is a failed_execution carrying a ProcessPrunedError. Pull
  # the root Run id out of the active_job arguments, then expand it
  # to any currently-running inline Runs in the same Workflow. RunJob
  # drives an entire Workflow chain inline, so the SQ row can still
  # reference the first Step's Run while the live work has advanced to
  # a later Step's Run.
  #
  # The error is JSON-serialized in the failed_executions.error
  # column, so we LIKE-match the exception_class string. Portable
  # across SQLite dev/test and MySQL prod (no JSON-column dialect
  # required).
  def reap_runs_with_pruned_workers
    run_ids = pruned_run_ids_from_solid_queue
    return if run_ids.empty?
    Run.where(id: run_ids, state: "running").find_each do |run|
      reap!(run, reason: "SolidQueue::ProcessPrunedError — worker process is gone (deploy or crash)", guard_live_work: true)
    end
  end

  def reap_runs_with_stale_heartbeat
    Run.stale.find_each do |run|
      reap!(run, reason: "no heartbeat in #{Run::STALE_HEARTBEAT_THRESHOLD.inspect}")
    end
  end

  # Re-enqueue Runs orphaned in :queued state. RunJob drives a
  # Workflow's Step chain depth-first inside one worker process: when a
  # Step succeeds, StepDispatcher creates the next Step's Run and
  # Run#enqueue_run_job is *suppressed* — the in-process loop is
  # expected to pick the successor up rather than bounce it through
  # SolidQueue. If the worker dies in the window between creating that
  # successor Run (:queued) and running it inline (deploy SIGKILL, OOM,
  # node eviction), the Run is orphaned: :queued forever with no
  # SolidQueue::Job. The :running-orphan path above never sees it
  # because it never started, and finish_orphaned_terminal_workflows
  # skips its Workflow because a :queued Run still counts as active.
  # That wedged Job 814 in `landing` for 17h.
  #
  # A :queued Run that has never started has no side effects, so the
  # correct recovery is to re-enqueue (resume) it, not fail it.
  # Run#enqueue_run_job reuses the right queue + priority. Guard: only
  # act when NO active RunJob is driving the Run's Workflow — if one
  # is, the inline loop still owns the successor and re-enqueuing would
  # duplicate it (and risk a false worker_died if both reach the Run).
  #
  # Exception: if the Step itself is already :running while the Run is
  # still :queued, the worker died after `step.start!` but before
  # `run.start!`. That transition window should be milliseconds; after
  # the grace period it is safer to re-enqueue even when an old root
  # RunJob still appears active in SolidQueue. This is the JOB-1540
  # wedge: the Workflow is "active" forever, but no Run can make
  # progress.
  #
  # The grace period covers the create/enqueue commit race for a
  # Workflow's very first Run and the tiny Step-start/Run-start window.
  def requeue_orphaned_queued_runs
    cutoff = ORPHAN_RUN_GRACE_PERIOD.ago
    candidates = Run.where(state: "queued").where("created_at < ?", cutoff).to_a
    return if candidates.empty?

    driven_workflow_ids = workflow_ids_with_active_run_jobs
    candidates.each do |run|
      workflow = run.step&.workflow
      next unless workflow&.running? || workflow&.queued?
      step_started_without_run = run.step&.running? && run.started_at.nil?
      next if driven_workflow_ids.include?(workflow.id) && !step_started_without_run

      reason = if step_started_without_run
        "running Step ##{run.step_id} still has queued Run ##{run.id}"
      else
        ":queued with no SolidQueue::Job and no active worker driving Workflow ##{workflow.id} (inline-drive orphan)"
      end
      Rails.logger.info("[ReapStaleRunsJob] Run ##{run.id} re-enqueued: #{reason}")
      run.reenqueue!
    end
  rescue ActiveRecord::StatementInvalid => e
    Rails.logger.debug("[ReapStaleRunsJob] SolidQueue tables unreachable (#{e.class}); skipping queued-orphan path")
  end

  # Recovery for the post-transaction gap where a caller instantiated
  # a Workflow and its Step graph, then died before
  # StepDispatcher.start_workflow created the first Run. This is a
  # different shape from a queued successor Run: there is no Run at
  # all, so Run-based reapers will never see it. The Workflow remains
  # :queued and can still occupy a landing slot if its Job has already
  # moved to :landing.
  #
  # Keep the repair narrow and delegate the actual start to
  # StepDispatcher so dependency checks, prompts, queue selection, and
  # Run creation stay in one place.
  def start_orphaned_queued_workflows
    cutoff = ORPHAN_RUN_GRACE_PERIOD.ago
    Workflow.where(state: "queued")
            .where("created_at < ?", cutoff)
            .includes(:job)
            .find_each do |workflow|
      first = workflow.first_step
      next unless first&.queued?
      next if first.runs.exists?
      next unless workflow.job&.open?
      next unless workflow.job.ready_for_execution?
      next unless workflow.job.stack_ready_for_execution?

      Rails.logger.info("[ReapStaleRunsJob] Workflow ##{workflow.id} started: :queued with no first Run after #{ORPHAN_RUN_GRACE_PERIOD.inspect}")
      StepDispatcher.start_workflow(workflow)
    end
  end

  # Workflow ids that have at least one non-finalized RunJob in
  # SolidQueue (the root Run the SQ::Job names belongs to that
  # Workflow, and the inline driver advances through the rest of its
  # chain). A queued Run inside one of these Workflows is still owned
  # by a live worker and must NOT be re-enqueued.
  def workflow_ids_with_active_run_jobs
    root_run_ids = active_run_job_root_run_ids
    return Set.new if root_run_ids.empty?

    Run.joins(:step)
       .where(id: root_run_ids)
       .distinct
       .pluck("steps.workflow_id")
       .compact
       .to_set
  end

  # Finds Runs in :running state with no active SQ::Job referencing
  # them. "Active" here means a row in solid_queue_jobs that hasn't
  # been finalized (finished_at NULL) and has not moved to
  # solid_queue_failed_executions. A pending, ready, claimed, or
  # scheduled job qualifies; failed jobs do not, even if Solid Queue
  # leaves finished_at NULL on the job row. If no row matches, the
  # Run has no worker that will ever resume it — reap it.
  #
  # Grace period (ORPHAN_RUN_GRACE_PERIOD) prevents reaping a Run
  # whose RunJob enqueue hasn't committed yet (the AR transaction
  # creating the Run and enqueuing the SQ::Job can briefly leave
  # the Run visible before the SQ::Job is).
  def reap_orphaned_running_runs
    cutoff = ORPHAN_RUN_GRACE_PERIOD.ago
    candidates = Run.where(state: "running").where("started_at < ?", cutoff).to_a
    return if candidates.empty?

    active_ids = active_run_job_run_ids
    candidates.each do |run|
      next if active_ids.include?(run.id)
      reap!(run, reason: "no SolidQueue::Job for Run ##{run.id} — orphaned (RunJob died without transitioning)", guard_live_work: true)
    end
  rescue ActiveRecord::StatementInvalid => e
    Rails.logger.debug("[ReapStaleRunsJob] SolidQueue tables unreachable (#{e.class}); skipping orphan-run path")
  end

  # Returns the set of Run ids owned by any non-finalized SQ::Job for
  # class_name=RunJob. The SQ row's arguments only contain the root
  # Run id passed to RunJob.perform. Because RunJob processes the rest
  # of that Workflow inline, a later Step's Run may be `running` with
  # no SQ row that names it directly. Treat all running Runs in those
  # active Workflows as active.
  def active_run_job_run_ids
    expand_root_run_ids_to_running_inline_runs(active_run_job_root_run_ids)
  end

  def active_run_job_root_run_ids
    SolidQueue::Job
      .where(class_name: "RunJob", finished_at: nil)
      .left_outer_joins(:failed_execution)
      .where(solid_queue_failed_executions: { id: nil })
      .pluck(:arguments)
      .filter_map { |args| args&.dig("arguments")&.first }
      .map(&:to_i)
  end

  # Returns the set of Run ids whose RunJob's SQ::Job has a
  # `failed_execution` whose error string includes
  # `ProcessPrunedError`. One join + one LIKE per pass. The
  # filtered result set is bounded by "Runs whose worker died
  # since the last reap" — usually 0, occasionally a small batch
  # right after a deploy.
  def pruned_run_ids_from_solid_queue
    expand_root_run_ids_to_running_inline_runs(pruned_root_run_ids_from_solid_queue)
  rescue ActiveRecord::StatementInvalid => e
    # The SolidQueue tables aren't reachable from this connection
    # — local dev/test runs single-database, so the queue tables
    # don't exist there. Heartbeat-stale path still covers this.
    Rails.logger.debug("[ReapStaleRunsJob] SolidQueue tables unreachable (#{e.class}); skipping pruned-worker fast path")
    Set.new
  end

  def pruned_root_run_ids_from_solid_queue
    SolidQueue::Job
      .where(class_name: "RunJob")
      .joins(:failed_execution)
      .where("solid_queue_failed_executions.error LIKE ?", "%ProcessPrunedError%")
      .pluck(:arguments)
      .filter_map { |args| args&.dig("arguments")&.first }
      .map(&:to_i)
      .uniq
  end

  def expand_root_run_ids_to_running_inline_runs(root_run_ids)
    root_run_ids = root_run_ids.map(&:to_i).uniq
    return Set.new if root_run_ids.empty?

    workflow_ids = Run.joins(:step)
                      .where(id: root_run_ids)
                      .distinct
                      .pluck("steps.workflow_id")
                      .compact

    inline_run_ids = if workflow_ids.empty?
      []
    else
      Run.joins(:step)
         .where(state: "running", steps: { workflow_id: workflow_ids })
         .pluck(:id)
    end
    (root_run_ids + inline_run_ids).map(&:to_i).to_set
  end

  def reap!(run, reason:, guard_live_work: false)
    if guard_live_work && (deferral_reason = live_work_deferral_reason(run))
      Rails.logger.info("[ReapStaleRunsJob] Run ##{run.id} not reaped yet despite #{reason}: #{deferral_reason}")
      return
    end

    if (reconciliation = RunCompletionReconciler.call(run)).reconciled?
      Rails.logger.info("[ReapStaleRunsJob] Run ##{run.id} reconciled instead of reaped: #{reconciliation.reason}")
      return
    end

    return unless run.may_fail?

    Rails.logger.info("[ReapStaleRunsJob] Run ##{run.id} reaped: #{reason}")
    run.agent_outcome = "worker_died"
    run.fail!
    run.save!

    # Workflow's terminal-state callback handles workspace teardown
    # on its own when Run.fail above triggers Step.fail (via Step's
    # after_update_commit) which triggers Workflow.fail. The reaper
    # only needs to make sure the Run+Step both transition.
    step = run.step
    if step&.may_fail?
      step.fail!
      step.save!
    end
    if step
      step.reload
      StepDispatcher.fail_from(step) if step.failed?
    end
  rescue StandardError => e
    Rails.logger.warn("[ReapStaleRunsJob] reap failed for Run ##{run.id}: #{e.class}: #{e.message}")
  end

  def live_work_deferral_reason(run)
    heartbeat_at = run.last_heartbeat_at
    return "fresh Run heartbeat at #{heartbeat_at.iso8601}" if recent_worker_death_activity?(heartbeat_at)

    log_at = JobLog.where(run_id: run.id).maximum(:created_at)
    return "fresh JobLog at #{log_at.iso8601}" if recent_worker_death_activity?(log_at)

    process = SpawnedProcess.running.where(run_id: run.id).order(Arel.sql("COALESCE(last_chunk_at, started_at) DESC")).first
    return nil unless process

    process_at = process.last_chunk_at || process.started_at
    if recent_worker_death_activity?(process_at)
      "active SpawnedProcess ##{process.id} with recent output at #{process_at.iso8601}"
    else
      "active SpawnedProcess ##{process.id}"
    end
  end

  def recent_worker_death_activity?(timestamp)
    timestamp.present? && timestamp >= WORKER_DEATH_ACTIVITY_GRACE_PERIOD.ago
  end

  # Backstop for deploy/crash failures that reached Workflow#failed
  # before auto-retry scheduling was reliable. Keep it deliberately
  # narrow: recent workflows only, and only when the latest failed
  # Run was reaped as worker_died.
  def reconcile_missed_worker_died_auto_retries
    Workflow.failed
            .where("finished_at >= ?", MISSED_AUTO_RETRY_LOOKBACK.ago)
            .find_each do |workflow|
      next if workflow.auto_retry_attempts.where(performed_at: nil, skipped_reason: nil).exists?

      latest_failed_run = workflow.runs.where(state: "failed").order(created_at: :desc).first
      next unless latest_failed_run&.agent_outcome == "worker_died"

      AutoRetryScheduler.schedule_for_workflow(workflow: workflow)
    end
  end

  # Recovery for a worker-death race where a downstream Step's Run was
  # cancelled before it ever started, but the Step itself stayed queued.
  # With all Runs terminal, no worker can ever advance that Step; with
  # the Step still queued, finish_orphaned_terminal_workflows refuses to
  # close the parent Workflow. Cancel only the impossible Step here, then
  # let the workflow finisher below infer the Workflow outcome from the
  # meaningful succeeded/failed Step positions.
  def cancel_unstarted_terminal_queued_steps
    Step.where(state: "queued")
        .joins(:workflow)
        .where(workflows: { state: "running" })
        .find_each do |step|
      runs = step.runs.to_a
      next if runs.empty?
      next unless runs.all?(&:terminal?)
      next if runs.any? { |run| run.started_at.present? }
      next unless step.may_cancel?

      Rails.logger.info("[ReapStaleRunsJob] Step ##{step.id} cancelled: queued with only unstarted terminal Runs")
      Step.suppress_cancel_cascade do
        step.cancel!
        step.save!
      end
    end
  end

  # Recovery for a missed hard-failure propagation: a Step reached
  # :failed, no Run remains active, but downstream queued Steps still
  # make Workflow#active_descendants? true. That shape cannot advance
  # without a worker, and finish_orphaned_terminal_workflows below
  # deliberately skips it because the queued tail is still active.
  #
  # Preserve the queued tail. Workflow#fail intentionally leaves
  # downstream Steps alone so "Retry from failed step" can reopen the
  # failed Step and continue through the existing chain.
  def fail_orphaned_workflows_with_failed_hard_stop
    Workflow.where(state: "running")
            .where("started_at < ?", ORPHAN_RUN_GRACE_PERIOD.ago)
            .find_each do |workflow|
      next unless workflow.steps.active.exists?
      next if Run.where(step_id: workflow.steps.select(:id)).active.exists?

      failed_step = latest_orphaned_hard_failure_step(workflow)
      next unless failed_step

      reason = orphaned_hard_failure_reason(workflow, failed_step)
      workflow.failure_reason = reason
      workflow.artifacts = (workflow.artifacts || {}).merge("failure_reason" => reason)
      fail_workflow!(workflow, log_reason: "failed #{failed_step.kind} step with queued tail and no active runs")
    end
  end

  # Recovery for the post-step gap: the last Run and Step reached a
  # terminal state, but the StepDispatcher callback that should
  # transition the Workflow itself never completed. At that point
  # there is no running Run left for the stale-run paths above to
  # reap, yet the running Workflow still blocks landing and dashboard
  # filters.
  #
  # Keep this narrow: only finish Workflows with no queued/running
  # Steps and no queued/running Runs. If any Step is still active,
  # normal dispatch owns it. Failed grader-loop iterations can coexist
  # with an eventually-succeeded Workflow, so infer the outcome from
  # the latest succeeded/failed Step position rather than the mere
  # presence of any failure.
  def finish_orphaned_terminal_workflows
    Workflow.where(state: "running")
            .where("started_at < ?", ORPHAN_RUN_GRACE_PERIOD.ago)
            .find_each do |workflow|
      next if workflow.steps.active.exists?
      next if Run.where(step_id: workflow.steps.select(:id)).active.exists?

      case orphaned_workflow_outcome(workflow)
      when :succeeded
        succeed_workflow!(workflow)
      when :failed
        fail_workflow!(workflow)
      end
    end
  end

  def orphaned_workflow_outcome(workflow)
    terminal_positions = workflow.steps.pluck(:state, :position)
    last_succeeded = terminal_positions.filter_map { |state, position| position if state == "succeeded" }.max
    last_failed = terminal_positions.filter_map { |state, position| position if state == "failed" }.max

    return :succeeded if last_succeeded && (last_failed.nil? || last_succeeded > last_failed)
    return :failed if last_failed && (last_succeeded.nil? || last_failed > last_succeeded)

    nil
  end

  CONTINUABLE_FAILURE_STEP_KINDS = %w[
    grade
    grader
    grader_collect
  ].freeze

  def latest_orphaned_hard_failure_step(workflow)
    return unless orphaned_workflow_outcome(workflow) == :failed

    step = workflow.steps.where(state: "failed").order(position: :desc).first
    return unless step
    return if CONTINUABLE_FAILURE_STEP_KINDS.include?(step.kind)
    return if unexpanded_try_failure?(step)

    step
  end

  def unexpanded_try_failure?(step)
    details = step.details.to_h
    details["try_id"].present? && !details["try_branch_expanded"]
  end

  def orphaned_hard_failure_reason(workflow, failed_step)
    existing = workflow.failure_reason.presence || workflow.artifact("failure_reason").presence
    return existing if existing.present?

    failed_run = failed_step.runs.where(state: "failed").order(created_at: :desc).first ||
      workflow.runs.where(state: "failed").order(created_at: :desc).first
    return "#{failed_run.agent_outcome} during #{failed_step.kind}" if failed_run&.agent_outcome.present?

    "#{failed_step.kind} failed with no active runs"
  end

  def succeed_workflow!(workflow)
    return unless workflow.may_succeed?

    Rails.logger.info("[ReapStaleRunsJob] Workflow ##{workflow.id} succeeded: all steps/runs are terminal")
    StateTransition.with_source("reconciler") do
      workflow.succeed!
      workflow.save!
    end
  rescue StandardError => e
    Rails.logger.warn("[ReapStaleRunsJob] workflow succeed failed for Workflow ##{workflow.id}: #{e.class}: #{e.message}")
  end

  def fail_workflow!(workflow, log_reason: "all steps/runs are terminal")
    return unless workflow.may_fail?

    Rails.logger.info("[ReapStaleRunsJob] Workflow ##{workflow.id} failed: #{log_reason}")
    StateTransition.with_source("reconciler") do
      workflow.fail!
      workflow.save!
    end
  rescue StandardError => e
    Rails.logger.warn("[ReapStaleRunsJob] workflow fail failed for Workflow ##{workflow.id}: #{e.class}: #{e.message}")
  end
end
