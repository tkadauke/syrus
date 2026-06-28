class ReapStaleRunsJob < ApplicationJob
  include SkipIfPending

  queue_as :default

  # Three reaping signals, in order of confidence/speed:
  #
  # 1. SolidQueue itself proved the worker died — the SQ::Job for
  #    this Run is in failed_execution with a `ProcessPrunedError`.
  #    SQ's supervisor doesn't fail-claimed-executions casually:
  #    only after the owning worker process's heartbeat lapsed past
  #    `process_alive_threshold` (5 min default). When we see this,
  #    the worker process is *definitively* gone and so any RunJob
  #    code mid-perform on its behalf is gone too. Reap immediately.
  #    Recovers post-deploy zombies in ~1 min.
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
  MISSED_AUTO_RETRY_LOOKBACK = 24.hours

  def perform
    reap_runs_with_pruned_workers     # fast path
    reap_orphaned_running_runs        # ~3-min path
    reap_runs_with_stale_heartbeat    # 30-min backstop
    requeue_orphaned_queued_runs      # inline-drive successor never enqueued
    cancel_unstarted_terminal_queued_steps
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
      reap!(run, reason: "SolidQueue::ProcessPrunedError — worker process is gone (deploy or crash)")
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
  # The grace period covers the create/enqueue commit race for a
  # Workflow's very first Run.
  def requeue_orphaned_queued_runs
    cutoff = ORPHAN_RUN_GRACE_PERIOD.ago
    candidates = Run.where(state: "queued").where("created_at < ?", cutoff).to_a
    return if candidates.empty?

    driven_workflow_ids = workflow_ids_with_active_run_jobs
    candidates.each do |run|
      workflow = run.step&.workflow
      next unless workflow&.running?
      next if driven_workflow_ids.include?(workflow.id)

      Rails.logger.info("[ReapStaleRunsJob] Run ##{run.id} re-enqueued: :queued with no SolidQueue::Job and no active worker driving Workflow ##{workflow.id} (inline-drive orphan)")
      run.reenqueue!
    end
  rescue ActiveRecord::StatementInvalid => e
    Rails.logger.debug("[ReapStaleRunsJob] SolidQueue tables unreachable (#{e.class}); skipping queued-orphan path")
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
  # been finalized (finished_at NULL). A pending job, a claimed
  # job, or a failed-but-not-yet-cleaned-up job all qualify;
  # successfully-finished jobs do not. If no row matches, the Run
  # has no worker that will ever resume it — reap it.
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
      reap!(run, reason: "no SolidQueue::Job for Run ##{run.id} — orphaned (RunJob died without transitioning)")
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

  def reap!(run, reason:)
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

  def succeed_workflow!(workflow)
    return unless workflow.may_succeed?

    Rails.logger.info("[ReapStaleRunsJob] Workflow ##{workflow.id} succeeded: all steps/runs are terminal")
    workflow.succeed!
    workflow.save!
  rescue StandardError => e
    Rails.logger.warn("[ReapStaleRunsJob] workflow succeed failed for Workflow ##{workflow.id}: #{e.class}: #{e.message}")
  end

  def fail_workflow!(workflow)
    return unless workflow.may_fail?

    Rails.logger.info("[ReapStaleRunsJob] Workflow ##{workflow.id} failed: all steps/runs are terminal")
    workflow.fail!
    workflow.save!
  rescue StandardError => e
    Rails.logger.warn("[ReapStaleRunsJob] workflow fail failed for Workflow ##{workflow.id}: #{e.class}: #{e.message}")
  end
end
