module WorkEngine
  class Reconciler
    ORPHAN_RUN_GRACE_PERIOD = ReapStaleRunsJob::ORPHAN_RUN_GRACE_PERIOD
    QUEUE_STARVATION_AFTER = 10.minutes
    RESOURCE_CONGESTION_CHECK_AFTER = 5.minutes
    RATE_LIMIT_CHECK_AFTER = 10.minutes

    AFFECTED_ID_KEYS = %i[job_ids workflow_ids step_ids run_ids solid_queue_job_ids spawned_process_ids].freeze
    NONRETRYABLE_CLASSIFICATIONS = %w[
      git_conflict
      git_non_fast_forward
      no_changes_produced
      semantic_failure
      provider_usage_limit
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
      @jobs = scoped_jobs.includes(:repository, :dependencies, :epic).to_a
      @workflows = scoped_workflows.includes(:job, :steps).to_a
      @runs = scoped_runs.includes(:job, :step, :claude_session, :run_failure_classification, :run_diagnostic).to_a
      @steps = Step.where(id: @workflows.flat_map { |workflow| workflow.steps.map(&:id) } + @runs.filter_map(&:step_id)).to_a
      @solid_queue = capture_solid_queue

      issues = []
      issues.concat(classify_queued_runs)
      issues.concat(classify_paused_queues)
      issues.concat(classify_running_runs)
      issues.concat(classify_workflows)
      issues.concat(classify_job_workflow_drift)
      issues.concat(classify_jobs_without_active_workflows)
      issues.concat(classify_unambiguous_job_state_drift)
      issues.concat(classify_completed_main_grader_jobs)
      issues.concat(classify_start_blocks)
      issues.concat(classify_main_broken_workflows)
      issues.concat(classify_resource_congestion)
      issues.concat(classify_rate_limits)
      issues.concat(classify_workspace_availability)
      issues.concat(classify_resumable_sessions)
      issues.concat(classify_retryable_failures)
      issues.concat(classify_nonretryable_failures)
      issues.concat(classify_cleanup_blockers)
      issues.concat(classify_workspace_prune_risks)

      result = Result.new(source: source, captured_at: now, snapshot: snapshot, issues: issues, repair_plans: [], repair_executions: [])
      repair_plans = WorkEngine::RepairPlanner.call(result: result, now: now)
      result = result.with(repair_plans: repair_plans)
      return result unless execute_repairs?

      result.with(repair_executions: WorkEngine::RepairExecutor.call(result: result, now: now))
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
        Job.open_threads
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
        next unless older_than?(run.created_at, ORPHAN_RUN_GRACE_PERIOD)

        sq = solid_queue_for_run(run)
        workflow = run.workflow
        if sq.nil?
          issue(
            kind: :queued_run_without_queue_claim,
            severity: :error,
            affected_ids: ids_for(run),
            safe_to_auto_repair: workflow&.running? || workflow&.queued?,
            recommended_repair_action: "reenqueue_run",
            evidence: run_evidence(run).merge(solid_queue_state: "missing", age_seconds: seconds_since(run.created_at)),
            explanation: "Run ##{run.id} is queued but no active SolidQueue RunJob references it."
          )
        elsif sq[:failed]
          issue(
            kind: :queued_run_solid_queue_failed_execution,
            severity: :error,
            affected_ids: ids_for(run).merge(solid_queue_job_ids: [ sq[:id] ]),
            safe_to_auto_repair: workflow&.running? || workflow&.queued?,
            recommended_repair_action: "reenqueue_run",
            evidence: run_evidence(run).merge(solid_queue: sq, solid_queue_state: "failed_execution"),
            explanation: "Run ##{run.id} is queued but its SolidQueue RunJob has a failed execution."
          )
        elsif sq[:claimed] && older_than?(sq[:claimed_at], QUEUE_STARVATION_AFTER) && !solid_queue_process_live?(sq[:process_id])
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

    def classify_paused_queues
      return [] unless solid_queue[:available]

      paused_queue_names = solid_queue[:pauses].map { |pause| pause[:queue_name] }.compact.uniq
      return [] if paused_queue_names.empty?

      affected_runs = runs.select(&:queued?).select do |run|
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
        next unless older_than?(run.started_at, ORPHAN_RUN_GRACE_PERIOD)

        sq = solid_queue_for_run(run)
        live_process = running_spawned_process_for(run)
        heartbeat_stale = run_stale?(run)
        next if fresh_activity?(run.last_heartbeat_at) || live_process

        issue(
          kind: :running_run_without_live_worker_evidence,
          severity: heartbeat_stale ? :critical : :warning,
          affected_ids: ids_for(run).merge(solid_queue_job_ids: [ sq&.dig(:id) ], spawned_process_ids: [ live_process&.id ]),
          safe_to_auto_repair: heartbeat_stale && run.may_fail?,
          recommended_repair_action: heartbeat_stale ? "fail_run_as_worker_died" : "capture_diagnostics",
          check_after: heartbeat_stale ? nil : now + RESOURCE_CONGESTION_CHECK_AFTER,
          evidence: run_evidence(run).merge(
            solid_queue: sq,
            last_heartbeat_age_seconds: seconds_since(run.last_heartbeat_at || run.started_at),
            live_spawned_process: live_process&.id
          ),
          explanation: "Run ##{run.id} is running without enough evidence of a live worker continuing it."
        )
      end
    end

    def classify_workflows
      workflows.filter_map do |workflow|
        if workflow.queued? && older_than?(workflow.created_at, ORPHAN_RUN_GRACE_PERIOD) && queued_without_first_run?(workflow)
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
        end
      end
    end

    def classify_job_workflow_drift
      jobs.filter_map do |job|
        active = workflows.select { |workflow| workflow.job_id == job.id && %w[queued running].include?(workflow.state) }
        next if active.empty? || %w[queued running landing coding approved].include?(job.state)

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
        next if workflows.any? { |workflow| workflow.job_id == job.id && %w[queued running].include?(workflow.state) }
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

        reason = workflow.artifact("start_blocked_reason")
        issue(
          kind: dependency_block_reason?(reason) ? :dependency_stack_start_block : :main_health_start_block,
          severity: :info,
          affected_ids: ids_for(workflow),
          safe_to_auto_repair: false,
          recommended_repair_action: "wait_for_blocker_or_operator_override",
          check_after: parse_time(workflow.artifact("start_blocked_next_check_at")),
          evidence: workflow_evidence(workflow).merge(
            start_blocked_reason: reason,
            unsatisfied_dependencies: workflow.job.unsatisfied_dependencies.map(&:id)
          ),
          explanation: "Workflow ##{workflow.id} is intentionally blocked before start: #{reason}."
        )
      end
    end

    def classify_main_broken_workflows
      workflows.filter_map do |workflow|
        next unless workflow.artifact("main_broken")

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
      if max.positive? && running_count >= max && runs.any?(&:queued?)
        issues << issue(
          kind: :resource_congestion,
          severity: :info,
          affected_ids: { run_ids: runs.select(&:queued?).map(&:id) },
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
        next if workflow.worker_hostname.present? && !InstanceVersion.worker_live?(workflow.worker_hostname)

        path = WorkflowWorkspace.path_for(workflow)
        next if File.directory?(path)
        next unless workflow.steps.where(state: "running").exists? || workflow.runs.where(state: "running").exists? || workflow.retry_available?

        issue(
          kind: :workspace_missing,
          severity: :critical,
          affected_ids: ids_for(workflow),
          safe_to_auto_repair: false,
          recommended_repair_action: "start_over_with_fresh_workflow",
          evidence: workflow_evidence(workflow).merge(workspace_path: path.to_s, worker_hostname: workflow.worker_hostname),
          explanation: "Workflow ##{workflow.id} needs its workspace, but the directory is not present on the inspected worker."
        )
      end
    end

    def classify_resumable_sessions
      runs.select { |run| run.failed? && run.step&.agentic? }.filter_map do |run|
        retryable_worker_failure = run.agent_outcome == AutoRetryScheduler::WORKER_DIED_CLASSIFICATION ||
          run.run_failure_classification&.classification == AutoRetryScheduler::WORKER_DIED_CLASSIFICATION
        next unless retryable_worker_failure

        if run.claude_session.present?
          issue(
            kind: :resumable_agent_session_present,
            severity: :info,
            affected_ids: ids_for(run),
            safe_to_auto_repair: true,
            recommended_repair_action: "resume_failed_step",
            evidence: run_evidence(run).merge(session_id: run.claude_session.session_id),
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
        classification = run.run_failure_classification
        next if classification.nil?
        next unless classification.retryable

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
          explanation: "Run ##{run.id} failed with a retryable classification."
        )
      end
    end

    def classify_nonretryable_failures
      runs.select(&:failed?).filter_map do |run|
        classification = run.run_failure_classification
        next if classification.nil?
        nonretryable = classification.retryable == false || NONRETRYABLE_CLASSIFICATIONS.include?(classification.classification)
        next unless nonretryable

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
        workspaces: workflows.to_h { |workflow| [ workflow.id, { path: WorkflowWorkspace.path_for(workflow).to_s, exists: File.directory?(WorkflowWorkspace.path_for(workflow)) } ] }
      )
    end

    def capture_solid_queue
      root_ids = runs.map(&:id)
      jobs = SolidQueue::Job.where(class_name: "RunJob").where(finished_at: nil).includes(:claimed_execution, :failed_execution).to_a
      parsed = jobs.filter_map do |job|
        root_run_id = run_id_from_solid_queue_arguments(job.arguments)
        next if root_ids.any? && !root_ids.include?(root_run_id)

        claim = job.claimed_execution
        failed = job.failed_execution
        {
          id: job.id,
          root_run_id: root_run_id,
          queue_name: job.queue_name,
          priority: job.priority,
          finished_at: job.finished_at,
          claimed: claim.present?,
          claimed_at: claim&.created_at,
          process_id: claim&.process_id,
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

      solid_queue[:jobs].find { |job| job[:root_run_id] == run.id } ||
        solid_queue[:jobs].find { |job| workflow_root_run_ids(run.workflow).include?(job[:root_run_id]) }
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

    def start_blocked?(workflow)
      workflow.artifact("start_blocked_reason").present?
    end

    def dependency_block_reason?(reason)
      %w[stack_dependencies_not_ready job_not_ready_for_execution].include?(reason.to_s)
    end

    def run_stale?(run)
      t = Run::STALE_HEARTBEAT_THRESHOLD.ago
      run.last_heartbeat_at.present? ? run.last_heartbeat_at < t : run.started_at.present? && run.started_at < t
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
        worker_hostname: workflow.worker_hostname
      }
    end

    def repositories
      @repositories ||= jobs.map(&:repository).compact.uniq
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
      return run.user.gh_rate_limit_reset_at if classification.classification == "rate_limited" && run.user.gh_rate_limit_reset_at&.future?

      nil
    end

    def step_repair_semantics(step)
      return nil unless step

      Step::Kind.fetch(step.kind).repair_semantics.to_s
    rescue ArgumentError
      nil
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
