require "set"

module WorkEngine
  class Reconciler
    ORPHAN_RUN_GRACE_PERIOD = ReapStaleRunsJob::ORPHAN_RUN_GRACE_PERIOD
    DETACHED_WORKER_EVIDENCE_GRACE = 3.minutes
    QUEUE_STARVATION_AFTER = 10.minutes
    RESOURCE_CONGESTION_CHECK_AFTER = 5.minutes
    RATE_LIMIT_CHECK_AFTER = 10.minutes

    AFFECTED_ID_KEYS = %i[job_ids workflow_ids step_ids run_ids work_intent_ids work_unit_ids solid_queue_job_ids spawned_process_ids].freeze
    NONRETRYABLE_CLASSIFICATIONS = %w[
      git_conflict
      git_non_fast_forward
      no_changes_produced
      semantic_failure
    ].freeze
    QUEUED_CANCELLED_WORKFLOW_RECOVERY_TRIGGER_KINDS = %w[
      initial
      retry
      replay
      manual
      resume
      pr_comment
      chat_feedback
      ci_failure
      coding_handoff
      local_mode_handoff
    ].freeze
    DELIBERATE_CANCELLED_WORKFLOW_REASONS = %w[
      job_closed
      operator_cancelled
      operator_stale_work_repair
      external_pr_closed
      external_pr_merged
      no_changes
    ].freeze

    Issue = Data.define(
      :kind,
      :severity,
      :evidence,
      :affected_ids,
      :safe_to_auto_repair,
      :recommended_repair_action,
      :retry_after,
      :check_after,
      :explanation
    ) do
      def initialize(kind:, severity:, evidence:, affected_ids:, safe_to_auto_repair:, recommended_repair_action:, explanation:, retry_after: nil, check_after: nil)
        super(
          kind: kind.to_s,
          severity: severity.to_s,
          evidence: evidence.deep_stringify_keys,
          affected_ids: affected_ids.slice(*AFFECTED_ID_KEYS).transform_values { |ids| Array(ids).compact.uniq },
          safe_to_auto_repair: !!safe_to_auto_repair,
          recommended_repair_action: recommended_repair_action.to_s,
          retry_after: retry_after,
          check_after: check_after,
          explanation: explanation.to_s
        )
      end

      def as_json(*)
        {
          kind: kind,
          severity: severity,
          evidence: evidence,
          affected_ids: affected_ids,
          safe_to_auto_repair: safe_to_auto_repair,
          recommended_repair_action: recommended_repair_action,
          retry_after: retry_after&.iso8601,
          check_after: check_after&.iso8601,
          explanation: explanation
        }
      end
    end

    Snapshot = Data.define(
      :source,
      :captured_at,
      :job_ids,
      :workflow_ids,
      :step_ids,
      :run_ids,
      :work_intent_ids,
      :work_unit_ids,
      :solid_queue_available,
      :solid_queue_jobs,
      :solid_queue_processes,
      :solid_queue_pauses,
      :spawned_process_ids,
      :instance_version_ids,
      :main_health,
      :rate_limits,
      :workspaces
    ) do
      def as_json(*)
        {
          source: source,
          captured_at: captured_at.iso8601,
          job_ids: job_ids,
          workflow_ids: workflow_ids,
          step_ids: step_ids,
          run_ids: run_ids,
          work_intent_ids: work_intent_ids,
          work_unit_ids: work_unit_ids,
          solid_queue_available: solid_queue_available,
          solid_queue_jobs: solid_queue_jobs,
          solid_queue_processes: solid_queue_processes,
          solid_queue_pauses: solid_queue_pauses,
          spawned_process_ids: spawned_process_ids,
          instance_version_ids: instance_version_ids,
          main_health: main_health,
          rate_limits: rate_limits.map(&:as_json),
          workspaces: workspaces
        }
      end
    end

    Result = Data.define(:source, :captured_at, :snapshot, :issues, :repair_plans, :repair_executions) do
      def issue_kinds = issues.map(&:kind)
      def ok? = issues.empty?

      def as_json(*)
        {
          source: source,
          captured_at: captured_at.iso8601,
          snapshot: snapshot.as_json,
          issues: issues.map(&:as_json),
          repair_plans: repair_plans.map(&:as_json),
          repair_executions: repair_executions.map(&:as_json)
        }
      end
    end

    def self.call(...) = new(...).call

    def self.request(source:, job: nil, workflow: nil, run: nil, work_intent: nil)
      args = {
        source: source.to_s,
        job_id: job&.id,
        workflow_id: workflow&.id,
        run_id: run&.id
      }
      args[:work_intent_id] = work_intent.id if work_intent
      WorkEngine::ReconcileJob.perform_later(**args)
    end

    def initialize(source:, job_id: nil, workflow_id: nil, run_id: nil, work_intent_id: nil, now: Time.current, execute_repairs: false)
      @source = source.to_s
      @job_id = job_id
      @workflow_id = workflow_id
      @run_id = run_id
      @work_intent_id = work_intent_id
      @now = now
      @execute_repairs = execute_repairs
    end

    def call
      WorkEngine::ReconcilerActivity.record_run_started!(
        source: source,
        job_id: job_id,
        workflow_id: workflow_id,
        run_id: run_id,
        work_intent_id: work_intent_id,
        now: now,
        execute_repairs: execute_repairs?
      )
      @jobs = scoped_jobs.includes(:repository, :dependencies, :epic).to_a
      @workflows = scoped_workflows.includes(:job, :steps).to_a
      @work_intents = scoped_work_intents.includes(:work_units).to_a
      @work_units = scoped_work_units.includes(:work_intent, :work_unit_locks, :work_unit_members, :workflow, :parent_work_unit).to_a
      @runs = scoped_runs.includes(:job, :step, :provider_session_metadata, :run_failure_classification, :run_diagnostic).to_a
      workflow_steps = @workflows.flat_map(&:steps)
      missing_run_step_ids = @runs.filter_map(&:step_id) - workflow_steps.map(&:id)
      @steps = workflow_steps + (missing_run_step_ids.empty? ? [] : Step.where(id: missing_run_step_ids).to_a)
      @solid_queue = capture_solid_queue

      issues = []
      issues.concat(classify_epic_workflow_conflicts)
      issues.concat(classify_closed_jobs_with_active_workflows)
      issues.concat(classify_superseded_active_workflows)
      issues.concat(classify_terminal_workflows_with_active_descendants)
      issues.concat(classify_active_runs_on_terminal_steps)
      issues.concat(classify_queued_runs)
      issues.concat(classify_paused_queues)
      issues.concat(classify_running_runs)
      issues.concat(classify_active_steps_with_terminal_runs)
      issues.concat(classify_queued_steps_without_runs)
      issues.concat(classify_workflows)
      issues.concat(classify_waiting_work_intents_ready_for_recheck)
      issues.concat(classify_dispatcher_owned_work_intents_without_active_units)
      issues.concat(classify_requested_work_intents_without_active_units)
      issues.concat(classify_active_work_units_without_workflows)
      issues.concat(classify_succeeded_work_units_with_unsatisfied_intents)
      issues.concat(classify_terminal_work_units_with_active_locks)
      issues.concat(classify_active_child_work_units_with_terminal_parents)
      issues.concat(classify_stale_auto_retry_workflows)
      issues.concat(classify_job_workflow_drift)
      issues.concat(classify_failed_jobs_with_active_repair_work)
      issues.concat(classify_jobs_without_active_workflows)
      issues.concat(classify_queued_jobs_cancelled_by_epic_workflow_conflict)
      issues.concat(classify_queued_jobs_cancelled_without_active_workflow)
      issues.concat(classify_approved_jobs_with_landing_start_blockers)
      issues.concat(classify_approved_jobs_missing_pr)
      issues.concat(classify_implemented_jobs_missing_pr)
      issues.concat(classify_unambiguous_job_state_drift)
      issues.concat(classify_completed_infrastructure_jobs)
      issues.concat(classify_start_blocks)
      issues.concat(classify_main_broken_workflows)
      issues.concat(classify_resource_congestion)
      issues.concat(classify_rate_limits)
      issues.concat(classify_workspace_availability)
      issues.concat(classify_resumable_sessions)
      issues.concat(classify_branch_divergence)
      issues.concat(classify_retryable_failures)
      issues.concat(classify_nonretryable_failures)
      issues.concat(classify_cleanup_blockers)
      issues.concat(classify_workspace_prune_risks)
      issues.concat(classify_runaway_protected_jobs)

      result = Result.new(source: source, captured_at: now, snapshot: snapshot, issues: issues, repair_plans: [], repair_executions: [])
      repair_plans = WorkEngine::RepairPlanner.call(result: result, now: now)
      result = result.with(repair_plans: repair_plans)
      unless execute_repairs?
        WorkEngine::ReconcilerActivity.record_result!(
          source: source,
          job_id: job_id,
          workflow_id: workflow_id,
          run_id: run_id,
          work_intent_id: work_intent_id,
          now: now,
          execute_repairs: false,
          result: result
        )
        return result
      end

      result = result.with(repair_executions: WorkEngine::RepairExecutor.call(result: result, now: now))
      WorkEngine::ReconcilerActivity.record_result!(
        source: source,
        job_id: job_id,
        workflow_id: workflow_id,
        run_id: run_id,
        work_intent_id: work_intent_id,
        now: now,
        execute_repairs: true,
        result: result
      )
      result
    rescue StandardError => e
      WorkEngine::ReconcilerActivity.record_failure!(
        source: source,
        job_id: job_id,
        workflow_id: workflow_id,
        run_id: run_id,
        work_intent_id: work_intent_id,
        now: now,
        execute_repairs: execute_repairs?,
        error: e
      )
      raise
    ensure
      Rails.logger.info(
        "[WorkEngine::Reconciler] requested by #{source}" \
        "#{context_description}; issues=#{issues&.size || 0}; execute_repairs=#{execute_repairs?}"
      )
    end

    private

    attr_reader :source, :job_id, :workflow_id, :run_id, :work_intent_id, :now, :jobs, :workflows, :work_intents, :work_units, :runs, :steps, :solid_queue

    def execute_repairs?
      @execute_repairs
    end

    def scoped_jobs
      if job_id.present?
        Job.where(id: job_id)
      elsif work_intent_id.present?
        WorkIntent.where(id: work_intent_id, scope_type: "job").select(:scope_id).then { |ids| Job.where(id: ids) }
      elsif workflow_id.present?
        Job.where(id: Workflow.where(id: workflow_id).select(:job_id))
      elsif run_id.present?
        Job.where(id: Run.where(id: run_id).select(:job_id))
      else
        active_job_ids = WorkUnits::Ownership.all_active_job_ids.to_a
        Job.where(id: Job.open_threads.select(:id))
           .or(Job.where(id: active_job_ids))
      end
    end

    def scoped_workflows
      if workflow_id.present?
        Workflow.where(id: workflow_id)
      elsif work_intent_id.present?
        Workflow.where(id: WorkUnit.where(work_intent_id: work_intent_id).select(:workflow_id))
      elsif run_id.present?
        Workflow.where(id: Step.where(id: Run.where(id: run_id).select(:step_id)).select(:workflow_id))
      elsif job_id.present?
        active_ids = Workflow.where(job_id: job_id, state: %w[ queued running failed ]).pluck(:id)
        terminal_descendant_ids = terminal_workflows_with_active_descendants(job_ids: [ job_id ]).pluck(:id)

        Workflow.where(id: active_ids + terminal_descendant_ids)
      else
        active_ids = Workflow.where(job_id: jobs.map(&:id), state: %w[ queued running failed ]).pluck(:id)
        terminal_descendant_ids = terminal_workflows_with_active_descendants.pluck(:id)

        Workflow.where(id: active_ids + terminal_descendant_ids)
      end
    end

    def scoped_runs
      if run_id.present?
        Run.where(id: run_id)
      elsif work_intent_id.present?
        Run.where(step_id: Step.where(workflow_id: workflows.map(&:id)).select(:id)).where(state: %w[ queued running failed ])
      else
        step_ids = workflows.flat_map { |workflow| workflow.steps.map(&:id) }
        Run.where(step_id: step_ids).where(state: %w[ queued running failed ])
      end
    end

    def scoped_work_intents
      if workflow_id.present?
        WorkIntent.joins(:work_units).where(work_units: { workflow_id: workflow_id })
      elsif work_intent_id.present?
        WorkIntent.where(id: work_intent_id)
      elsif run_id.present?
        WorkIntent.joins(:work_units).where(work_units: { workflow_id: Step.where(id: Run.where(id: run_id).select(:step_id)).select(:workflow_id) })
      elsif job_id.present?
        direct_intents = WorkIntent.where(scope_type: "job", scope_id: job_id)
        member_intents = WorkIntent
          .joins(work_units: :work_unit_members)
          .where(work_unit_members: { job_id: job_id })
        WorkIntent.where(id: direct_intents.select(:id)).or(WorkIntent.where(id: member_intents.select(:id)))
      else
        WorkIntent.where(state: "waiting")
      end
    end

    def scoped_work_units
      if workflow_id.present?
        WorkUnit.where(workflow_id: workflow_id)
      elsif work_intent_id.present?
        WorkUnit.where(work_intent_id: work_intent_id)
      elsif run_id.present?
        WorkUnit.where(workflow_id: Step.where(id: Run.where(id: run_id).select(:step_id)).select(:workflow_id))
      elsif job_id.present?
        member_unit_ids = WorkUnit
          .joins(:work_unit_members)
          .where(work_unit_members: { job_id: job_id })
          .select(:id)
        workflow_unit_ids = WorkUnit.where(workflow_id: workflows.map(&:id)).select(:id)
        WorkUnit.where(id: member_unit_ids).or(WorkUnit.where(id: workflow_unit_ids))
      else
        active_units = WorkUnit.where(state: WorkUnits::Ownership::ACTIVE_STATES)
        terminal_locked_units = WorkUnit
          .joins(:work_unit_locks)
          .where(state: %w[succeeded failed cancelled], work_unit_locks: { released_at: nil })
        succeeded_unsatisfied_units = WorkUnit
          .joins(:work_intent)
          .where(state: "succeeded", work_intents: { state: %w[requested waiting] })
        WorkUnit.where(id: active_units.select(:id))
          .or(WorkUnit.where(id: terminal_locked_units.select(:id)))
          .or(WorkUnit.where(id: succeeded_unsatisfied_units.select(:id)))
      end
    end

    # A Workflow can reach a terminal state while child Steps/Runs are left
    # behind in queued/running. Drive this off active descendants (small sets)
    # instead of scanning every terminal Workflow, so old failed/cancelled
    # Workflows do not keep invisible queued work forever.
    # job_ids: nil scans every active Step/Run system-wide (the periodic
    # full reconcile's job). A job_id-scoped reconcile request (fired on
    # nearly every landing-queue/admission-wakeup/repair event) must not
    # pay for that global scan just to check its own job's workflows, so
    # narrow the Step/Run lookup to that job's workflows first.
    def terminal_workflows_with_active_descendants(job_ids: nil)
      active_steps = Step.where(state: Step::ACTIVE_STATES)
      steps_with_active_runs = Step.where(id: Run.where(state: Run::ACTIVE_STATES).select(:step_id))

      if job_ids
        workflow_ids = Workflow.where(job_id: job_ids).select(:id)
        active_steps = active_steps.where(workflow_id: workflow_ids)
        steps_with_active_runs = steps_with_active_runs.where(workflow_id: workflow_ids)
      end

      Workflow.terminal.where(id: active_steps.select(:workflow_id))
        .or(Workflow.terminal.where(id: steps_with_active_runs.select(:workflow_id)))
    end

    def classify_queued_runs
      return [] unless solid_queue[:available]

      runs.select(&:queued?).filter_map do |run|
        next if run.job&.closed?
        next if run.step&.terminal?
        next unless older_than?(run.created_at, ORPHAN_RUN_GRACE_PERIOD)

        sqs = solid_queue_jobs_for_run(run)
        workflow = run.workflow
        next unless workflow&.queued? || workflow&.running?
        next if stale_auto_retry_attempt_for(workflow)
        next if pending_auto_retry_attempt?(workflow)

        if sqs.empty?
          issue(
            kind: :queued_run_without_queue_claim,
            severity: :error,
            affected_ids: ids_for(run),
            safe_to_auto_repair: workflow&.running? || workflow&.queued?,
            recommended_repair_action: "reenqueue_run",
            evidence: run_evidence(run).merge(solid_queue_state: "missing", age_seconds: seconds_since(run.created_at)),
            explanation: "Run ##{run.id} is queued but no active SolidQueue RunJob references it."
          )
        elsif sqs.none? { |sq| queue_job_can_progress?(sq) } && (sq = sqs.find { |candidate| candidate[:ready] && dead_resume_queue?(candidate[:queue_name]) })
          if grader_collect_cached_failure?(run)
            issue(**grader_collect_cached_failure_issue(run, workflow, sq, "dead_resume_queue"))
          else
            issue(
              kind: :queued_run_on_dead_resume_queue,
              severity: :error,
              affected_ids: ids_for(run).merge(solid_queue_job_ids: [ sq[:id] ]),
              safe_to_auto_repair: workflow&.running? || workflow&.queued?,
              recommended_repair_action: "reenqueue_run",
              evidence: run_evidence(run).merge(solid_queue: sq, solid_queue_state: "dead_resume_queue"),
              explanation: "Run ##{run.id} is queued on a storage-affinity resume queue with no live worker."
            )
          end
        elsif sqs.none? { |sq| queue_job_can_progress?(sq) } && (sq = sqs.find { |candidate| candidate[:failed] })
          if grader_collect_cached_failure?(run)
            issue(**grader_collect_cached_failure_issue(run, workflow, sq, "failed_execution"))
          else
            issue(
              kind: :queued_run_solid_queue_failed_execution,
              severity: :error,
              affected_ids: ids_for(run).merge(solid_queue_job_ids: [ sq[:id] ]),
              safe_to_auto_repair: workflow&.running? || workflow&.queued?,
              recommended_repair_action: "reenqueue_run",
              evidence: run_evidence(run).merge(solid_queue: sq, solid_queue_state: "failed_execution"),
              explanation: "Run ##{run.id} is queued but its SolidQueue RunJob has a failed execution."
            )
          end
        elsif sqs.none? { |sq| queue_job_can_progress?(sq) } && (sq = sqs.find { |candidate| stale_queue_claim?(candidate) })
          issue(
            kind: :queued_run_stale_queue_claim,
            severity: :warning,
            affected_ids: ids_for(run).merge(solid_queue_job_ids: [ sq[:id] ]),
            safe_to_auto_repair: false,
            recommended_repair_action: "check_queue_worker_or_wait",
            check_after: now + RESOURCE_CONGESTION_CHECK_AFTER,
            evidence: run_evidence(run).merge(solid_queue: sq, claim_age_seconds: seconds_since(sq[:claimed_at])),
            explanation: "Run ##{run.id} is still queued behind a stale or unreachable SolidQueue claim."
          )
        end
      end
    end

    def classify_active_runs_on_terminal_steps
      runs.select { |run| run.queued? || run.running? }.filter_map do |run|
        step = run.step
        next unless step&.terminal?

        issue(
          kind: :active_run_on_terminal_step,
          severity: :warning,
          affected_ids: ids_for(run),
          safe_to_auto_repair: run.may_skip?,
          recommended_repair_action: "skip_obsolete_run",
          evidence: run_evidence(run).merge(
            step_state: step.state,
            step_finished_at: step.finished_at&.iso8601
          ),
          explanation: "Run ##{run.id} is #{run.state} on terminal Step ##{step.id}; it is obsolete and should not be re-enqueued."
        )
      end
    end

    def classify_epic_workflow_conflicts
      EpicWorkflowLock.conflicting_active_workflows(workflows).map do |conflict|
        workflow = conflict.fetch(:workflow)
        keeper = conflict.fetch(:keeper)
        issue(
          kind: :epic_workflow_conflict,
          severity: workflow.epic_wide? ? :critical : :error,
          affected_ids: ids_for(workflow).merge(
            job_ids: [ workflow.job_id ],
            workflow_ids: [ workflow.id, keeper.id ].uniq,
            epic_ids: [ workflow.job&.epic_id ].compact
          ),
          safe_to_auto_repair: workflow.may_cancel?,
          recommended_repair_action: "cancel_epic_workflow_conflict",
          evidence: workflow_evidence(workflow).merge(
            epic_id: workflow.job&.epic_id,
            conflicting_workflow_id: workflow.id,
            conflicting_trigger_kind: workflow.trigger_kind,
            keeper_workflow_id: keeper.id,
            keeper_trigger_kind: keeper.trigger_kind,
            reason: conflict.fetch(:reason)
          ),
          explanation: "Workflow ##{workflow.id} conflicts with active Epic-wide Workflow ##{keeper.id}; only one workflow may mutate or run jobs for the Epic at a time."
        )
      end
    end

    def classify_paused_queues
      return [] unless solid_queue[:available]

      paused_queue_names = solid_queue[:pauses].map { |pause| pause[:queue_name] }.compact.uniq
      return [] if paused_queue_names.empty?

      affected_runs = runs.select(&:queued?).reject { |run| run.job&.closed? }.select do |run|
        sq = solid_queue_for_run(run)
        paused_queue_names.include?(sq&.dig(:queue_name)) || sq.nil? && paused_queue_names.include?("runs")
      end
      return [] if affected_runs.empty?

      [
        issue(
          kind: :runs_paused,
          severity: :info,
          affected_ids: {
            run_ids: affected_runs.map(&:id),
            workflow_ids: affected_runs.filter_map(&:workflow_id),
            job_ids: affected_runs.map(&:job_id)
          },
          safe_to_auto_repair: false,
          recommended_repair_action: "operator_resume_queue",
          check_after: now + RESOURCE_CONGESTION_CHECK_AFTER,
          evidence: { paused_queues: paused_queue_names },
          explanation: "Queued Runs are blocked because their SolidQueue queue is paused."
        )
      ]
    end

    def classify_running_runs
      runs.select(&:running?).filter_map do |run|
        next if run.job&.closed?
        next if run.step&.terminal?
        next unless older_than?(run.started_at, ORPHAN_RUN_GRACE_PERIOD)

        sq = solid_queue_for_run(run)
        live_process = running_spawned_process_for(run)
        heartbeat_stale = run_stale?(run)
        last_activity_at = run.last_heartbeat_at || run.started_at
        detached = detached_running_run?(sq, live_process)
        detached_ready = detached && older_than?(last_activity_at, DETACHED_WORKER_EVIDENCE_GRACE)
        next if !detached && (fresh_activity?(run.last_heartbeat_at) || live_process)

        issue(
          kind: :running_run_without_live_worker_evidence,
          severity: heartbeat_stale || detached_ready ? :critical : :warning,
          affected_ids: ids_for(run).merge(solid_queue_job_ids: [ sq&.dig(:id) ], spawned_process_ids: [ live_process&.id ]),
          safe_to_auto_repair: (heartbeat_stale || detached_ready) && run.may_fail?,
          recommended_repair_action: heartbeat_stale || detached_ready ? "fail_run_as_worker_died" : "capture_diagnostics",
          check_after: check_after_for_running_run(
            heartbeat_stale: heartbeat_stale,
            detached_ready: detached_ready,
            detached: detached,
            last_activity_at: last_activity_at
          ),
          evidence: run_evidence(run).merge(
            solid_queue: sq,
            detached_worker_evidence: detached,
            detached_worker_evidence_grace_seconds: DETACHED_WORKER_EVIDENCE_GRACE.to_i,
            last_heartbeat_age_seconds: seconds_since(last_activity_at),
            live_spawned_process: live_process&.id
          ),
          explanation: "Run ##{run.id} is running without enough evidence of a live worker continuing it."
        )
      end
    end

    def classify_active_steps_with_terminal_runs
      steps.select { |step| step.running? || step.queued? }.filter_map do |step|
        next unless step.workflow&.running?

        step_runs = runs_for_step_reconciliation(step)
        next if step_runs.empty?
        next if step_runs.any? { |run| run.queued? || run.running? }
        next unless step_runs.all?(&:terminal?)

        projection = Steps::StateProjection.for(step, runs: step_runs)
        terminal_run = projection.latest_terminal_run
        next unless terminal_run

        issue(
          kind: :running_step_with_terminal_runs,
          severity: :error,
          affected_ids: ids_for(step).merge(run_ids: step_runs.map(&:id)),
          safe_to_auto_repair: true,
          recommended_repair_action: "reconcile_step_from_terminal_run",
          evidence: workflow_evidence(step.workflow).merge(
            step_id: step.id,
            step_kind: step.kind,
            step_state: step.state,
            terminal_run_id: terminal_run.id,
            terminal_run_state: terminal_run.state,
            terminal_run_finished_at: terminal_run.finished_at&.iso8601
          ),
          explanation: "Step ##{step.id} is #{step.state} but all of its Runs are terminal, so no worker can advance it."
        )
      end
    end

    def classify_queued_steps_without_runs
      steps.select(&:queued?).filter_map do |step|
        workflow = step.workflow
        next unless workflow&.running?
        next unless older_than?(step.created_at, ORPHAN_RUN_GRACE_PERIOD)
        next if step.runs.exists?

        previous = step.previous_step
        next unless previous&.succeeded?

        issue(
          kind: :queued_step_without_run,
          severity: :error,
          affected_ids: ids_for(step),
          safe_to_auto_repair: true,
          recommended_repair_action: "resume_queued_step",
          evidence: workflow_evidence(workflow).merge(
            step_id: step.id,
            step_kind: step.kind,
            step_position: step.position,
            previous_step_id: previous.id,
            previous_step_kind: previous.kind,
            previous_step_state: previous.state,
            age_seconds: seconds_since(step.created_at)
          ),
          explanation: "Step ##{step.id} is queued behind succeeded Step ##{previous.id}, but no Run was created for it."
        )
      end
    end

    def classify_terminal_workflows_with_active_descendants
      workflows.select(&:terminal?).filter_map do |workflow|
        active_step_ids = workflow.projected_active_step_ids
        active_run_ids = workflow.runs.active.pluck(:id)
        next if active_step_ids.empty? && active_run_ids.empty?

        issue(
          kind: :cleanup_blocked_by_active_descendants,
          severity: :warning,
          affected_ids: ids_for(workflow).merge(step_ids: active_step_ids, run_ids: active_run_ids),
          safe_to_auto_repair: true,
          recommended_repair_action: "cancel_terminal_workflow_active_descendants",
          evidence: workflow_evidence(workflow).merge(
            active_step_ids: active_step_ids,
            active_run_ids: active_run_ids
          ),
          explanation: "Workflow ##{workflow.id} is terminal but still has queued/running descendants; cancel the stale descendants so the terminal workflow is internally consistent."
        )
      end
    end

    def classify_workflows
      workflows.filter_map do |workflow|
        if workflow.queued? && older_than?(workflow.created_at, ORPHAN_RUN_GRACE_PERIOD) && queued_without_first_run?(workflow)
          if landing_start_blocked_workflow?(workflow)
            reason = start_block_reason(workflow)
            check_after = start_block_next_check_at(workflow)
            wait_for_retry = check_after.present? && check_after.future?
            main_repair_job = eligible_main_repair_job_for_blocked_landing(workflow)
            repair_action = if main_repair_job
              "release_landing_slot_for_main_repair"
            elsif wait_for_retry
              "wait_for_landing_start_block_to_clear"
            else
              "start_workflow"
            end
            next issue(
              kind: :landing_start_blocked,
              severity: wait_for_retry && !main_repair_job ? :info : :warning,
              affected_ids: ids_for(workflow),
              safe_to_auto_repair: main_repair_job.present? || !wait_for_retry,
              recommended_repair_action: repair_action,
              check_after: main_repair_job ? nil : check_after,
              evidence: workflow_evidence(workflow).merge(
                first_step_id: workflow.first_step&.id,
                start_blocked_reason: reason,
                start_blocked_details: start_block_details(workflow),
                landing_failure_reason: workflow.failure_reason.presence || workflow.artifact("failure_reason"),
                main_repair_job_id: main_repair_job&.id,
                main_repair_job_slug: main_repair_job&.slug,
                landing_queue_entry: landing_queue_evidence(workflow.job)
              ),
              explanation: "Landing Workflow ##{workflow.id} is queued with no first Run because start is intentionally blocked: #{reason}."
            )
          end

          if stale_dependency_start_block?(workflow)
            next issue(
              kind: :stale_dependency_start_block,
              severity: :error,
              affected_ids: ids_for(workflow),
              safe_to_auto_repair: workflow.job.open?,
              recommended_repair_action: "clear_stale_start_block_and_start_workflow",
              evidence: workflow_evidence(workflow).merge(
                first_step_id: workflow.first_step&.id,
                start_blocked_reason: start_block_reason(workflow),
                execution_dependencies_satisfied: workflow.job.dependencies_satisfied_for_execution?,
                unsatisfied_dependencies: workflow.job.unsatisfied_dependencies.map(&:id)
              ),
              explanation: "Workflow ##{workflow.id} has a stale dependency start block, but current dependencies are ready for execution."
            )
          end

          issue(
            kind: :queued_workflow_without_first_run,
            severity: start_blocked?(workflow) ? :info : :error,
            affected_ids: ids_for(workflow),
            safe_to_auto_repair: workflow.job.open? && !start_blocked?(workflow),
            recommended_repair_action: start_blocked?(workflow) ? "wait_for_start_block_to_clear" : "start_workflow",
            check_after: start_block_next_check_at(workflow),
            evidence: workflow_evidence(workflow).merge(first_step_id: workflow.first_step&.id),
            explanation: "Workflow ##{workflow.id} is queued and its first Step has no Run."
          )
        elsif workflow.running? && older_than?(workflow.started_at, ORPHAN_RUN_GRACE_PERIOD) && !workflow_has_active_descendants?(workflow)
          issue(
            kind: :running_workflow_without_active_descendants,
            severity: :error,
            affected_ids: ids_for(workflow),
            safe_to_auto_repair: true,
            recommended_repair_action: "finish_workflow_from_terminal_descendants",
            evidence: workflow_evidence(workflow).merge(step_states: workflow.steps.pluck(:id, :kind, :state)),
            explanation: "Workflow ##{workflow.id} is running but has no queued or running Steps/Runs."
          )
        elsif workflow.running? && (failed_step = orphaned_failed_step(workflow))
          issue(
            kind: :running_workflow_with_failed_step,
            severity: :error,
            affected_ids: ids_for(workflow).merge(step_ids: [ failed_step.id ], run_ids: failed_step.runs.where(state: "failed").pluck(:id)),
            safe_to_auto_repair: true,
            recommended_repair_action: "fail_workflow_from_failed_step",
            evidence: workflow_evidence(workflow).merge(
              failed_step_id: failed_step.id,
              failed_step_kind: failed_step.kind,
              failed_step_finished_at: failed_step.finished_at&.iso8601,
              step_states: workflow.steps.pluck(:id, :kind, :state)
            ),
            explanation: "Workflow ##{workflow.id} is still running even though Step ##{failed_step.id} has failed."
          )
        end
      end
    end

    def classify_stale_auto_retry_workflows
      workflows.filter_map do |workflow|
        attempt = stale_auto_retry_attempt_for(workflow)
        source = attempt&.workflow
        next unless source

        issue(
          kind: :stale_auto_retry_workflow,
          severity: :warning,
          affected_ids: ids_for(workflow).merge(job_ids: [ workflow.job_id ]),
          safe_to_auto_repair: true,
          recommended_repair_action: "cancel_stale_auto_retry_workflow",
          evidence: workflow_evidence(workflow).merge(
            auto_retry_attempt_id: attempt.id,
            source_workflow_id: source.id,
            source_workflow_state: source.state,
            source_branch_divergence_recovery: source.artifact("branch_divergence_recovery"),
            job_state: workflow.job.state
          ),
          explanation: "Workflow ##{workflow.id} is an auto-retry for Workflow ##{source.id}, but that source failure was already superseded."
        )
      end
    end

    def classify_terminal_work_units_with_active_locks
      work_units.select(&:terminal?).filter_map do |unit|
        active_locks = unit.work_unit_locks.select(&:active?)
        next if active_locks.empty?

        issue(
          kind: :terminal_work_unit_active_locks,
          severity: :error,
          affected_ids: ids_for(unit),
          safe_to_auto_repair: true,
          recommended_repair_action: "release_terminal_work_unit_locks",
          evidence: {
            work_unit_id: unit.id,
            work_unit_state: unit.state,
            workflow_id: unit.workflow_id,
            active_lock_ids: active_locks.map(&:id),
            active_lock_keys: active_locks.map(&:lock_key)
          },
          explanation: "Terminal WorkUnit ##{unit.id} still owns active locks; terminal units must release locks so future work can proceed."
        )
      end
    end

    def classify_waiting_work_intents_ready_for_recheck
      work_intents.select(&:waiting?).filter_map do |intent|
        next unless intent_gates_pass?(intent)

        issue(
          kind: :waiting_work_intent_ready_for_recheck,
          severity: :warning,
          affected_ids: ids_for(intent),
          safe_to_auto_repair: true,
          recommended_repair_action: "recheck_waiting_work_intent",
          evidence: {
            work_intent_id: intent.id,
            work_intent_kind: intent.kind,
            work_intent_state: intent.state,
            wait_reason: intent.wait_reason,
            wait_until: intent.wait_until&.iso8601,
            wait_details: intent.wait_details
          },
          explanation: "WorkIntent ##{intent.id} is waiting for #{intent.wait_reason}, but its current gates pass and the wait can be cleared."
        )
      end
    end

    def classify_requested_work_intents_without_active_units
      return [] unless work_intent_id.present?

      work_intents.select(&:requested?).filter_map do |intent|
        next unless intent.definition.generic_intent_start_allowed?

        relaunchability = work_intent_relaunchability(intent)
        next unless relaunchability.relaunchable?
        next unless intent_gates_pass?(intent)

        active_unit_ids = intent.work_units
          .select { |unit| unit.state.in?(WorkIntents::TerminalUnitSync::ACTIVE_UNIT_STATES) }
          .map(&:id)
        next if active_unit_ids.any?

        issue(
          kind: :requested_work_intent_without_active_unit,
          severity: :warning,
          affected_ids: ids_for(intent),
          safe_to_auto_repair: true,
          recommended_repair_action: "launch_requested_work_intent",
          evidence: {
            work_intent_id: intent.id,
            work_intent_kind: intent.kind,
            work_intent_state: intent.state,
            scope_type: intent.scope_type,
            scope_id: intent.scope_id,
            representative_job_id: relaunchability.representative_job_id,
            member_job_ids: relaunchability.member_job_ids,
            active_work_unit_ids: active_unit_ids,
            terminal_work_unit_ids: intent.work_units.select(&:terminal?).map(&:id)
          },
          explanation: "WorkIntent ##{intent.id} is requested and ready, but has no active WorkUnit."
        )
      end
    end

    def classify_dispatcher_owned_work_intents_without_active_units
      return [] unless work_intent_id.present?

      work_intents.select(&:requested?).filter_map do |intent|
        next if intent.definition.generic_intent_start_allowed?

        relaunchability = work_intent_relaunchability(intent)
        next unless relaunchability.relaunchable?
        next unless intent_gates_pass?(intent)

        active_unit_ids = intent.work_units
          .select { |unit| unit.state.in?(WorkIntents::TerminalUnitSync::ACTIVE_UNIT_STATES) }
          .map(&:id)
        next if active_unit_ids.any?

        issue(
          kind: :dispatcher_owned_work_intent_without_active_unit,
          severity: :warning,
          affected_ids: ids_for(intent),
          safe_to_auto_repair: true,
          recommended_repair_action: "wake_dispatcher_for_requested_work_intent",
          evidence: {
            work_intent_id: intent.id,
            work_intent_kind: intent.kind,
            work_intent_state: intent.state,
            dispatcher: dispatcher_for_intent(intent),
            scope_type: intent.scope_type,
            scope_id: intent.scope_id,
            representative_job_id: relaunchability.representative_job_id,
            member_job_ids: relaunchability.member_job_ids,
            active_work_unit_ids: active_unit_ids,
            terminal_work_unit_ids: intent.work_units.select(&:terminal?).map(&:id)
          },
          explanation: "WorkIntent ##{intent.id} is requested and ready, but its #{intent.kind} definition must be relaunched by its domain dispatcher."
        )
      end
    end

    WorkIntentRelaunchability = Data.define(:representative_job_id, :member_job_ids) do
      def relaunchable? = representative_job_id.present?
    end

    def work_intent_relaunchability(intent)
      if intent.scope_type == "job" && intent.scope_id.present?
        return WorkIntentRelaunchability.new(representative_job_id: intent.scope_id, member_job_ids: [ intent.scope_id ])
      end

      latest_unit = intent.work_units.max_by { |unit| [ unit.created_at || Time.zone.at(0), unit.id || 0 ] }
      workflow = latest_unit&.workflow
      members = latest_unit&.work_unit_members&.sort_by(&:id)&.map(&:job_id)&.compact || []
      representative_job_id = workflow&.job_id || members.last
      WorkIntentRelaunchability.new(representative_job_id: representative_job_id, member_job_ids: members)
    end

    def intent_gates_pass?(intent)
      intent.definition.intent_gates.all? { |gate| gate.call(intent).pass? }
    rescue WorkDefinitions::UnknownKind
      false
    end

    def dispatcher_for_intent(intent)
      intent.definition.landing_lock? ? "landing_queue" : "unknown"
    rescue WorkDefinitions::UnknownKind
      "unknown"
    end

    def classify_active_work_units_without_workflows
      work_units.select(&:active?).filter_map do |unit|
        next if unit.workflow_id.present?

        issue(
          kind: :active_work_unit_without_workflow,
          severity: :error,
          affected_ids: ids_for(unit),
          safe_to_auto_repair: true,
          recommended_repair_action: "cancel_active_work_unit_without_workflow",
          evidence: {
            work_unit_id: unit.id,
            work_unit_state: unit.state,
            work_intent_id: unit.work_intent_id,
            active_lock_ids: unit.work_unit_locks.select(&:active?).map(&:id),
            active_lock_keys: unit.work_unit_locks.select(&:active?).map(&:lock_key)
          },
          explanation: "Active WorkUnit ##{unit.id} has no Workflow, so it cannot execute but may still own locks."
        )
      end
    end

    def classify_succeeded_work_units_with_unsatisfied_intents
      work_units.select(&:succeeded?).filter_map do |unit|
        intent = unit.work_intent
        next unless intent&.requested? || intent&.waiting?

        active_sibling_ids = active_work_unit_ids_for_intent(intent, excluding: unit)
        next if active_sibling_ids.any?

        issue(
          kind: :succeeded_work_unit_unsatisfied_intent,
          severity: :error,
          affected_ids: ids_for(unit).merge(work_intent_ids: [ intent.id ]),
          safe_to_auto_repair: true,
          recommended_repair_action: "satisfy_work_intent_from_succeeded_work_unit",
          evidence: {
            work_unit_id: unit.id,
            work_unit_state: unit.state,
            workflow_id: unit.workflow_id,
            work_intent_id: intent.id,
            work_intent_kind: intent.kind,
            work_intent_state: intent.state,
            work_intent_wait_reason: intent.wait_reason
          },
          explanation: "Succeeded WorkUnit ##{unit.id} completed WorkIntent ##{intent.id}, but the intent is still #{intent.state}."
        )
      end
    end

    def classify_active_child_work_units_with_terminal_parents
      active_children_by_parent = work_units
        .select(&:active?)
        .select { |unit| unit.parent_work_unit&.terminal? }
        .group_by(&:parent_work_unit)

      active_children_by_parent.map do |parent, children|
        issue(
          kind: :terminal_work_unit_active_children,
          severity: :error,
          affected_ids: ids_for(parent).merge(work_unit_ids: [ parent.id, *children.map(&:id) ]),
          safe_to_auto_repair: true,
          recommended_repair_action: "cancel_terminal_work_unit_active_children",
          evidence: {
            parent_work_unit_id: parent.id,
            parent_work_unit_state: parent.state,
            child_work_unit_ids: children.map(&:id),
            child_work_unit_states: children.map { |child| [ child.id, child.kind, child.state, child.workflow_id ] }
          },
          explanation: "Terminal WorkUnit ##{parent.id} still has active child WorkUnits; terminal parents cannot keep descendant runtime work alive."
        )
      end
    end

    def active_work_unit_ids_for_intent(intent, excluding:)
      intent.work_units
        .where(state: WorkIntents::TerminalUnitSync::ACTIVE_UNIT_STATES)
        .where.not(id: excluding.id)
        .pluck(:id)
    end

    def stale_auto_retry_attempt_for(workflow)
      return nil unless retry_workflow_attempt?(workflow) && workflow.queued?

      @stale_auto_retry_attempts ||= {}
      return @stale_auto_retry_attempts[workflow.id] if @stale_auto_retry_attempts.key?(workflow.id)

      attempt_id = workflow.artifact("auto_retry_attempt_id")
      attempt = AutoRetryAttempt.includes(:workflow).find_by(id: attempt_id) if attempt_id.present?
      source = attempt&.workflow
      @stale_auto_retry_attempts[workflow.id] =
        if source_auto_retry_superseded?(workflow.job, source)
          attempt
        end
    end

    def source_auto_retry_superseded?(job, source)
      return false unless job && source

      source.succeeded? ||
        newer_successful_workflow?(job, source) ||
        branch_divergence_recovered_by_current_pr_branch?(source)
    end

    # A pending AutoRetryAttempt already owns recovery for this workflow (it
    # will schedule a fresh Run via AutoRetryJob once it fires), so a queued
    # Run that lost its claim in the meantime should not also be repaired by
    # reenqueue_run — racing the two paths is what turned a single grader
    # failure into a run storm (JOB-2970 / WF-18780).
    def pending_auto_retry_attempt?(workflow)
      workflow.present? && workflow.auto_retry_attempts.pending.exists?
    end

    # queued_run_without_queue_claim (the Run never had a queue claim at all)
    # is the one case desired behavior still allows: the Run has not executed
    # yet, so it must run once to progress the retry-until loop
    # deterministically. Once a claim/attempt already happened (dead resume
    # queue, failed SolidQueue execution) and the required grader conclusion
    # is already cached failed for the exact commit + fingerprint this
    # workflow is at, re-enqueueing would just replay a known outcome.
    def grader_collect_cached_failure?(run)
      run.step&.kind == "grader_collect" && GraderConclusionCache.failed_for_workflow?(run.workflow)
    end

    def grader_collect_cached_failure_issue(run, workflow, sq, solid_queue_state)
      {
        kind: :queued_grader_collect_cached_failure,
        severity: :warning,
        affected_ids: ids_for(run).merge(solid_queue_job_ids: [ sq[:id] ]),
        safe_to_auto_repair: true,
        recommended_repair_action: "mark_cached_grader_collect_failed",
        evidence: run_evidence(run).merge(
          solid_queue: sq,
          solid_queue_state: solid_queue_state,
          grade_plan_head_sha: workflow.artifact(GraderConclusionCache::ARTIFACT_HEAD_SHA_KEY),
          grade_plan_fingerprint: workflow.artifact(GraderConclusionCache::ARTIFACT_FINGERPRINT_KEY)
        ),
        explanation: "Run ##{run.id} is a queued grader_collect Run that already lost a queue claim, but the required grader conclusion is already cached failed for the current commit; mark the collect failed so the retry-until loop can exhaust or append the next repair iteration without replaying known work."
      }
    end

    def classify_job_workflow_drift
      jobs.filter_map do |job|
        active = active_runtime_workflows_for_job(job)
        next if active.empty? || job.closed? || %w[queued running landing coding approved].include?(job.state)
        next if job.failed? && job.latest_workflow&.queued? && ReconcileJobStatesJob::Plan.for(job)
        next if job.failed? && active_repair_workflows?(active)
        next if active.all? { |workflow| expected_start_blocked_workflow?(job, workflow) }

        issue(
          kind: :job_workflow_state_drift,
          severity: :warning,
          affected_ids: { job_ids: [ job.id ], workflow_ids: active.map(&:id) },
          safe_to_auto_repair: false,
          recommended_repair_action: "operator_review_state_transition",
          evidence: { job_state: job.state, active_workflow_states: active.map { |workflow| [ workflow.id, workflow.state ] } },
          explanation: "Job ##{job.id} is #{job.state} while it still has active Workflows."
        )
      end
    end

    def classify_failed_jobs_with_active_repair_work
      jobs.filter_map do |job|
        next unless job.failed?

        active = active_runtime_workflows_for_job(job)
        repair_workflows = active.select { |workflow| repair_workflow?(workflow) }
        next if repair_workflows.empty?

        units = active_work_units_for_job(job)
        issue(
          kind: :failed_job_active_repair_work,
          severity: :info,
          affected_ids: ids_for(job).merge(
            workflow_ids: repair_workflows.map(&:id),
            work_unit_ids: units.select { |unit| repair_workflow?(unit.workflow) || repair_work_unit?(unit) }.map(&:id)
          ),
          safe_to_auto_repair: false,
          recommended_repair_action: "monitor_active_repair_work",
          evidence: {
            job_state: job.state,
            active_repair_workflows: repair_workflows.map { |workflow| [ workflow.id, workflow.trigger_kind, workflow.state ] },
            active_work_units: units.map { |unit| [ unit.id, unit.kind, unit.state, unit.workflow_id ] }
          },
          explanation: "Job ##{job.id} is failed, but active repair work is already running or queued."
        )
      end
    end

    def active_runtime_workflows_for_job(job)
      @active_runtime_workflows_for_job ||= {}
      @active_runtime_workflows_for_job[job.id] ||= job.active_runtime_workflows
    end

    def active_work_units_for_job(job)
      @active_work_units_for_job ||= {}
      @active_work_units_for_job[job.id] ||= WorkUnits::Ownership.active_units_for_job(job)
    end

    def active_repair_workflows?(workflows)
      workflows.any? { |workflow| repair_workflow?(workflow) }
    end

    def repair_workflow?(workflow)
      return false unless workflow&.trigger_kind

      WorkDefinitions.for(workflow.trigger_kind).active_repair_work?
    rescue WorkDefinitions::UnknownKind
      false
    end

    def repair_work_unit?(unit)
      return false unless unit&.kind

      WorkDefinitions.for(unit.kind).active_repair_work?
    rescue WorkDefinitions::UnknownKind
      false
    end

    def retry_workflow_attempt?(workflow)
      return false unless workflow

      definition = WorkDefinitions.for(workflow.work_unit&.kind || workflow.trigger_kind)
      definition.retry_workflow_attempt?
    rescue WorkDefinitions::UnknownKind
      false
    end

    def expected_start_blocked_workflow?(job, workflow)
      return false unless workflow.queued?
      return false unless workflow.first_step&.runs&.none?

      if WorkUnits::StartBlock.for(workflow).blocked_for?(StepDispatcher::MAIN_HEALTH_BLOCK_REASON)
        # Follow-up workflows on implemented Jobs are allowed to sit queued
        # while main health is red. `classify_start_blocks` reports the real
        # blocker; surfacing this as generic state drift sends operators down
        # the wrong recovery path.
        return job.implemented?
      end

      false
    end

    def classify_closed_jobs_with_active_workflows
      jobs.select(&:closed?).flat_map do |job|
        workflows
          .select { |workflow| workflow.job_id == job.id && %w[queued running].include?(workflow.state) }
          .map do |workflow|
            issue(
              kind: :closed_job_active_workflow,
              severity: :critical,
              affected_ids: ids_for(workflow).merge(job_ids: [ job.id ]),
              safe_to_auto_repair: workflow.may_cancel?,
              recommended_repair_action: "cancel_workflow_for_closed_job",
              evidence: workflow_evidence(workflow).merge(
                job_finished_at: job.finished_at&.iso8601,
                job_closure_reason: job.closure_reason,
                active_step_states: workflow.steps.where(state: %w[queued running]).pluck(:id, :kind, :state)
              ),
              explanation: "Closed Job ##{job.id} still has active Workflow ##{workflow.id}; that work should be cancelled."
            )
          end
      end
    end

    def classify_superseded_active_workflows
      jobs.reject(&:closed?).flat_map do |job|
        active = workflows
          .select { |workflow| workflow.job_id == job.id && %w[queued running].include?(workflow.state) }
          .sort_by { |workflow| [ workflow.created_at || Time.zone.at(0), workflow.id || 0 ] }
        next [] if active.size < 2

        keeper = active.last
        active[0...-1].map do |workflow|
          issue(
            kind: :superseded_active_workflow,
            severity: :error,
            affected_ids: ids_for(workflow).merge(job_ids: [ job.id ], workflow_ids: [ workflow.id, keeper.id ]),
            safe_to_auto_repair: workflow.may_cancel?,
            recommended_repair_action: "cancel_superseded_active_workflow",
            evidence: workflow_evidence(workflow).merge(
              keeper_workflow_id: keeper.id,
              keeper_trigger_kind: keeper.trigger_kind,
              keeper_workflow_state: keeper.state,
              active_workflow_states: active.map { |candidate| [ candidate.id, candidate.trigger_kind, candidate.state ] }
            ),
            explanation: "Job ##{job.id} has multiple active Workflows; older Workflow ##{workflow.id} is superseded by newer active Workflow ##{keeper.id}."
          )
        end
      end
    end

    def newer_successful_workflow?(job, source)
      cutoff = source.finished_at || source.created_at
      return false unless cutoff

      job.workflows
         .where(state: "succeeded")
         .where("created_at > ? OR (created_at = ? AND id > ?)", cutoff, cutoff, source.id)
         .exists?
    end

    def classify_unambiguous_job_state_drift
      jobs.filter_map do |job|
        next unless ReconcileJobStatesJob::RECONCILABLE_STATES.include?(job.state)
        next if job.latest_workflow&.terminal? && active_runtime_work_for_job?(job)

        plan = ReconcileJobStatesJob::Plan.for(job)
        next unless plan

        issue(
          kind: :unambiguous_job_state_drift,
          severity: :warning,
          affected_ids: ids_for(job).merge(workflow_ids: [ job.latest_workflow&.id ]),
          safe_to_auto_repair: true,
          recommended_repair_action: "reconcile_job_state",
          evidence: {
            job_state: plan.from_state,
            target_state: plan.target_state,
            latest_workflow_id: job.latest_workflow&.id,
            latest_workflow_state: job.latest_workflow&.state,
            reason: plan.reason
          },
          explanation: "Job ##{job.id} has unambiguous Workflow-derived state drift."
        )
      end
    end

    def classify_jobs_without_active_workflows
      jobs.filter_map do |job|
        next unless job.state.in?(%w[running landing])
        active_workflows = workflows.select { |workflow| workflow.job_id == job.id && %w[queued running].include?(workflow.state) }
        next if active_workflows.any?
        next if active_runtime_work_for_job?(job)
        next if job.landing? && active_landing_work_for_job?(job)

        if job.landing?
          next unless landing_slot_orphaned?(job)

          next issue(
            kind: :landing_job_without_active_workflow,
            severity: :critical,
            affected_ids: ids_for(job).merge(workflow_ids: [ job.latest_workflow&.id ]),
            safe_to_auto_repair: job.may_defer_landing?,
            recommended_repair_action: "defer_orphaned_landing_job",
            evidence: {
              job_state: job.state,
              latest_workflow_id: job.latest_workflow&.id,
              latest_workflow_state: job.latest_workflow&.state,
              latest_workflow_trigger_kind: job.latest_workflow&.trigger_kind,
              updated_at: job.updated_at&.iso8601
            },
            explanation: "Job ##{job.id} is occupying the landing slot, but no active Workflow owns landing work for it."
          )
        end

        next unless older_than?(job.updated_at, RESOURCE_CONGESTION_CHECK_AFTER)

        issue(
          kind: :job_without_active_workflow,
          severity: :critical,
          affected_ids: ids_for(job).merge(workflow_ids: [ job.latest_workflow&.id ]),
          safe_to_auto_repair: false,
          recommended_repair_action: "operator_review_state_transition",
          evidence: {
            job_state: job.state,
            latest_workflow_id: job.latest_workflow&.id,
            latest_workflow_state: job.latest_workflow&.state,
            updated_at: job.updated_at&.iso8601
          },
          explanation: "Job ##{job.id} is #{job.state}, but has no active Workflow."
        )
      end
    end

    def classify_queued_jobs_cancelled_by_epic_workflow_conflict
      jobs.filter_map do |job|
        next unless job.queued?
        next if active_runtime_work_for_job?(job)

        latest = job.latest_workflow
        next unless latest&.cancelled?
        next unless cancelled_workflow_reason(latest) == EpicWorkflowLock::BLOCK_REASON
        next if active_epic_wide_workflow_for_job?(job)
        next unless job.dependencies_satisfied_for_execution?

        issue(
          kind: :queued_job_after_epic_workflow_conflict,
          severity: :warning,
          affected_ids: ids_for(job).merge(workflow_ids: [ latest.id ]),
          safe_to_auto_repair: true,
          recommended_repair_action: "retry_job_after_epic_workflow_conflict",
          evidence: {
            job_state: job.state,
            latest_workflow_id: latest.id,
            latest_workflow_state: latest.state,
            latest_workflow_trigger_kind: latest.trigger_kind,
            cancelled_reason: cancelled_workflow_reason(latest),
            cancelled_details: cancelled_workflow_details(latest)
          },
          explanation: "Job ##{job.id} is queued with no active Workflow after its latest Workflow was cancelled for an Epic-wide workflow lock."
        )
      end
    end

    def classify_queued_jobs_cancelled_without_active_workflow
      jobs.filter_map do |job|
        next unless job.queued?
        next if active_runtime_work_for_job?(job)

        latest = job.latest_workflow
        next unless recoverable_cancelled_workflow_for_queued_job?(job, latest)
        next if ReconcileJobStatesJob::Plan.for(job)

        issue(
          kind: :queued_job_after_cancelled_workflow,
          severity: :warning,
          affected_ids: ids_for(job).merge(workflow_ids: [ latest.id ]),
          safe_to_auto_repair: true,
          recommended_repair_action: "retry_job_after_cancelled_workflow",
          evidence: {
            job_state: job.state,
            latest_workflow_id: latest.id,
            latest_workflow_state: latest.state,
            latest_workflow_trigger_kind: latest.trigger_kind,
            cancelled_reason: cancelled_workflow_reason(latest),
            retry_cancelled_reason: latest.artifact("retry_cancelled_reason"),
            start_cancelled_reason: latest.artifact("start_cancelled_reason"),
            main_broken: latest.artifact("main_broken")
          },
          explanation: "Job ##{job.id} is queued with no active Workflow after its latest Workflow was cancelled without a terminal or deliberate cancellation marker."
        )
      end
    end

    def classify_approved_jobs_with_landing_start_blockers
      jobs.filter_map do |job|
        next unless job.approved?
        next unless LandingQueueReentry.landing_start_blocker?(job.landing_failure_reason)
        next if active_runtime_work_for_job?(job)

        issue(
          kind: :approved_job_landing_start_blocked,
          severity: :warning,
          affected_ids: ids_for(job).merge(workflow_ids: [ job.latest_workflow&.id ]),
          safe_to_auto_repair: true,
          recommended_repair_action: "clear_landing_start_blocker_and_wake_queue",
          evidence: {
            job_state: job.state,
            epic_id: job.epic_id,
            repository_id: job.repository_id,
            landing_failure_reason: job.landing_failure_reason,
            latest_workflow_id: job.latest_workflow&.id,
            latest_workflow_state: job.latest_workflow&.state,
            active_repository_landing_job_id: Job.landing.where(repository_id: job.repository_id).where.not(id: job.id).order(:id).pick(:id)
          },
          explanation: "Approved Job ##{job.id} has a transient landing-start blocker; it should re-enter the landing queue instead of requiring an immediate manual dispatch."
        )
      end
    end

    def classify_approved_jobs_missing_pr
      jobs.filter_map do |job|
        next unless job.approved?
        next if job.pr_number.present? || job.external_pr_number.present? || job.fork_review_pr_number.present?
        next if job.infrastructure_job?
        next if job.main_branch_repair?
        next if active_runtime_work_for_job?(job)

        issue(
          kind: :approved_job_missing_pr,
          severity: :critical,
          affected_ids: ids_for(job).merge(workflow_ids: [ job.latest_workflow&.id ].compact),
          safe_to_auto_repair: job.may_force_fail?,
          recommended_repair_action: "fail_approved_job_missing_pr",
          evidence: {
            job_state: job.state,
            latest_workflow_id: job.latest_workflow&.id,
            latest_workflow_state: job.latest_workflow&.state,
            latest_workflow_trigger_kind: job.latest_workflow&.trigger_kind,
            pr_number: job.pr_number,
            external_pr_number: job.external_pr_number,
            fork_review_pr_number: job.fork_review_pr_number,
            landing_queue: landing_queue_evidence(job)
          },
          explanation: "Approved Job ##{job.id} has no tracked PR, so it cannot land and can block the landing queue."
        )
      end
    end

    def classify_implemented_jobs_missing_pr
      jobs.filter_map do |job|
        next unless job.implemented?
        next if job.pr_number.present? || job.external_pr_number.present? || job.fork_review_pr_number.present?
        next if job.infrastructure_job?
        next if job.main_branch_repair?

        latest_workflow = job.latest_workflow
        next unless latest_workflow
        next unless ReconcileJobStatesJob.new.terminal_workflow?(latest_workflow)
        review_publication_step_kinds = review_publication_step_kinds_for(latest_workflow)
        next if review_publication_step_kinds.empty?
        next unless latest_workflow.steps.where(kind: review_publication_step_kinds).exists?
        next if latest_workflow.steps.where(kind: review_publication_step_kinds, state: "succeeded").exists?
        next if active_runtime_work_for_job?(job)

        issue(
          kind: :implemented_job_missing_pr,
          severity: :critical,
          affected_ids: ids_for(job).merge(workflow_ids: [ latest_workflow.id ]),
          safe_to_auto_repair: job.may_force_fail?,
          recommended_repair_action: "fail_implemented_job_missing_pr",
          evidence: {
            job_state: job.state,
            latest_workflow_id: latest_workflow.id,
            latest_workflow_state: latest_workflow.state,
            latest_workflow_trigger_kind: latest_workflow.trigger_kind,
            review_publication_steps: latest_workflow.steps.where(kind: review_publication_step_kinds).pluck(:id, :kind, :state),
            pr_number: job.pr_number,
            external_pr_number: job.external_pr_number,
            fork_review_pr_number: job.fork_review_pr_number
          },
          explanation: "Job ##{job.id} is implemented, but its PR-producing Workflow did not publish a tracked PR."
        )
      end
    end

    def landing_slot_orphaned?(job)
      !active_landing_work_for_job?(job)
    end

    def landing_start_blocked_workflow?(workflow)
      workflow.job&.landing? &&
        workflow.landing_workflow? &&
        start_block_reason(workflow).present?
    end

    def landing_queue_evidence(job)
      entry = LandingQueueProcessor.entries(Job.where(id: job.id)).find { |candidate| candidate.job_id == job.id }
      return unless entry

      {
        position: entry.position,
        eligible: entry.eligible?,
        blocked_reason: entry.blocked_reason,
        waiting_for_job_ids: entry.waiting_for_jobs.map(&:id),
        blocker_job_ids: entry.blocker_jobs.map(&:id)
      }
    end

    # Internal anchor Jobs that do not require operator review can be stranded
    # open when a lifecycle hook is skipped or raises after their Workflow is
    # already terminal. This is the safety net.
    def classify_completed_infrastructure_jobs
      jobs.filter_map do |job|
        next if job.closed?

        latest_workflow = job.latest_workflow
        closure_reason = completed_internal_job_closure_reason(job, latest_workflow)
        next unless closure_reason
        next unless job.implemented? || ReconcileJobStatesJob.new.terminal_workflow?(latest_workflow)

        issue(
          kind: :completed_infrastructure_job,
          severity: :info,
          affected_ids: ids_for(job).merge(workflow_ids: [ latest_workflow&.id ]),
          safe_to_auto_repair: true,
          recommended_repair_action: "close_completed_infrastructure_job",
          evidence: {
            job_kind: job.kind,
            job_state: job.state,
            latest_workflow_id: latest_workflow&.id,
            latest_workflow_state: latest_workflow&.state,
            closure_reason: closure_reason
          },
          explanation: "#{job.kind.humanize} Job ##{job.id} is complete and can be closed."
        )
      end
    end

    def completed_internal_job_closure_reason(job, latest_workflow)
      return job.kind if job.infrastructure_job?

      return unless job.main_branch_repair?
      return unless latest_workflow&.trigger_kind == "main_branch_repair"
      return unless latest_workflow.succeeded?
      return unless latest_workflow.artifact("preflight_passed")
      return if job.pr_number.present? || job.external_pr_number.present?

      "preflight_passed"
    end

    def classify_start_blocks
      workflows.filter_map do |workflow|
        if workflow.running? && phase_start_block_recheck_due?(workflow)
          reason = start_block_reason(workflow)
          next unless resource_admission_block_reason?(reason)
          details = start_block_details(workflow)

          next issue(
            kind: :resource_admission_start_block,
            severity: :error,
            affected_ids: ids_for(workflow).merge(step_ids: [ details.to_h["phase_step_id"] ].compact),
            safe_to_auto_repair: true,
            recommended_repair_action: "resume_deferred_phase",
            evidence: workflow_evidence(workflow).merge(
              start_blocked_reason: reason,
              start_blocked_next_check_at: start_block_next_check_at(workflow)&.iso8601,
              phase_step_id: details.to_h["phase_step_id"],
              phase_step_kind: details.to_h["phase_step_kind"]
            ),
            explanation: "Workflow ##{workflow.id} is paused at a phase boundary after its resource-admission recheck time elapsed."
          )
        end

        next unless workflow.queued? && start_blocked?(workflow)
        next if landing_start_blocked_workflow?(workflow)

        reason = start_block_reason(workflow)
        dependency_block = dependency_block_reason?(reason)
        admission_block = admission_block_reason?(reason)
        issue(
          kind: start_block_issue_kind(dependency_block: dependency_block, admission_block: admission_block),
          severity: :info,
          affected_ids: ids_for(workflow),
          safe_to_auto_repair: false,
          recommended_repair_action: start_block_repair_action(dependency_block: dependency_block, admission_block: admission_block),
          check_after: start_block_next_check_at(workflow),
          evidence: workflow_evidence(workflow).merge(
            start_blocked_reason: reason,
            unsatisfied_dependencies: workflow.job.unsatisfied_dependencies.map(&:id)
          ),
          explanation: "Workflow ##{workflow.id} is intentionally blocked before start: #{reason}."
        )
      end
    end

    def start_block_issue_kind(dependency_block:, admission_block:)
      return :dependency_stack_start_block if dependency_block
      return :resource_admission_start_block if admission_block

      :main_health_start_block
    end

    def start_block_repair_action(dependency_block:, admission_block:)
      return "wait_for_dependency_or_stack_readiness" if dependency_block
      return "wait_for_resource_admission" if admission_block

      "wait_for_main_health"
    end

    def phase_start_block_recheck_due?(workflow)
      reason = start_block_reason(workflow)
      return false if reason.blank?
      return false unless start_block_details(workflow).to_h["phase_step_id"].present?

      start_blocked_check_due?(workflow)
    end

    def resource_admission_block_reason?(reason)
      WorkflowAdmissionCapacityWakeup.admission_or_resource_reason?(reason)
    end

    def admission_block_reason?(reason)
      reason.to_s.in?([ StepDispatcher::ADMISSION_BLOCK_REASON, "admission_control" ])
    end

    def classify_main_broken_workflows
      workflows.filter_map do |workflow|
        next unless workflow.artifact("main_broken")
        next unless StepDispatcher.main_health_blocking?(workflow)

        issue(
          kind: :main_branch_broken,
          severity: :warning,
          affected_ids: ids_for(workflow),
          safe_to_auto_repair: false,
          recommended_repair_action: "wait_for_main_recovery",
          check_after: now + RESOURCE_CONGESTION_CHECK_AFTER,
          evidence: workflow_evidence(workflow).merge(main_broken: true),
          explanation: "Workflow ##{workflow.id} is blocked from retry because the base branch is marked broken."
        )
      end
    end

    def classify_resource_congestion
      issues = []
      max = AppSetting.max_concurrent_agent_runs
      running_count = Run.running_agent_runs.count
      open_queued_runs = runs.select { |run| run.queued? && !run.job&.closed? }
      if max.positive? && running_count >= max && open_queued_runs.any?
        issues << issue(
          kind: :resource_congestion,
          severity: :info,
          affected_ids: { run_ids: open_queued_runs.map(&:id) },
          safe_to_auto_repair: false,
          recommended_repair_action: "wait_for_agent_capacity",
          check_after: now + RESOURCE_CONGESTION_CHECK_AFTER,
          evidence: { max_concurrent_agent_runs: max, running_agent_runs: running_count },
          explanation: "Queued runs are waiting because the configured agent concurrency limit is saturated."
        )
      end

      if (disk = InstanceVersion.worst_data_root)&.data_root_alert?
        issues << issue(
          kind: :resource_congestion,
          severity: disk.data_root_alert_level == :critical ? :critical : :warning,
          affected_ids: {},
          safe_to_auto_repair: false,
          recommended_repair_action: "free_worker_data_root_space",
          evidence: { data_root: disk.data_root_usage_json },
          explanation: "A worker data root is under disk pressure."
        )
      end
      issues
    end

    def classify_rate_limits
      ProviderCircuitBreaker.open_circuits(now: now, include_logs: false).map do |decision|
        issue(
          kind: :rate_limit,
          severity: decision.usage_limit? ? :error : :warning,
          affected_ids: {},
          safe_to_auto_repair: false,
          recommended_repair_action: decision.usage_limit? ? "operator_update_provider_quota" : "wait_for_provider_recovery",
          retry_after: decision.retry_after || (now + RATE_LIMIT_CHECK_AFTER),
          evidence: decision.as_json,
          explanation: "Provider #{decision.provider} is currently blocked by #{decision.reason}."
        )
      end
    end

    def classify_workspace_availability
      workflows.select { |workflow| workflow.running? || workflow.retry_available? }.filter_map do |workflow|
        next if workflow.job&.closed?
        next if WorkflowWorkspace.remote_live_worker_workspace?(workflow)
        next if workflow.worker_storage_key.present? && !InstanceVersion.worker_queue_live?(Workflow.resume_queue_name(workflow.worker_storage_key))
        next if workflow.worker_storage_key.blank? && workflow.worker_hostname.present? && !InstanceVersion.worker_live?(workflow.worker_hostname)

        path = WorkflowWorkspace.path_for(workflow)
        next if File.directory?(path)
        next unless workflow.live_descendants? || workflow.retry_available?

        issue(
          kind: :workspace_missing,
          severity: :critical,
          affected_ids: ids_for(workflow),
          safe_to_auto_repair: false,
          recommended_repair_action: "start_over_with_fresh_workflow",
          evidence: workflow_evidence(workflow).merge(
            workspace_path: path.to_s,
            worker_hostname: workflow.worker_hostname,
            worker_storage_key: workflow.worker_storage_key
          ),
          explanation: "Workflow ##{workflow.id} needs its workspace, but the directory is not present on the inspected worker."
        )
      end
    end

    def classify_resumable_sessions
      runs.select { |run| run.failed? && run.step&.agentic? }.filter_map do |run|
        next if run.job&.closed?
        next unless latest_workflow_run?(run)
        next unless failed_run_still_controls_step?(run)
        next if step_needs_terminal_run_reconciliation?(run.step)

        retryable_worker_failure = run.agent_outcome == AutoRetryAttempt::WORKER_DIED_CLASSIFICATION ||
          run.run_failure_classification&.classification == AutoRetryAttempt::WORKER_DIED_CLASSIFICATION
        next unless retryable_worker_failure

        if run.provider_session_metadata.present?
          issue(
            kind: :resumable_agent_session_present,
            severity: :info,
            affected_ids: ids_for(run),
            safe_to_auto_repair: true,
            recommended_repair_action: "resume_failed_step",
            evidence: run_evidence(run).merge(session_id: run.provider_session_metadata.session_id),
            explanation: "Run ##{run.id} failed after an agent session was captured and can be resumed."
          )
        else
          issue(
            kind: :resumable_agent_session_missing,
            severity: :warning,
            affected_ids: ids_for(run),
            safe_to_auto_repair: false,
            recommended_repair_action: "retry_as_new_workflow",
            evidence: run_evidence(run).merge(live_session_id: run.live_session_id),
            explanation: "Run ##{run.id} appears retryable, but no resumable agent session is stored."
          )
        end
      end
    end

    def classify_retryable_failures
      runs.select(&:failed?).filter_map do |run|
        next if run.job&.closed?
        next unless latest_workflow_run?(run)
        next unless failed_run_still_controls_step?(run)
        next if step_needs_terminal_run_reconciliation?(run.step)
        next if recoverable_branch_divergence?(run)
        next if branch_divergence_recovered_by_current_pr_branch?(run.workflow)
        next if external_pr_ingest_run?(run)

        classification = run.run_failure_classification
        next if classification.nil?
        next unless classification.retryable || provider_quota_classification?(classification)

        issue(
          kind: :retryable_run_failure,
          severity: :warning,
          affected_ids: ids_for(run),
          safe_to_auto_repair: true,
          recommended_repair_action: "plan_retry",
          retry_after: retry_after_for(run, classification),
          evidence: run_evidence(run).merge(
            classification: classification.classification,
            retryable: classification.retryable,
            confidence: classification.confidence,
            reason: classification.reason,
            step_repair_semantics: step_repair_semantics(run.step)
          ),
          explanation: provider_quota_classification?(classification) ?
            "Run ##{run.id} failed because the provider usage quota is exhausted." :
            "Run ##{run.id} failed with a retryable classification."
        )
      end
    end

    def classify_branch_divergence
      runs.select(&:failed?).filter_map do |run|
        next if run.job&.closed?
        next if step_needs_terminal_run_reconciliation?(run.step)
        next unless branch_diverged_pr_open_run?(run)

        workflow = run.workflow
        job = run.job
        divergence = workflow&.artifact("branch_divergence").presence
        next if workflow&.artifact("branch_divergence_recovery").present?
        next unless divergence_current_pr_head?(job, divergence)

        if workflow == job.latest_workflow && job.failed? && !active_runtime_work_for_job?(job)
          issue(
            kind: :branch_diverged_pr_open,
            severity: :warning,
            affected_ids: ids_for(run),
            safe_to_auto_repair: true,
            recommended_repair_action: "retry_workflow",
            evidence: run_evidence(run).merge(
              classification: run.run_failure_classification&.classification,
              branch_divergence: divergence,
              current_pr_head_sha: current_pr_head_sha(job)
            ),
            explanation: "Run ##{run.id} failed because the PR branch changed; retrying as a new workflow preserves the current PR branch."
          )
        else
          issue(
            kind: :stale_branch_diverged_workflow,
            severity: :info,
            affected_ids: ids_for(run),
            safe_to_auto_repair: true,
            recommended_repair_action: "discard_superseded_branch_output",
            evidence: run_evidence(run).merge(
              classification: run.run_failure_classification&.classification,
              branch_divergence: divergence,
              current_pr_head_sha: current_pr_head_sha(job),
              latest_workflow_id: job.latest_workflow&.id,
              latest_workflow_state: job.latest_workflow&.state
            ),
            explanation: "Workflow ##{workflow.id} has stale branch-diverged output; the current PR branch is already at the protected remote SHA."
          )
        end
      end
    end

    def classify_nonretryable_failures
      runs.select(&:failed?).filter_map do |run|
        next if run.job&.closed?
        next unless latest_workflow_run?(run)
        next if step_needs_terminal_run_reconciliation?(run.step)
        next if recoverable_branch_divergence?(run)
        next if branch_divergence_recovered_by_current_pr_branch?(run.workflow)

        classification = run.run_failure_classification
        next if classification.nil?
        next if provider_quota_classification?(classification)

        nonretryable = classification.retryable == false || NONRETRYABLE_CLASSIFICATIONS.include?(classification.classification)
        next unless nonretryable
        next if stale_publication_divergence?(run, classification)

        issue(
          kind: :nonretryable_semantic_git_failure,
          severity: :error,
          affected_ids: ids_for(run),
          safe_to_auto_repair: false,
          recommended_repair_action: "operator_review_failure",
          evidence: run_evidence(run).merge(
            classification: classification.classification,
            retryable: classification.retryable,
            confidence: classification.confidence,
            reason: classification.reason
          ),
          explanation: "Run ##{run.id} failed with a nonretryable semantic or git classification."
        )
      end
    end

    def stale_publication_divergence?(run, classification)
      return false unless classification.classification == "git_non_fast_forward"

      workflow = run.step&.workflow
      return false unless workflow
      return true if workflow.artifact("retry_cancelled_reason") == "superseded"
      return true if workflow.artifact("superseded_publication").present?

      workflow.superseded_by_newer_successful_publication?
    end

    def classify_cleanup_blockers
      workflows.select { |workflow| %w[succeeded failed cancelled].include?(workflow.state) }.filter_map do |workflow|
        next if workflow.cleaned_up_at.present?
        next unless workflow.live_descendants?
        next if workflow.active_descendants?

        issue(
          kind: :cleanup_blocked_by_active_descendants,
          severity: :warning,
          affected_ids: ids_for(workflow),
          safe_to_auto_repair: false,
          recommended_repair_action: "operator_review_active_descendants",
          evidence: workflow_evidence(workflow).merge(
            active_step_ids: workflow.projected_active_step_ids,
            active_run_ids: workflow.runs.active.pluck(:id)
          ),
          explanation: "Workflow ##{workflow.id} is terminal but still has active descendants that prevent workspace cleanup."
        )
      end
    end

    def classify_workspace_prune_risks
      cutoff = now - (WorkflowWorkspacePruneJob::RETAIN_AFTER_FAILURE - 1.day)
      workflows.filter_map do |workflow|
        next unless workflow.failed?
        next if workflow.cleaned_up_at.present?
        next unless workflow.finished_at.present? && workflow.finished_at < cutoff

        issue(
          kind: :workflow_workspace_prune_risk,
          severity: :warning,
          affected_ids: ids_for(workflow),
          safe_to_auto_repair: false,
          recommended_repair_action: "retry_or_archive_before_workspace_prune",
          evidence: workflow_evidence(workflow).merge(
            finished_at: workflow.finished_at&.iso8601,
            prune_after: (workflow.finished_at + WorkflowWorkspacePruneJob::RETAIN_AFTER_FAILURE).iso8601
          ),
          explanation: "Workflow ##{workflow.id} failed and its workspace is close to the retention cutoff."
        )
      end
    end

    def classify_runaway_protected_jobs
      jobs.filter_map do |job|
        next unless job.runaway_protection.present?

        issue(
          kind: :runaway_protection_active,
          severity: :warning,
          affected_ids: ids_for(job).merge(workflow_ids: [ job.latest_workflow&.id ]),
          safe_to_auto_repair: false,
          recommended_repair_action: "operator_clear_runaway_protection",
          evidence: {
            job_state: job.state,
            runaway_protection: job.runaway_protection,
            runaway_protection_at: job.runaway_protection_at&.iso8601,
            total_workflows: job.workflows_since_latest_reopen.count,
            latest_workflow_id: job.latest_workflow&.id,
            latest_workflow_state: job.latest_workflow&.state
          },
          explanation: "Job ##{job.id} has runaway protection active (#{job.runaway_protection}); automatic retries are blocked until the operator manually retries."
        )
      end
    end

    def snapshot
      Snapshot.new(
        source: source,
        captured_at: now,
        job_ids: jobs.map(&:id),
        workflow_ids: workflows.map(&:id),
        step_ids: steps.map(&:id),
        run_ids: runs.map(&:id),
        work_intent_ids: work_intents.map(&:id),
        work_unit_ids: work_units.map(&:id),
        solid_queue_available: solid_queue[:available],
        solid_queue_jobs: solid_queue[:jobs],
        solid_queue_processes: solid_queue[:processes],
        solid_queue_pauses: solid_queue[:pauses],
        spawned_process_ids: PerformanceLogging.phase("work_engine.reconciler.snapshot_spawned_processes") {
          spawned_process_ids_for(runs.map(&:id), workflows.map(&:id))
        },
        instance_version_ids: PerformanceLogging.phase("work_engine.reconciler.snapshot_instance_versions") { InstanceVersion.fresh.pluck(:id) },
        main_health: PerformanceLogging.phase("work_engine.reconciler.snapshot_main_health") { repositories.index_with(&:main_health).transform_keys(&:slug) },
        rate_limits: PerformanceLogging.phase("work_engine.reconciler.snapshot_rate_limits") { ProviderCircuitBreaker.open_circuits(now: now, include_logs: false) },
        workspaces: PerformanceLogging.phase("work_engine.reconciler.snapshot_workspaces") {
          workflows.to_h { |workflow| [ workflow.id, workspace_snapshot_for(workflow) ] }
        }
      )
    end

    def capture_solid_queue
      PerformanceLogging.phase("work_engine.reconciler.capture_solid_queue") do
        root_ids = PerformanceLogging.phase("work_engine.reconciler.solid_queue_root_run_ids") { solid_queue_root_run_ids }
        jobs = PerformanceLogging.phase("work_engine.reconciler.solid_queue_run_jobs") do
          SolidQueue::Job
            .where(class_name: "RunJob")
            .where(finished_at: nil)
            .select(:id, :arguments, :queue_name, :priority, :finished_at)
            .to_a
        end
        # Resolve each queue job's root Run and drop the irrelevant ones before
        # fanning out. The parse below already discards everything outside
        # root_ids; doing it after four `job_id IN (...)` queries just pays for
        # rows nobody reads. The discarded share is not marginal: a failed
        # SolidQueue job keeps finished_at NULL forever, so on production this
        # query returned 1,775 rows — 1,751 of them permanently-failed RunJobs,
        # the oldest a month old — to serve 24 that were actually live. One of
        # the four fan-outs hits a 272MB failed-executions table.
        root_run_id_by_job_id = PerformanceLogging.phase("work_engine.reconciler.solid_queue_scope", count: jobs.size) do
          jobs.each_with_object({}) do |job, acc|
            root_run_id = run_id_from_solid_queue_arguments(job.arguments)
            next if root_ids.any? && !root_ids.include?(root_run_id)

            acc[job.id] = root_run_id
          end
        end
        jobs = jobs.select { |job| root_run_id_by_job_id.key?(job.id) }
        solid_queue_job_ids = jobs.map(&:id)
        ready_job_ids = PerformanceLogging.phase("work_engine.reconciler.solid_queue_ready_ids", count: solid_queue_job_ids.size) do
          solid_queue_job_ids.empty? ? Set.new : SolidQueue::ReadyExecution.where(job_id: solid_queue_job_ids).pluck(:job_id).to_set
        end
        claimed_by_job_id = PerformanceLogging.phase("work_engine.reconciler.solid_queue_claimed", count: solid_queue_job_ids.size) do
          solid_queue_job_ids.empty? ? {} : SolidQueue::ClaimedExecution.where(job_id: solid_queue_job_ids).select(:job_id, :process_id, :created_at).index_by(&:job_id)
        end
        failed_job_ids = PerformanceLogging.phase("work_engine.reconciler.solid_queue_failed", count: solid_queue_job_ids.size) do
          solid_queue_job_ids.empty? ? Set.new : SolidQueue::FailedExecution.where(job_id: solid_queue_job_ids).pluck(:job_id).to_set
        end
        scheduled_by_job_id = PerformanceLogging.phase("work_engine.reconciler.solid_queue_scheduled", count: solid_queue_job_ids.size) do
          solid_queue_job_ids.empty? ? {} : SolidQueue::ScheduledExecution.where(job_id: solid_queue_job_ids).select(:job_id, :scheduled_at).index_by(&:job_id)
        end
        running_root_run_ids = runs.select(&:running?).map(&:id).to_set
        parsed = PerformanceLogging.phase("work_engine.reconciler.solid_queue_parse") do
          jobs.filter_map do |job|
            # Already resolved and scoped above; `jobs` holds only what survived.
            root_run_id = root_run_id_by_job_id[job.id]

            claim = claimed_by_job_id[job.id]
            scheduled = scheduled_by_job_id[job.id]
            {
              id: job.id,
              root_run_id: root_run_id,
              queue_name: job.queue_name,
              priority: job.priority,
              finished_at: job.finished_at,
              ready: ready_job_ids.include?(job.id),
              claimed: claim.present?,
              claimed_at: claim&.created_at,
              process_id: claim&.process_id,
              scheduled: scheduled.present?,
              scheduled_at: scheduled&.scheduled_at,
              failed: failed_job_ids.include?(job.id),
              error: nil
            }
          end
        end
        failed_error_job_ids = parsed.filter_map { |job| job[:id] if job[:failed] && running_root_run_ids.include?(job[:root_run_id]) }
        if failed_error_job_ids.any?
          error_by_job_id = PerformanceLogging.phase("work_engine.reconciler.solid_queue_failed_errors", count: failed_error_job_ids.size) do
            SolidQueue::FailedExecution.where(job_id: failed_error_job_ids).pluck(:job_id, :error).to_h
          end
          parsed.each { |job| job[:error] = error_by_job_id[job[:id]] if error_by_job_id.key?(job[:id]) }
        end

        {
          available: true,
          jobs: parsed,
          processes: PerformanceLogging.phase("work_engine.reconciler.solid_queue_processes") {
            SolidQueue::Process.all.map { |process| { id: process.id, hostname: process.hostname, last_heartbeat_at: process.last_heartbeat_at } }
          },
          pauses: PerformanceLogging.phase("work_engine.reconciler.solid_queue_pauses") {
            SolidQueue::Pause.all.map { |pause| { id: pause.id, queue_name: pause.queue_name, created_at: pause.created_at } }
          }
        }
      end
    rescue ActiveRecord::StatementInvalid, NameError
      { available: false, jobs: [], processes: [], pauses: [] }
    end

    def solid_queue_for_run(run)
      return nil unless solid_queue[:available]

      solid_queue_jobs_for_run(run).first
    end

    def solid_queue_jobs_for_run(run)
      return [] unless solid_queue[:available]

      workflow_run_ids = workflow_root_run_ids(run.workflow)
      direct, workflow = solid_queue[:jobs].partition { |job| job[:root_run_id] == run.id }
      (direct + workflow.select { |job| workflow_run_ids.include?(job[:root_run_id]) }).uniq { |job| job[:id] }
    end

    # Two indexed lookups unioned in Ruby, not one OR'd relation.
    #
    # `where(run_id: ...).or(where(workflow_id: ...))` reads better but MySQL
    # will not combine the run_id and workflow_id indexes for it, so the OR
    # degrades to a full scan of spawned_processes — 382k rows and 375MB on
    # production. Measured there: the OR form took 127.4 seconds; the same two
    # predicates queried separately took 0.99ms and 0.80ms.
    def spawned_process_ids_for(run_ids, workflow_ids)
      by_run = run_ids.empty? ? [] : SpawnedProcess.where(run_id: run_ids).pluck(:id)
      by_workflow = workflow_ids.empty? ? [] : SpawnedProcess.where(workflow_id: workflow_ids).pluck(:id)

      (by_run | by_workflow).sort
    end

    def solid_queue_root_run_ids
      workflow_ids = workflows.map(&:id)
      return runs.map(&:id).to_set if workflow_ids.empty?

      step_ids = Step.where(workflow_id: workflow_ids).select(:id)
      Run.where(step_id: step_ids).pluck(:id).to_set
    end

    def queue_job_can_progress?(sq)
      return false if sq[:failed]
      return true if sq[:scheduled] && !dead_resume_queue?(sq[:queue_name])
      return true if sq[:ready] && !sq[:claimed] && !dead_resume_queue?(sq[:queue_name])
      return true if sq[:claimed] && solid_queue_process_live?(sq[:process_id])

      false
    end

    def stale_queue_claim?(sq)
      sq[:claimed] && older_than?(sq[:claimed_at], QUEUE_STARVATION_AFTER) && !solid_queue_process_live?(sq[:process_id])
    end

    def dead_resume_queue?(queue_name)
      queue_name = queue_name.to_s
      return false unless queue_name.start_with?("resume-")

      !InstanceVersion.worker_queue_live?(queue_name)
    end

    def workspace_snapshot_for(workflow)
      path = WorkflowWorkspace.path_for(workflow)
      if WorkflowWorkspace.remote_live_worker_workspace?(workflow)
        return {
          path: path.to_s,
          exists: true,
          inspected: false,
          worker_hostname: workflow.worker_hostname,
          worker_storage_key: workflow.worker_storage_key
        }
      end

      {
        path: path.to_s,
        exists: File.directory?(path),
        inspected: true,
        worker_hostname: workflow.worker_hostname,
        worker_storage_key: workflow.worker_storage_key
      }
    end

    def solid_queue_process_live?(process_id)
      return false if process_id.blank?

      solid_queue[:processes].any? do |process|
        process[:id] == process_id && process[:last_heartbeat_at].present? && process[:last_heartbeat_at] > 2.minutes.ago
      end
    end

    def run_id_from_solid_queue_arguments(arguments)
      payload = arguments.is_a?(String) ? JSON.parse(arguments) : arguments
      payload&.dig("arguments")&.first.to_i
    rescue JSON::ParserError, TypeError
      nil
    end

    def workflow_root_run_ids(workflow)
      return Set.new unless workflow

      Run.where(step_id: workflow.steps.select(:id)).pluck(:id).to_set
    end

    def queued_without_first_run?(workflow)
      first = workflow.first_step
      first&.queued? && !first.runs.exists?
    end

    def workflow_has_active_descendants?(workflow)
      workflow.active_descendants?
    end

    def orphaned_failed_step(workflow)
      failed_steps = workflow.steps.select(&:failed?)
      return nil if failed_steps.empty?
      return nil if workflow.live_descendants?

      failed_steps.max_by { |step| [ step.position || -1, step.id || -1 ] }
    end

    def runs_for_step_reconciliation(step)
      scoped = runs.select { |run| run.step_id == step.id }
      return scoped if scoped.any? { |run| run.queued? || run.running? || run.failed? || run.cancelled? }

      # scoped_runs skips succeeded runs during broad scans. A worker can still
      # die after a Run succeeds but before the Step transition is persisted, so
      # fetch this running Step's complete run set for the narrow repair check.
      step.runs.to_a
    end

    def step_needs_terminal_run_reconciliation?(step)
      return false unless step&.running? || (step&.queued? && step.workflow&.running?)

      step_runs = runs.select { |run| run.step_id == step.id }
      step_runs.any? && step_runs.all?(&:terminal?)
    end

    def start_blocked?(workflow)
      reason = start_block_reason(workflow)
      return false if reason.blank?
      return false if start_blocked_check_due?(workflow)

      current_start_block_active?(workflow, reason)
    end

    def start_blocked_check_due?(workflow)
      next_check_at = start_block_next_check_at(workflow)
      next_check_at.present? && next_check_at <= now
    end

    def stale_dependency_start_block?(workflow)
      start_block_reason(workflow).to_s.in?([ StepDispatcher::STACK_BLOCK_REASON, "stack_dependencies_not_ready" ]) &&
        !start_blocked_check_due?(workflow) &&
        workflow.job.dependencies_satisfied_for_execution?
    end

    def dependency_block_reason?(reason)
      %w[dependency_failed stack_dependencies_not_ready stack_fan_in_base_unavailable job_not_ready_for_execution].include?(reason.to_s)
    end

    def current_start_block_active?(workflow, reason)
      case reason.to_s
      when StepDispatcher::MAIN_HEALTH_BLOCK_REASON, "main_branch_health"
        StepDispatcher.main_health_blocking?(workflow)
      when StepDispatcher::STACK_BLOCK_REASON, "stack_dependencies_not_ready"
        !stale_dependency_start_block?(workflow)
      else
        true
      end
    end

    def eligible_main_repair_job_for_blocked_landing(workflow)
      return nil unless start_block_reason(workflow).to_s.in?([ StepDispatcher::MAIN_HEALTH_BLOCK_REASON, "main_branch_health" ])
      return nil unless workflow.job&.repository_id

      candidates = Job.approved.where(repository_id: workflow.job.repository_id).to_a
      repair_ids = candidates.select { |job| MainHealthChangedService.fix_main_job?(job) }.map(&:id)
      return nil if repair_ids.empty?

      LandingQueueProcessor.entries(Job.where(id: repair_ids))
                           .find(&:eligible?)
                           &.job
    end

    def start_block_reason(workflow)
      WorkUnits::StartBlock.for(workflow).reason
    end

    def start_block_details(workflow)
      WorkUnits::StartBlock.for(workflow).details
    end

    def start_block_next_check_at(workflow)
      WorkUnits::StartBlock.for(workflow).next_check_at
    end

    def run_stale?(run)
      t = Run::STALE_HEARTBEAT_THRESHOLD.ago
      run.last_heartbeat_at.present? ? run.last_heartbeat_at < t : run.started_at.present? && run.started_at < t
    end

    def detached_running_run?(solid_queue_job, live_process)
      return false if live_process
      return true if solid_queue_job.nil?

      solid_queue_job[:failed] && process_pruned_error?(solid_queue_job[:error])
    end

    def process_pruned_error?(error)
      error.to_s.include?("ProcessPrunedError")
    end

    def check_after_for_running_run(heartbeat_stale:, detached_ready:, detached:, last_activity_at:)
      return nil if heartbeat_stale || detached_ready
      return last_activity_at + DETACHED_WORKER_EVIDENCE_GRACE if detached && last_activity_at
      return last_activity_at + Run::STALE_HEARTBEAT_THRESHOLD if last_activity_at

      now + RESOURCE_CONGESTION_CHECK_AFTER
    end

    def fresh_activity?(timestamp)
      timestamp.present? && timestamp >= ORPHAN_RUN_GRACE_PERIOD.ago
    end

    def running_spawned_process_for(run)
      SpawnedProcess.running.where(run_id: run.id).order(Arel.sql("COALESCE(last_chunk_at, started_at) DESC")).first
    end

    def issue(kind:, severity:, evidence:, affected_ids:, safe_to_auto_repair:, recommended_repair_action:, explanation:, retry_after: nil, check_after: nil)
      Issue.new(
        kind: kind,
        severity: severity,
        evidence: evidence,
        affected_ids: affected_ids,
        safe_to_auto_repair: safe_to_auto_repair,
        recommended_repair_action: recommended_repair_action,
        retry_after: retry_after,
        check_after: check_after,
        explanation: explanation
      )
    end

    def ids_for(record)
      case record
      when Run
        { job_ids: [ record.job_id ], workflow_ids: [ record.workflow_id ], step_ids: [ record.step_id ], run_ids: [ record.id ] }
      when Step
        { job_ids: [ record.workflow.job_id ], workflow_ids: [ record.workflow_id ], step_ids: [ record.id ] }
      when Workflow
        ids = { job_ids: [ record.job_id ], workflow_ids: [ record.id ], step_ids: record.steps.map(&:id), run_ids: record.runs.pluck(:id) }
        ids[:work_unit_ids] = [ record.work_unit.id ] if record.work_unit
        ids
      when WorkUnit
        ids = { work_intent_ids: [ record.work_intent_id ], work_unit_ids: [ record.id ] }
        ids[:workflow_ids] = [ record.workflow_id ] if record.workflow_id.present?
        ids[:job_ids] = record.work_unit_members.pluck(:job_id)
        ids
      when WorkIntent
        ids = { work_intent_ids: [ record.id ] }
        ids[:job_ids] = [ record.scope_id ] if record.scope_type == "job" && record.scope_id.present?
        ids
      when Job
        { job_ids: [ record.id ] }
      else
        {}
      end
    end

    def run_evidence(run)
      {
        run_id: run.id,
        run_state: run.state,
        step_id: run.step_id,
        step_kind: run.step&.kind,
        workflow_id: run.workflow_id,
        job_id: run.job_id,
        agent_provider: run.agent_provider,
        agent_outcome: run.agent_outcome,
        started_at: run.started_at&.iso8601,
        last_heartbeat_at: run.last_heartbeat_at&.iso8601,
        created_at: run.created_at&.iso8601
      }
    end

    def workflow_evidence(workflow)
      evidence = {
        workflow_id: workflow.id,
        workflow_state: workflow.state,
        trigger_kind: workflow.trigger_kind,
        job_id: workflow.job_id,
        job_state: workflow.job.state,
        created_at: workflow.created_at&.iso8601,
        started_at: workflow.started_at&.iso8601,
        worker_hostname: workflow.worker_hostname,
        worker_storage_key: workflow.worker_storage_key
      }
      unit = workflow.work_unit
      return evidence unless unit

      evidence.merge(
        work_intent_id: unit.work_intent_id,
        work_intent_kind: unit.work_intent&.kind,
        work_intent_state: unit.work_intent&.state,
        work_unit_id: unit.id,
        work_unit_kind: unit.kind,
        work_unit_state: unit.state,
        work_unit_blocked_reason: unit.blocked_reason,
        work_unit_blocked_until: unit.blocked_until&.iso8601,
        work_unit_blocked_details: unit.blocked_details.presence,
        work_unit_member_job_ids: unit.work_unit_members.map(&:job_id),
        work_unit_active_lock_keys: unit.work_unit_locks.select(&:active?).map(&:lock_key),
        parent_work_unit_id: unit.parent_work_unit_id,
        preempted_by_work_unit_id: unit.preempted_by_work_unit_id,
        preemption_reason: unit.preemption_reason
      )
    end

    def repositories
      @repositories ||= jobs.map(&:repository).compact.uniq
    end

    def active_epic_wide_workflow_for_job?(job)
      WorkEngine::RuntimeOwnership.active_epic_wide_workflow_for_job?(job)
    end

    def active_landing_work_for_job?(job)
      WorkEngine::RuntimeOwnership.active_landing_work_for_job?(job)
    end

    def active_runtime_work_for_job?(job)
      return false unless job

      WorkUnits::TerminalWorkflowSync.for_job(job)
      job.reload.active_runtime_work?
    end

    def recoverable_cancelled_workflow_for_queued_job?(job, workflow)
      return false unless workflow&.cancelled?
      return false unless QUEUED_CANCELLED_WORKFLOW_RECOVERY_TRIGGER_KINDS.include?(workflow.trigger_kind)
      return false if cancelled_workflow_reason(workflow) == EpicWorkflowLock::BLOCK_REASON
      return false if deliberate_cancelled_workflow?(workflow)
      return false if active_epic_wide_workflow_for_job?(job)
      return false unless job.dependencies_satisfied_for_execution?

      true
    end

    def deliberate_cancelled_workflow?(workflow)
      reason = cancelled_workflow_reason(workflow).to_s
      return true if DELIBERATE_CANCELLED_WORKFLOW_REASONS.include?(reason)
      return true if reason.start_with?("operator_")
      return true if workflow.artifact("retry_cancelled_reason").present?

      false
    end

    def cancelled_workflow_reason(workflow)
      workflow.artifact("start_cancelled_reason").presence || workflow.artifact("cancelled_reason")
    end

    def cancelled_workflow_details(workflow)
      workflow.artifact("start_cancelled_details").presence || workflow.artifact("cancelled_details")
    end

    def seconds_since(timestamp)
      return nil unless timestamp

      (now - timestamp).to_i
    end

    def older_than?(timestamp, duration)
      timestamp.present? && timestamp < now - duration
    end

    def parse_time(value)
      Time.iso8601(value.to_s)
    rescue ArgumentError, TypeError
      nil
    end

    def retry_after_for(run, classification)
      quota_reset = ProviderQuotaReset.retry_after_for_run(run, now: now)
      return quota_reset if provider_quota_classification?(classification) && quota_reset
      return run.user.gh_rate_limit_reset_at if classification.classification == "rate_limited" && run.user.gh_rate_limit_reset_at&.future?

      nil
    end

    def provider_quota_classification?(classification)
      classification&.classification == ProviderUsageLimit::CLASSIFICATION
    end

    def step_repair_semantics(step)
      return nil unless step

      Step::Kind.fetch(step.kind).repair_semantics.to_s
    rescue ArgumentError
      nil
    end

    def recoverable_branch_divergence?(run)
      branch_diverged_pr_open_run?(run) &&
        run.workflow&.artifact("branch_divergence_recovery").blank? &&
        divergence_current_pr_head?(run.job, run.workflow&.artifact("branch_divergence"))
    end

    def branch_divergence_recovered_by_current_pr_branch?(workflow)
      workflow&.artifact("branch_divergence_recovery").is_a?(Hash) &&
        workflow.artifact("branch_divergence_recovery")["action"] == "superseded_by_current_pr_branch"
    end

    def branch_diverged_pr_open_run?(run)
      review_publication_step?(run.workflow, run.step&.kind) &&
        run.run_failure_classification&.classification == "branch_diverged"
    end

    def review_publication_step?(workflow, step_kind)
      return false unless workflow && step_kind

      review_publication_step_kinds_for(workflow).include?(step_kind.to_s)
    end

    def review_publication_step_kinds_for(workflow)
      work_definition_for(workflow)&.review_publication_step_kinds || []
    end

    def work_definition_for(workflow)
      WorkDefinitions.for(workflow.trigger_kind)
    rescue WorkDefinitions::UnknownKind
      nil
    end

    # external_pr_ingest already retries deterministically within its own
    # bounded RetryUntil chain (see Workflows::ExternalPrIngest). Layering the
    # work engine's separate auto-repair loop on top just because an
    # individual grader Run's outcome happened to look like a timeout or
    # worker death converts a deterministic grader/application failure into
    # an unbounded retry loop instead of letting the workflow exhaust its
    # iterations and land the Job in :failed for operator action (Retry PR
    # Ingestion).
    def external_pr_ingest_run?(run)
      run.workflow&.trigger_kind == "external_pr_ingest"
    end

    def latest_workflow_run?(run)
      workflow = run.workflow
      job = run.job
      workflow && job && workflow == job.latest_workflow
    end

    def failed_run_still_controls_step?(run)
      step = run.step
      return false unless step&.failed?

      step.latest_run == run
    end

    def divergence_current_pr_head?(job, divergence)
      return false unless job&.pr_number.present?
      return false unless divergence.is_a?(Hash)

      remote_sha = divergence["remote_sha"].presence
      remote_sha.present? && current_pr_head_sha(job).present? && remote_sha == current_pr_head_sha(job)
    end

    def current_pr_head_sha(job)
      return nil unless job
      return job[:head_sha].presence if job.has_attribute?(:head_sha)

      job.mergeability_head_sha.presence || job.pr_checks_sha.presence
    end

    def context_description
      parts = []
      parts << "job=#{job_id}" if job_id.present?
      parts << "workflow=#{workflow_id}" if workflow_id.present?
      parts << "run=#{run_id}" if run_id.present?
      return "" if parts.empty?

      " (#{parts.join(', ')})"
    end
  end
end
