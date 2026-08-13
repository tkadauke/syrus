module WorkEngine
  class Reconciler
    ORPHAN_RUN_GRACE_PERIOD = ReapStaleRunsJob::ORPHAN_RUN_GRACE_PERIOD
    DETACHED_WORKER_EVIDENCE_GRACE = 3.minutes
    QUEUE_STARVATION_AFTER = 10.minutes
    RESOURCE_CONGESTION_CHECK_AFTER = 5.minutes
    RATE_LIMIT_CHECK_AFTER = 10.minutes

    AFFECTED_ID_KEYS = %i[job_ids workflow_ids step_ids run_ids solid_queue_job_ids spawned_process_ids].freeze
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

    def self.request(source:, job: nil, workflow: nil, run: nil)
      WorkEngine::ReconcileJob.perform_later(
        source: source.to_s,
        job_id: job&.id,
        workflow_id: workflow&.id,
        run_id: run&.id
      )
    end

    def initialize(source:, job_id: nil, workflow_id: nil, run_id: nil, now: Time.current, execute_repairs: false)
      @source = source.to_s
      @job_id = job_id
      @workflow_id = workflow_id
      @run_id = run_id
      @now = now
      @execute_repairs = execute_repairs
    end

    def call
      WorkEngine::ReconcilerActivity.record_run_started!(
        source: source,
        job_id: job_id,
        workflow_id: workflow_id,
        run_id: run_id,
        now: now,
        execute_repairs: execute_repairs?
      )
      @jobs = scoped_jobs.includes(:repository, :dependencies, :epic).to_a
      @workflows = scoped_workflows.includes(:job, :steps).to_a
      @runs = scoped_runs.includes(:job, :step, :provider_session_metadata, :run_failure_classification, :run_diagnostic).to_a
      @steps = Step.where(id: @workflows.flat_map { |workflow| workflow.steps.map(&:id) } + @runs.filter_map(&:step_id)).to_a
      @solid_queue = capture_solid_queue

      issues = []
      issues.concat(classify_epic_workflow_conflicts)
      issues.concat(classify_closed_jobs_with_active_workflows)
      issues.concat(classify_queued_runs)
      issues.concat(classify_paused_queues)
      issues.concat(classify_running_runs)
      issues.concat(classify_active_steps_with_terminal_runs)
      issues.concat(classify_queued_steps_without_runs)
      issues.concat(classify_workflows)
      issues.concat(classify_stale_auto_retry_workflows)
      issues.concat(classify_job_workflow_drift)
      issues.concat(classify_jobs_without_active_workflows)
      issues.concat(classify_queued_jobs_cancelled_by_epic_workflow_conflict)
      issues.concat(classify_queued_jobs_cancelled_without_active_workflow)
      issues.concat(classify_approved_jobs_with_landing_start_blockers)
      issues.concat(classify_unambiguous_job_state_drift)
      issues.concat(classify_completed_main_grader_jobs)
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

    attr_reader :source, :job_id, :workflow_id, :run_id, :now, :jobs, :workflows, :runs, :steps, :solid_queue

    def execute_repairs?
      @execute_repairs
    end

    def scoped_jobs
      if job_id.present?
        Job.where(id: job_id)
      elsif workflow_id.present?
        Job.where(id: Workflow.where(id: workflow_id).select(:job_id))
      elsif run_id.present?
        Job.where(id: Run.where(id: run_id).select(:job_id))
      else
        Job.where(id: Job.open_threads.select(:id))
           .or(Job.where(id: Workflow.active.select(:job_id)))
      end
    end

    def scoped_workflows
      if workflow_id.present?
        Workflow.where(id: workflow_id)
      elsif run_id.present?
        Workflow.where(id: Step.where(id: Run.where(id: run_id).select(:step_id)).select(:workflow_id))
      else
        Workflow.where(job_id: jobs.map(&:id)).where(state: %w[ queued running failed ])
      end
    end

    def scoped_runs
      if run_id.present?
        Run.where(id: run_id)
      else
        step_ids = Step.where(workflow_id: workflows.map(&:id)).select(:id)
        Run.where(step_id: step_ids).where(state: %w[ queued running failed ])
      end
    end

    def classify_queued_runs
      return [] unless solid_queue[:available]

      runs.select(&:queued?).filter_map do |run|
        next if run.job&.closed?
        next unless older_than?(run.created_at, ORPHAN_RUN_GRACE_PERIOD)

        sqs = solid_queue_jobs_for_run(run)
        workflow = run.workflow
        next if stale_auto_retry_attempt_for(workflow)

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
          issue(
            kind: :queued_run_on_dead_resume_queue,
            severity: :error,
            affected_ids: ids_for(run).merge(solid_queue_job_ids: [ sq[:id] ]),
            safe_to_auto_repair: workflow&.running? || workflow&.queued?,
            recommended_repair_action: "reenqueue_run",
            evidence: run_evidence(run).merge(solid_queue: sq, solid_queue_state: "dead_resume_queue"),
            explanation: "Run ##{run.id} is queued on a storage-affinity resume queue with no live worker."
          )
        elsif sqs.none? { |sq| queue_job_can_progress?(sq) } && (sq = sqs.find { |candidate| candidate[:failed] })
          issue(
            kind: :queued_run_solid_queue_failed_execution,
            severity: :error,
            affected_ids: ids_for(run).merge(solid_queue_job_ids: [ sq[:id] ]),
            safe_to_auto_repair: workflow&.running? || workflow&.queued?,
            recommended_repair_action: "reenqueue_run",
            evidence: run_evidence(run).merge(solid_queue: sq, solid_queue_state: "failed_execution"),
            explanation: "Run ##{run.id} is queued but its SolidQueue RunJob has a failed execution."
          )
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

        terminal_run = latest_terminal_run(step_runs)
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

    def classify_workflows
      workflows.filter_map do |workflow|
        if workflow.queued? && older_than?(workflow.created_at, ORPHAN_RUN_GRACE_PERIOD) && queued_without_first_run?(workflow)
          if landing_start_blocked_workflow?(workflow)
            reason = workflow.artifact("start_blocked_reason")
            check_after = parse_time(workflow.artifact("start_blocked_next_check_at"))
            wait_for_retry = check_after.present? && check_after.future?
            next issue(
              kind: :landing_start_blocked,
              severity: wait_for_retry ? :info : :warning,
              affected_ids: ids_for(workflow),
              safe_to_auto_repair: !wait_for_retry,
              recommended_repair_action: wait_for_retry ? "wait_for_landing_start_block_to_clear" : "start_workflow",
              check_after: check_after,
              evidence: workflow_evidence(workflow).merge(
                first_step_id: workflow.first_step&.id,
                start_blocked_reason: reason,
                start_blocked_details: workflow.artifact("start_blocked_details"),
                landing_failure_reason: workflow.failure_reason.presence || workflow.artifact("failure_reason"),
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
                start_blocked_reason: workflow.artifact("start_blocked_reason"),
                unsatisfied_dependencies: []
              ),
              explanation: "Workflow ##{workflow.id} has a stale dependency start block, but current dependency resolution is satisfied."
            )
          end

          issue(
            kind: :queued_workflow_without_first_run,
            severity: start_blocked?(workflow) ? :info : :error,
            affected_ids: ids_for(workflow),
            safe_to_auto_repair: workflow.job.open? && !start_blocked?(workflow),
            recommended_repair_action: start_blocked?(workflow) ? "wait_for_start_block_to_clear" : "start_workflow",
            check_after: parse_time(workflow.artifact("start_blocked_next_check_at")),
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

    def stale_auto_retry_attempt_for(workflow)
      return nil unless workflow&.trigger_kind == "retry" && workflow.queued?

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

    def classify_job_workflow_drift
      jobs.filter_map do |job|
        active = workflows.select { |workflow| workflow.job_id == job.id && %w[queued running].include?(workflow.state) }
        next if active.empty? || job.closed? || %w[queued running landing coding approved].include?(job.state)
        next if job.failed? && job.latest_workflow&.queued? && ReconcileJobStatesJob::Plan.for(job)

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
        next if job.workflows.active.exists?
        next if job.any_active_run?

        latest = job.latest_workflow
        next unless latest&.cancelled?
        next unless cancelled_workflow_reason(latest) == EpicWorkflowLock::BLOCK_REASON
        next if active_epic_wide_workflow_for_job?(job)
        next if job.unsatisfied_dependencies.any?

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
        next if job.workflows.active.exists?
        next if job.any_active_run?

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
        next if job.any_active_run?

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

    def landing_slot_orphaned?(job)
      job.workflows.active.none?
    end

    def landing_start_blocked_workflow?(workflow)
      workflow.job&.landing? &&
        workflow.landing_workflow? &&
        workflow.artifact("start_blocked_reason").present?
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

    def classify_completed_main_grader_jobs
      jobs.filter_map do |job|
        next unless job.kind == "main_grader"
        next if job.closed?

        latest_workflow = job.latest_workflow
        next unless job.implemented? || ReconcileJobStatesJob.new.terminal_workflow?(latest_workflow)

        issue(
          kind: :completed_main_grader_job,
          severity: :info,
          affected_ids: ids_for(job).merge(workflow_ids: [ latest_workflow&.id ]),
          safe_to_auto_repair: true,
          recommended_repair_action: "close_completed_main_grader_job",
          evidence: {
            job_state: job.state,
            latest_workflow_id: latest_workflow&.id,
            latest_workflow_state: latest_workflow&.state,
            closure_reason: Job::MAIN_GRADER_CLOSURE_REASON
          },
          explanation: "Main grader Job ##{job.id} is complete and can be closed."
        )
      end
    end

    def classify_start_blocks
      workflows.filter_map do |workflow|
        next unless workflow.queued? && start_blocked?(workflow)
        next if landing_start_blocked_workflow?(workflow)

        reason = workflow.artifact("start_blocked_reason")
        dependency_block = dependency_block_reason?(reason)
        admission_block = reason.to_s == StepDispatcher::ADMISSION_BLOCK_REASON
        issue(
          kind: start_block_issue_kind(dependency_block: dependency_block, admission_block: admission_block),
          severity: :info,
          affected_ids: ids_for(workflow),
          safe_to_auto_repair: false,
          recommended_repair_action: start_block_repair_action(dependency_block: dependency_block, admission_block: admission_block),
          check_after: parse_time(workflow.artifact("start_blocked_next_check_at")),
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
      ProviderCircuitBreaker.open_circuits(now: now).map do |decision|
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
        next unless workflow.steps.where(state: "running").exists? || workflow.runs.where(state: "running").exists? || workflow.retry_available?

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

        if workflow == job.latest_workflow && job.failed? && !job.any_active_run?
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

        issue(
          kind: :cleanup_blocked_by_active_descendants,
          severity: :warning,
          affected_ids: ids_for(workflow),
          safe_to_auto_repair: false,
          recommended_repair_action: "operator_review_active_descendants",
          evidence: workflow_evidence(workflow).merge(
            active_step_ids: workflow.steps.active.pluck(:id),
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
        solid_queue_available: solid_queue[:available],
        solid_queue_jobs: solid_queue[:jobs],
        solid_queue_processes: solid_queue[:processes],
        solid_queue_pauses: solid_queue[:pauses],
        spawned_process_ids: SpawnedProcess.where(run_id: runs.map(&:id)).or(SpawnedProcess.where(workflow_id: workflows.map(&:id))).pluck(:id),
        instance_version_ids: InstanceVersion.fresh.pluck(:id),
        main_health: repositories.index_with(&:main_health).transform_keys(&:slug),
        rate_limits: ProviderCircuitBreaker.open_circuits(now: now),
        workspaces: workflows.to_h { |workflow| [ workflow.id, workspace_snapshot_for(workflow) ] }
      )
    end

    def capture_solid_queue
      root_ids = solid_queue_root_run_ids
      ready_job_ids = SolidQueue::ReadyExecution.pluck(:job_id).to_set
      jobs = SolidQueue::Job.where(class_name: "RunJob").where(finished_at: nil).includes(:claimed_execution, :failed_execution, :scheduled_execution).to_a
      parsed = jobs.filter_map do |job|
        root_run_id = run_id_from_solid_queue_arguments(job.arguments)
        next if root_ids.any? && !root_ids.include?(root_run_id)

        claim = job.claimed_execution
        failed = job.failed_execution
        scheduled = job.scheduled_execution
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
          failed: failed.present?,
          error: failed&.error
        }
      end

      {
        available: true,
        jobs: parsed,
        processes: SolidQueue::Process.all.map { |process| { id: process.id, hostname: process.hostname, last_heartbeat_at: process.last_heartbeat_at } },
        pauses: SolidQueue::Pause.all.map { |pause| { id: pause.id, queue_name: pause.queue_name, created_at: pause.created_at } }
      }
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
      workflow.steps.active.exists? || workflow.runs.active.exists?
    end

    def orphaned_failed_step(workflow)
      failed_steps = workflow.steps.select(&:failed?)
      return nil if failed_steps.empty?
      return nil if workflow.runs.active.exists?
      return nil if workflow.steps.where(state: "running").exists?

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

    def latest_terminal_run(step_runs)
      step_runs.select(&:terminal?).max_by { |run| [ run.finished_at || run.updated_at || run.created_at || Time.zone.at(0), run.id || 0 ] }
    end

    def start_blocked?(workflow)
      reason = workflow.artifact("start_blocked_reason")
      return false if reason.blank?
      return false if start_blocked_check_due?(workflow)

      current_start_block_active?(workflow, reason)
    end

    def start_blocked_check_due?(workflow)
      next_check_at = parse_time(workflow.artifact("start_blocked_next_check_at"))
      next_check_at.present? && next_check_at <= now
    end

    def stale_dependency_start_block?(workflow)
      workflow.artifact("start_blocked_reason") == StepDispatcher::STACK_BLOCK_REASON &&
        !start_blocked_check_due?(workflow) &&
        workflow.job.unsatisfied_dependencies.empty?
    end

    def dependency_block_reason?(reason)
      %w[dependency_failed stack_dependencies_not_ready stack_fan_in_base_unavailable job_not_ready_for_execution].include?(reason.to_s)
    end

    def current_start_block_active?(workflow, reason)
      case reason.to_s
      when StepDispatcher::MAIN_HEALTH_BLOCK_REASON
        StepDispatcher.main_health_blocking?(workflow)
      when StepDispatcher::STACK_BLOCK_REASON
        !stale_dependency_start_block?(workflow)
      else
        true
      end
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
        { job_ids: [ record.job_id ], workflow_ids: [ record.id ], step_ids: record.steps.map(&:id), run_ids: record.runs.pluck(:id) }
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
      {
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
    end

    def repositories
      @repositories ||= jobs.map(&:repository).compact.uniq
    end

    def active_epic_wide_workflow_for_job?(job)
      return false unless job.epic_id

      Workflow
        .active
        .epic_wide
        .where(job_id: job.epic.jobs.select(:id))
        .exists?
    end

    def recoverable_cancelled_workflow_for_queued_job?(job, workflow)
      return false unless workflow&.cancelled?
      return false unless QUEUED_CANCELLED_WORKFLOW_RECOVERY_TRIGGER_KINDS.include?(workflow.trigger_kind)
      return false if cancelled_workflow_reason(workflow) == EpicWorkflowLock::BLOCK_REASON
      return false if deliberate_cancelled_workflow?(workflow)
      return false if active_epic_wide_workflow_for_job?(job)
      return false if job.unsatisfied_dependencies.any?

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
      run.step&.kind == "pr_open" &&
        run.run_failure_classification&.classification == "branch_diverged"
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
