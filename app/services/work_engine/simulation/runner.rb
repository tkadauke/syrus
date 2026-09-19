require "digest/sha1"
require "ostruct"

module WorkEngine
  module Simulation
    class Runner
      TERMINAL_JOB_STATES = %w[implemented approved landing closed failed no_change_needed].freeze
      SUCCESS_JOB_STATES = %w[implemented approved landing closed no_change_needed].freeze
      DEFAULT_IGNORED_RECONCILER_ISSUE_KINDS = %w[workspace_missing].freeze
      SIMULATED_ALTERNATE_PROVIDER = "claude".freeze

      def self.call(...) = new(...).call

      def initialize(
        job_ids:,
        work_intent_ids: [],
        scenario: "database",
        outcomes: {},
        scenario_events: [],
        expectations: {},
        runtime: {},
        success_states: {},
        wait_states: {},
        auto_retry_failed_jobs: true,
        global_reconcile: false,
        max_ticks: DEFAULT_MAX_TICKS,
        ignored_reconciler_issue_kinds: DEFAULT_IGNORED_RECONCILER_ISSUE_KINDS
      )
        @job_ids = Array(job_ids).map(&:to_i)
        @work_intent_ids = Array(work_intent_ids).map(&:to_i)
        @scenario = scenario
        @outcomes = outcomes.to_h
        @scenario_events = Array(scenario_events).map.with_index { |event, index| event.to_h.merge("__index" => index, "__fired" => false) }
        @expectations = expectations.to_h
        @runtime = runtime.to_h
        @success_states = success_states.to_h
        @wait_states = wait_states.to_h
        @auto_retry_failed_jobs = auto_retry_failed_jobs
        @global_reconcile = global_reconcile
        @max_ticks = max_ticks.to_i.positive? ? max_ticks.to_i : DEFAULT_MAX_TICKS
        @ignored_reconciler_issue_kinds = Array(ignored_reconciler_issue_kinds).map(&:to_s)
        @events = []
        @run_attempts = Hash.new(0)
        @worker_index = 0
      end

      def call
        max_ticks.times do |tick|
          before = fingerprint
          apply_scenario_events!(tick)
          reconcile!(tick)
          process_auto_retry_attempts!(tick)
          retry_failed_jobs!(tick)
          wake_jobs!
          process_landing_queue!(tick)
          execute_active_runs!(tick)
          next if retryable_failed_jobs?
          return success(tick + 1) if complete?
          return waiting(tick + 1) if no_active_runs? && valid_waiting?

          after = fingerprint
          if after == before && no_active_runs?
            return stuck(tick + 1, "no state changed")
          end
        end

        return waiting(max_ticks) if valid_waiting? && no_active_runs?

        stuck(max_ticks, "max ticks exhausted")
      end

      private

      attr_reader :job_ids, :work_intent_ids, :scenario, :outcomes, :scenario_events, :expectations, :runtime, :success_states, :wait_states, :max_ticks, :ignored_reconciler_issue_kinds, :events, :run_attempts

      def apply_scenario_events!(tick)
        scenario_events.each do |event|
          next if event["__fired"] && event.fetch("once", true)
          next unless condition_matches?(event["when"])

          apply_scenario_action!(tick, event)
          event["__fired"] = true
        end
      end

      def condition_matches?(condition)
        condition = condition.to_h
        return true if condition.blank?

        return Array(condition["all"]).all? { |entry| condition_matches?(entry) } if condition.key?("all")
        return Array(condition["any"]).any? { |entry| condition_matches?(entry) } if condition.key?("any")
        return !condition_matches?(condition["not"]) if condition.key?("not")

        condition.all? do |key, value|
          case key.to_s
          when "job" then job_condition_matches?(value)
          when "epic" then epic_condition_matches?(value)
          when "run" then run_condition_matches?(value)
          when "workflow" then workflow_condition_matches?(value)
          when "work_unit" then work_unit_condition_matches?(value)
          when "queue" then queue_condition_matches?(value)
          else raise ArgumentError, "unknown simulation event condition #{key.inspect}"
          end
        end
      end

      def job_condition_matches?(condition)
        condition = normalize_job_condition(condition)
        job = Job.find(condition.fetch("id"))
        matches_state?(job.state, condition) &&
          matches_boolean?(job.pr_number.present?, condition["has_pr"])
      end

      def epic_condition_matches?(condition)
        condition = normalize_epic_condition(condition)
        epic = Epic.find(condition.fetch("id"))
        matches_state?(epic.state, condition)
      end

      def workflow_condition_matches?(condition)
        condition = condition.to_h
        scope = Workflow.where(job_id: condition.fetch("job"))
        scope = scope.where(trigger_kind: condition["kind"]) if condition["kind"].present?
        scope = scope.where(state: Array(condition["state"] || condition["states"])) if condition["state"].present? || condition["states"].present?
        return false unless scope.exists?
        return true if condition["start_blocked"].blank?

        scope.any? { |workflow| WorkUnits::StartBlock.for(workflow).reason.to_s == condition["start_blocked"].to_s }
      end

      def work_unit_condition_matches?(condition)
        condition = condition.to_h
        scope = WorkUnit.joins(:work_unit_members).where(work_unit_members: { job_id: condition.fetch("job") })
        scope = scope.where(kind: condition["kind"]) if condition["kind"].present?
        scope = scope.where(state: Array(condition["state"] || condition["states"])) if condition["state"].present? || condition["states"].present?
        scope = scope.where(blocked_reason: condition["blocked_reason"]) if condition["blocked_reason"].present?
        scope.exists?
      end

      def run_condition_matches?(condition)
        condition = condition.to_h
        scope = Run.joins(:step)
        scope = scope.where(job_id: condition["job"]) if condition["job"].present?
        scope = scope.where(state: Array(condition["state"] || condition["states"])) if condition["state"].present? || condition["states"].present?
        scope = scope.where(steps: { kind: condition["step"] || condition["kind"] }) if condition["step"].present? || condition["kind"].present?
        return scope.exists? if condition["name"].blank?

        scope.includes(:step).any? { |run| run.step&.details.to_h["name"].to_s == condition["name"].to_s }
      end

      def queue_condition_matches?(condition)
        condition.to_h.all? do |key, value|
          case key.to_s
          when "active_runs" then matches_queue_state?(active_runs.empty?, value)
          when "active_work_units" then matches_queue_state?(active_work_units.empty?, value)
          when "landing" then matches_queue_state?(landing_queue.empty?, value)
          when "landing_front"
            landing_queue.first&.id == value.to_i
          else raise ArgumentError, "unknown simulation queue condition #{key.inspect}"
          end
        end
      end

      def apply_scenario_action!(tick, event)
        actions = event.fetch("do", {})
        label = event["name"].presence || "event #{event.fetch("__index") + 1}"
        events << "tick #{tick}: event #{label}"
        actions.each do |key, value|
          case key.to_s
          when "approve" then approve_job!(value)
          when "close" then close_job!(value)
          when "complete_epic" then complete_epic!(value)
          when "fail" then fail_job!(value)
          when "set_pr_checks" then set_pr_checks!(value)
          when "advance_main" then advance_main!(value)
          when "exhaust_provider_usage" then exhaust_provider_usage!(value)
          when "refresh_provider_usage" then refresh_provider_usage!(value)
          when "set_provider_status" then set_provider_status!(value)
          when "set_job_provider" then set_job_provider!(value)
          when "merge_pr" then merge_pr!(value)
          when "report_pr_feedback" then report_pr_feedback!(value)
          when "report_ci_failure" then report_ci_failure!(value)
          when "break_main_branch" then break_main_branch!(value)
          when "heal_main_branch" then heal_main_branch!(value)
          when "wake_provider_admission" then wake_provider_admission!(value)
          when "resume_deferred_phase" then resume_deferred_phase!(value)
          when "lose_worker" then lose_worker!(value)
          else raise ArgumentError, "unknown simulation event action #{key.inspect}"
          end
        end
      end

      def approve_job!(job_id)
        job = Job.find(job_id)
        job.approve!(via: "operator") if job.may_approve?
        job.save!
      end

      def close_job!(value)
        attrs = value.is_a?(Hash) ? value : { "job" => value }
        job = Job.find(attrs.fetch("job"))
        job.close_with_reason!(attrs.fetch("reason", "pr_merged")) if job.may_close?
      end

      def complete_epic!(epic_id)
        epic = Epic.find(epic_id)
        if epic.may_auto_complete?
          epic.auto_complete!
        else
          epic.update!(state: "done", done_at: Time.current)
        end
        epic.dependent_epics.find_each(&:refresh_auto_state!)
      end

      def fail_job!(job_id)
        job = Job.find(job_id)
        job.force_fail! if job.may_force_fail?
        job.save!
      end

      def set_pr_checks!(value)
        attrs = value.to_h
        job = Job.find(attrs.fetch("job"))
        job.update!(
          pr_checks_state: attrs.fetch("state"),
          pr_checks_sha: attrs["sha"] || job.mergeability_head_sha || job.head_sha
        )
      end

      def advance_main!(value)
        attrs = value.is_a?(Hash) ? value : { "sha" => value }
        Repository.where(id: jobs.map(&:repository_id).uniq).find_each do |repository|
          repository.update!(
            last_health_checked_sha: attrs["sha"].presence || simulated_main_sha(repository, attrs),
            last_ci_evaluated_sha: attrs["sha"].presence || simulated_main_sha(repository, attrs)
          )
        end
        Job.where(id: job_ids).where.not(pr_number: nil).update_all("commits_behind_base = COALESCE(commits_behind_base, 0) + 1")
      end

      # Records provider usage evidence the way a usage poller would, so the
      # real availability gate, circuit breaker, and wakeup services react to
      # it. Both actions bust the availability and breaker read caches: ticks
      # run in one process, so without this the gate would keep reading the
      # decision computed before the evidence existed.
      def exhaust_provider_usage!(value)
        record_simulated_provider_usage!(provider_for(value), status: "exhausted")
      end

      def refresh_provider_usage!(value)
        record_simulated_provider_usage!(provider_for(value), status: "available")
      end

      # Generic form of the two above, for provider states beyond the
      # usage-quota axis (auth_error, rate_limited, ...). Takes
      # `{ provider:, status: }`; a bare provider name records "available".
      def set_provider_status!(value)
        attrs = value.is_a?(Hash) ? value : {}
        provider = attrs["provider"].presence || (value.is_a?(String) ? value : nil) || "codex"
        record_simulated_provider_usage!(provider, status: attrs["status"].presence || "available")
      end

      def wake_provider_admission!(value)
        provider = provider_for(value)
        admission = ProviderAdmissionWakeup.call(provider: provider, user: simulation_user)
        resumed = resume_blocked_workflows!(WorkUnits::Gates::ProviderAvailability::REASON, provider: provider)
        events << "provider admission wakeup: #{admission.workflow_count} workflows, " \
                  "#{admission.auto_retry_count} auto retries, #{resumed} deferred phases resumed"
      end

      def resume_deferred_phase!(value)
        attrs = value.is_a?(Hash) ? value : { "job" => value }
        job = Job.find(attrs.fetch("job"))
        workflow = job.workflows.order(:id).last
        step = if attrs["step"].present?
          workflow.steps.find_by!(kind: attrs.fetch("step").to_s)
        end
        result = WorkUnits::DeferredPhaseResume.call(workflow.id, step&.id)
        events << "deferred phase resume for #{job.slug}: #{result.status}"
      end

      # Runs the same resume the enqueued WorkflowPhaseAdmissionJob would run,
      # inline: there are no queue workers in a simulation. Covers workflows
      # already mid-flight, which ProviderAdmissionWakeup intentionally skips.
      def resume_blocked_workflows!(reason, provider: nil)
        scope = WorkUnit
          .joins(:workflow)
          .where(state: "blocked", blocked_reason: reason)
          .where(workflows: { state: %w[queued running] })
          .order(:id)
        scope = scope.where(workflows: { agent_provider: provider.to_s }) if provider
        scope.filter_map { |unit| WorkUnits::DeferredPhaseResume.call(unit.workflow_id) }.count(&:started?)
      end

      # Mirrors the operator switching a job's provider mid-flight: repins
      # unstarted workflows, then leaves the running-but-blocked one for the
      # reconciler's stale-provider relaunch. Takes `{ job:, provider: }`.
      def set_job_provider!(value)
        attrs = value.to_h
        job = Job.find(attrs.fetch("job"))
        provider = resolve_simulated_provider(attrs.fetch("provider"))
        job.switch_job_provider_setting!(provider)
        events << "switched #{job.slug} provider to #{provider}"
      end

      # Models someone merging (or closing) the job's PR on GitHub, outside
      # Syrus. Runs the real closed-PR resolution with the merged flag as the
      # injected boundary fact -- the cherry-classification fallback needs a
      # clone and stays covered by unit specs. Takes `{ job:, merged: }`
      # (default true); unmerged closes resolve pr_closed here because the
      # patch-presence check cannot run without a remote.
      def merge_pr!(value)
        attrs = value.is_a?(Hash) ? value : { "job" => value }
        job = Job.find(attrs.fetch("job"))
        merged = attrs.fetch("merged", true)
        pr = OpenStruct.new(
          merged: merged,
          base: OpenStruct.new(ref: job.repository.default_branch, sha: nil)
        )
        reason = ClosedPullRequestResolution.reason(job: job, pr: pr, client: nil)
        job.close_with_reason!(reason) if job.may_close?
        events << "#{merged ? "merged" : "closed"} PR for #{job.slug} -> #{reason}"
      end

      # Models a reviewer commenting on the job's PR. The comment payload is
      # the injected boundary fact; ingestion (dedup, attribution,
      # actionable classification), watermarking, and the pr_comment
      # dispatch all run for real. Takes `{ job:, body:, handle: }`.
      def report_pr_feedback!(value)
        attrs = value.is_a?(Hash) ? value : {}
        job = Job.find(attrs.fetch("job"))
        comment = OpenStruct.new(
          id: attrs.fetch("comment_id", 90_001),
          body: attrs.fetch("body", "Please handle the empty-input edge case too."),
          created_at: Time.current,
          user: OpenStruct.new(login: attrs.fetch("handle", "operator"))
        )
        user = job.owner_user || job.user
        result = PrCommentIngester.call(
          job: job, comments: [ comment ], pr_type: "direct",
          comment_kind: "issue", user: user,
          agent_provider: job.workflow_agent_provider
        )
        if result.qualifying_records.empty?
          events << "reported PR feedback on #{job.slug}: no qualifying comments"
          return
        end

        cutoff = [ job.last_seen_comment_at, job.last_feedback_addressed_at ].compact.max
        workflow = nil
        job.with_lock do
          job.reload
          Job::ApprovalUnapprover.call(job: job, user: job.user) if job.may_unapprove?
          workflow = WorkUnits::Launcher.instantiate(
            kind: "pr_comment",
            job: job,
            artifacts: {
              "pr_comments" => result.qualifying_records.map { |r| { "id" => r.id, "body" => r.body } },
              "feedback_cutoff" => cutoff&.iso8601,
              "pr_feedback_iteration" => job.workflows.where(trigger_kind: Workflow::TriggerKind.feedback_values).count + 1,
              "pr_feedback_auto" => true
            },
            agent_provider: job.workflow_agent_provider
          )
          job.update!(last_seen_comment_at: comment.created_at)
        end
        return unless workflow

        WorkUnits::Launcher.start!(workflow)
        events << "dispatched pr_comment workflow for #{job.slug}"
      end

      # Models CI reporting failure on the job's PR head. Dispatches the real
      # CiFailure workflow; set_pr_checks separately to keep the world
      # consistent. Skips when the sha was already handled, like the poller.
      # Takes `{ job:, failed_checks:, base_sha:, base_healthy: }`. The base
      # is recorded at a known-healthy sha by default -- the precondition the
      # poller verifies before dispatching, which a simulation has no
      # main-grader history for. Pass `base_healthy: false` to exercise the
      # ci_repair_safety suppression instead.
      def report_ci_failure!(value)
        attrs = value.is_a?(Hash) ? value : {}
        job = Job.find(attrs.fetch("job"))
        head_sha = job.mergeability_head_sha.presence || job.head_sha.presence || "simulated-head"
        if job.last_ci_handled_sha == head_sha
          events << "CI already handled for #{job.slug} at #{head_sha[0, 7]}"
          return
        end

        base_sha = attrs["base_sha"].presence || "simulated-base"
        record_simulated_base_health!(job, base_sha) unless attrs.key?("base_healthy") && !attrs["base_healthy"]
        failed_checks = attrs.fetch("failed_checks", [ { "name" => "rspec", "conclusion" => "failure" } ])
        result = WorkUnits::Launcher.create_and_start!(
          kind: "ci_failure",
          job: job,
          artifacts: {
            "head_sha" => head_sha,
            "base_sha" => base_sha,
            "failed_checks" => failed_checks
          },
          agent_provider: job.workflow_agent_provider
        )
        if result.run
          job.update!(last_ci_handled_sha: head_sha)
          events << "dispatched ci_failure workflow for #{job.slug}"
        else
          events << "ci_failure workflow for #{job.slug} deferred at start"
        end
      end

      # Models main-branch health flipping to broken (e.g. the main_grader
      # workflow failing) and recovering (repair landed). The block itself --
      # strict policy, repair-blocks-work, paused landing, broken health --
      # is evaluated by the real dispatcher gate; these actions only move
      # the world state the gate reads.
      def break_main_branch!(value)
        repository = simulation_repository
        repository.update!(grader_health: "broken", landing_paused: true)
        events << "broke main branch health"
      end

      def heal_main_branch!(value)
        repository = simulation_repository
        repository.update!(grader_health: "healthy", ci_health: "healthy", landing_paused: false)
        resumed = resume_blocked_workflows!(WorkUnits::Gates::MainBranchHealth::REASON)
        events << "healed main branch health, #{resumed} deferred phases resumed"
      end

      def lose_worker!(value)
        attrs = value.is_a?(Hash) ? value : { "hostname" => value }
        hostname = attrs.fetch("hostname").to_s
        stale_at = attrs["stale_at"].present? ? Time.zone.parse(attrs.fetch("stale_at")) : 15.minutes.ago
        InstanceVersion.where(hostname: hostname, role: "worker").update_all(
          last_heartbeat_at: stale_at,
          finished_at: stale_at,
          outcome: "lost",
          updated_at: Time.current
        )
        SpawnedProcess.running.where(hostname: hostname).find_each do |process|
          process.update_columns(
            last_chunk_at: stale_at,
            started_at: [ process.started_at || stale_at, stale_at ].min,
            updated_at: Time.current
          )
          Run.where(id: process.run_id).update_all(
            last_heartbeat_at: stale_at,
            started_at: stale_at,
            updated_at: Time.current
          )
        end
        if defined?(SolidQueue::Process)
          SolidQueue::Process.where(hostname: hostname).update_all(last_heartbeat_at: stale_at)
        end
        events << "lost worker #{hostname}"
      end

      def simulation_repository
        jobs.first&.repository
      end

      def record_simulated_base_health!(job, base_sha)
        MainBranchHealthCheck.create!(
          repository: job.repository,
          sha: base_sha,
          ci_health: "healthy",
          grader_health: "healthy",
          checked_at: Time.current,
          source: "grader_workflow"
        )
      end

      def provider_for(value)
        attrs = value.is_a?(Hash) ? value : {}
        provider = attrs["provider"].presence || (value.is_a?(String) ? value : nil) || "codex"
        resolve_simulated_provider(provider)
      end

      def resolve_simulated_provider(provider)
        case provider.to_s
        when "alternate"
          User.agent_providers.find { |candidate| candidate != "codex" } ||
            ensure_simulated_agent_provider!(SIMULATED_ALTERNATE_PROVIDER)
        else
          provider.to_s.tap { |resolved| ensure_simulated_agent_provider!(resolved) }
        end
      end

      def ensure_simulated_agent_provider!(provider)
        provider = provider.to_s
        return provider if User.agent_providers.include?(provider)

        provider_class = Class.new(AgentProviders::Base) do
          include Syrus::Plugin::AgentProvider

          define_singleton_method(:provider_key) { provider }
          define_singleton_method(:display_name) { provider.to_s.humanize }
          define_singleton_method(:available?) { true }
        end
        Syrus::PluginRegistry.register(:agent_provider, provider_class)
        provider
      end

      def simulation_user
        jobs.first&.user
      end

      def record_simulated_provider_usage!(provider, status:)
        user = simulation_user
        ProviderAvailabilityEvidence.create!(
          user: user,
          provider: provider.to_s,
          status: status,
          source: "simulation",
          observed_at: Time.current
        )
        App::ProviderAvailability.clear_cache!(user: user, provider: provider.to_s)
        ProviderCircuitBreaker.clear_read_cache!
      end

      def reconcile!(tick)
        if global_reconcile?
          reconcile_result!(tick, WorkEngine::Reconciler.call(source: "simulation:#{scenario}:tick#{tick}", execute_repairs: true))
        else
          job_ids.each do |job_id|
            reconcile_result!(
              tick,
              WorkEngine::Reconciler.call(
                source: "simulation:#{scenario}:tick#{tick}:job#{job_id}",
                job_id: job_id,
                execute_repairs: true
              )
            )
          end
        end
        scenario_work_intent_ids.each do |intent_id|
          reconcile_result!(
            tick,
            WorkEngine::Reconciler.call(
              source: "simulation:#{scenario}:tick#{tick}:#{intent_id}",
              work_intent_id: intent_id,
              execute_repairs: true
            )
          )
        end
      end

      def global_reconcile?
        @global_reconcile == true
      end

      def reconcile_result!(tick, result)
        result.issues.each do |issue|
          next if ignored_reconciler_issue_kinds.include?(issue.kind)

          events << "tick #{tick}: reconciler #{issue.kind}"
        end
        result.repair_executions.each do |execution|
          next if execution.status == "success"

          events << "tick #{tick}: repair #{execution.action} -> #{execution.status} #{execution.message}"
        end
      end

      def wake_jobs!
        jobs.each do |job|
          job.reload
          job.start_pending_workflows_if_dependencies_satisfied! if job.open?
        rescue WorkUnits::Launcher::LockConflict => e
          events << "wakeup #{job.slug}: active lock #{e.lock_key}"
        end
      end

      def process_landing_queue!(tick)
        workflow = LandingQueueProcessor.new.call
        return unless workflow
        return unless job_ids.include?(workflow.job_id)

        events << "tick #{tick}: landing_queue dispatched #{workflow.slug} #{workflow.trigger_kind} for #{workflow.job.title}"

      rescue WorkUnits::Launcher::LockConflict => e
        events << "tick #{tick}: landing_queue active lock #{e.lock_key}"
      end

      def retry_failed_jobs!(tick)
        return unless auto_retry_failed_jobs?

        jobs.each do |job|
          job.reload
          next unless job.failed?

          result = SmartRetryEnqueuer.call(job: job, automatic: false)
          next unless result.success?

          events << "tick #{tick}: retry #{job.slug} via #{result.action}"
        end
      end

      def process_auto_retry_attempts!(tick)
        attempts = pending_auto_retry_attempts
        return if attempts.empty?

        next_attempt = attempts.min_by { |attempt| [ attempt.scheduled_at || Time.current, attempt.id ] }
        if next_attempt.scheduled_at&.future? && no_active_runs?
          next_attempt.update!(scheduled_at: Time.current)
          events << "tick #{tick}: fast-forward auto retry #{next_attempt.id}"
        end

        pending_auto_retry_attempts.where("scheduled_at <= ?", Time.current).order(:scheduled_at, :id).each do |attempt|
          AutoRetryJob.perform_now(attempt.id)
          attempt.reload
          events << "tick #{tick}: auto retry #{attempt.id} #{attempt.retry_kind} -> #{attempt.performed_at.present? ? "started" : "skipped"}"
        end
      end

      def retryable_failed_jobs?
        return false unless auto_retry_failed_jobs?

        jobs.any?(&:failed?)
      end

      def auto_retry_failed_jobs?
        @auto_retry_failed_jobs
      end

      def execute_active_runs!(tick)
        active_runs.each do |run|
          execute_run!(run, tick)
        end
      end

      def execute_run!(run, tick)
        unless run.step&.dependencies_settled?
          events << "tick #{tick}: #{run.slug} #{run.step&.kind} -> deferred waiting for dependencies"
          return
        end

        run_attempts[run_signature(run)] += 1
        outcome = outcome_for(run)
        events << "tick #{tick}: #{run.slug} #{run.step&.kind} -> #{outcome_label(outcome)}"

        start_run!(run, outcome)
        case outcome_status(outcome)
        when "success"
          if simulate_side_effects!(run, outcome) == :failed
            finish_simulated_processes!(run, "failed")
            fail_run!(run, agent_outcome: "error",
                           failure_code: simulated_failure_code(outcome),
                           error_message: simulated_outcome_field(outcome, "error_message"),
                           error_class: simulated_outcome_field(outcome, "error_class"))
          else
            finish_simulated_processes!(run, "succeeded")
            succeed_run_and_step!(run)
          end
        when "pending"
          # Leave the run active for another tick. This lets scenarios model
          # parallel fanout where one grader is still running while another
          # sibling has already failed.
        when "worker_died"
          finish_simulated_processes!(run, "orphaned")
          fail_run!(run, agent_outcome: AutoRetryAttempt::WORKER_DIED_CLASSIFICATION)
        when "failure"
          finish_simulated_processes!(run, "failed")
          fail_run!(run, agent_outcome: "error",
                         failure_code: simulated_failure_code(outcome),
                         error_message: simulated_outcome_field(outcome, "error_message"),
                         error_class: simulated_outcome_field(outcome, "error_class"))
        else
          raise ArgumentError, "unknown simulation outcome #{outcome.inspect} for #{run.slug}"
        end
      end

      def start_run!(run, outcome)
        workflow = run.workflow
        workflow.start! && workflow.save! if workflow&.may_start?
        step = run.step
        step.start! && step.save! if step&.may_start?
        run.start! && run.save! if run.may_start?
        record_simulated_runtime!(run.reload, outcome)
      end

      def succeed_run_and_step!(run)
        run.succeed!
        run.save!
        step = run.step.reload
        return unless step.may_succeed?

        step.succeed!
        step.save!
        drain_step_success!(step)
      end

      def fail_run!(run, agent_outcome:, failure_code: nil, error_message: nil, error_class: nil)
        if failure_code.present?
          stamp_simulated_failure_code!(run, failure_code)
        end
        if error_message.present? || error_class.present?
          record_simulated_diagnostic!(run, error_class: error_class, error_message: error_message)
        end
        run.agent_outcome = agent_outcome
        run.fail!
        run.save!
        drain_run_failure!(run.reload)
      end

      # Gives the failed run the diagnostic a real handler would have
      # captured, so reason-text matching downstream (transient blockers,
      # quota resets, failure_reason_for) reads the injected fact instead
      # of a generic message.
      def record_simulated_diagnostic!(run, error_class:, error_message:)
        RunDiagnostic.create!(
          run: run,
          error_class: error_class.presence || "Steps::Base::StepFailed",
          error_message: error_message.presence || "simulated failure"
        )
      end

      # Stamps the failure code a real step handler would have stamped for
      # this failure (see Steps::Base#mark_failure_code!), so Try branches
      # match for real. The code itself -- e.g. the remote moving under a
      # push -- is the injected external fact, exactly like an outcome.
      def stamp_simulated_failure_code!(run, failure_code)
        problem = Problem::Kind.resolve(failure_code)
        return if problem.nil?

        step = run.step
        return unless step

        step.update!(
          details: step.details.to_h.merge(
            "failure_code" => failure_code,
            "problem_code" => problem.code
          )
        )
      end

      def simulated_failure_code(outcome)
        simulated_outcome_field(outcome, "failure_code")
      end

      def simulated_outcome_field(outcome, field)
        return nil unless outcome.is_a?(Hash)

        outcome[field].presence || outcome[field.to_sym].presence
      end

      def drain_step_success!(step)
        workflow = step.workflow.reload
        return unless workflow.running?
        return if workflow.runs.where(state: %w[queued running]).exists?

        StepDispatcher.advance_from(step)
      end

      def drain_run_failure!(run)
        step = run.step&.reload
        return unless step

        unless step.failed?
          step.fail!
          step.save!
        end
        step.reload
        if step_fail_policy(step) == :advance
          StepDispatcher.advance_from(step)
        elsif step.workflow.reload.may_fail?
          StepDispatcher.fail_from(step)
        end
      end

      def step_fail_policy(step)
        Step::Kind.fetch(step.kind).fail_policy
      rescue ArgumentError
        :fail_workflow
      end

      def simulate_side_effects!(run, outcome = nil)
        job = run.job
        case run.step&.kind
        when "implement", "respond", "analyze_and_fix", "landing_fix", "run_skill"
          sha = simulated_sha(run)
          run.update_columns(head_sha: sha)
          job.update_columns(
            branch_name: job.branch_name.presence || "syrus/simulated-#{job.id}",
            mergeability_head_sha: sha
          )
        when "pr_open"
          sha = job.head_sha.presence || simulated_sha(run)
          run.update_columns(head_sha: sha)
          job.update_columns(
            branch_name: job.branch_name.presence || "syrus/simulated-#{job.id}",
            pr_number: job.pr_number.presence || job.id + 10_000,
            pr_checks_state: "passing",
            pr_checks_sha: sha,
            mergeability_head_sha: sha
          )
        when "auto_merge"
          close_job_if_possible!(job, "pr_merged")
        when "merge_train_land", "merge_train_land_after_rebase"
          return mark_merge_train_members_unverified!(run, outcome) if simulated_outcome_field(outcome, "unverified_members").present?

          close_merge_train_members!(run)
        when "stack_auto_rebase"
          simulate_stack_auto_rebase!(run, outcome)
        end
      end

      def simulate_stack_auto_rebase!(run, outcome)
        results = stack_rebase_results_for(run, outcome)
        run.workflow.set_artifact!(StackRebasePlan::RESULTS_ARTIFACT, results) if results.any?
        run.workflow.set_artifact!(StackRebasePlan::AGENT_PENDING_ARTIFACT, [])

        results.each do |entry|
          next unless entry.dig("result", "reason") == ::AutoRebase::ALREADY_LANDED_REASON

          stack_job = Job.find_by(id: entry["job_id"])
          close_job_if_possible!(stack_job, "pr_merged")
        end
        skip_next_step!(run.step, "stack auto-rebase already succeeded")
      end

      def stack_rebase_results_for(run, outcome)
        entries = Array(run.workflow.artifact(StackRebasePlan::STACK_ARTIFACT))
        configured = outcome.is_a?(Hash) ? outcome.fetch("stack_results", {}) : {}
        entries.map do |entry|
          reason = configured[entry["job_id"].to_s] || configured[entry["job_id"]] || "rebased"
          entry.merge(
            "result" => {
              "succeeded" => true,
              "reason" => reason,
              "changed" => false,
              "pre_sha" => simulated_sha_for("stack-pre", entry["job_id"]),
              "post_sha" => simulated_sha_for("stack-post", entry["job_id"]),
              "base_sha" => simulated_sha_for("stack-base", entry["job_id"])
            }
          )
        end
      end

      def close_merge_train_members!(run)
        train = MergeTrain.find_by(id: run.workflow.artifact("merge_train_id"))
        train&.members&.find_each { |member| member.update!(state: "merged") }
        member_jobs = train&.member_jobs&.to_a.presence || run.workflow.work_unit&.member_jobs&.to_a || [ run.job ]
        member_jobs.compact.each { |member_job| close_job_if_possible!(member_job, "pr_merged") }
        train&.update!(state: "succeeded", finished_at: Time.current) unless train&.state == "succeeded"
      end

      def mark_merge_train_members_unverified!(run, outcome)
        train = MergeTrain.find_by(id: run.workflow.artifact("merge_train_id"))
        return :failed unless train

        configured = Array(simulated_outcome_field(outcome, "unverified_members")).map(&:to_s)
        members = if configured.empty?
          train.members.to_a
        elsif configured.include?("all")
          train.members.to_a
        else
          train.members.includes(:job).select { |member| configured.include?(member.job_id.to_s) || configured.include?(member.job&.slug.to_s) }
        end
        members = train.members.to_a if members.empty?

        slugs = members.filter_map { |member| member.job&.slug }
        reason = simulated_outcome_field(outcome, "error_message").presence ||
          "merge_train: landed integration #{train.integration_sha.to_s.first(9)} but could not verify #{slugs.size}/#{train.members.size} member(s): #{slugs.join(', ')}; needs re-landing"
        members.each { |member| member.update!(state: "failed", reason: reason.truncate(500)) }
        train.update!(state: "failed", failure_reason: reason.truncate(500), finished_at: Time.current)
        :failed
      end

      def close_job_if_possible!(job, reason)
        return unless job&.may_close?

        job.close_with_reason!(reason)
      end

      def skip_next_step!(step, reason)
        next_step = step.next_step
        return unless next_step&.may_skip?

        next_step.skip_with_reason!(reason)
      end

      def outcome_for(run)
        step_key = "#{run.job_id}:#{run.step&.kind}"
        named_step_key = "#{step_key}:#{run.step&.details.to_h["name"]}" if run.step&.details.to_h["name"].present?
        named_kind_key = "#{run.step&.kind}:#{run.step&.details.to_h["name"]}" if run.step&.details.to_h["name"].present?
        scripted = outcomes.fetch("steps", {})[step_key] ||
          outcomes.fetch("steps", {})[named_step_key] ||
          outcomes.fetch("steps", {})[named_kind_key] ||
          outcomes.fetch("steps", {})[run.step&.kind.to_s]
        sequence_outcome(scripted, run) || outcomes.fetch("default", "success")
      end

      def sequence_outcome(scripted, run)
        return scripted if scripted.is_a?(String)
        return scripted if scripted.is_a?(Hash)
        return nil unless scripted.is_a?(Array)

        scripted[[ run_attempts[run_signature(run)] - 1, scripted.length - 1 ].min]
      end

      def outcome_status(outcome)
        outcome.is_a?(Hash) ? outcome.fetch("status", "success") : outcome
      end

      def outcome_label(outcome)
        outcome.is_a?(Hash) ? outcome.inspect : outcome
      end

      def run_signature(run)
        [ run.job_id, run.step&.kind, run.step&.details.to_h["name"] ].compact.join(":")
      end

      def record_simulated_runtime!(run, outcome)
        hostname = worker_hostname_for(run, outcome)
        storage_key = worker_storage_key_for(hostname, outcome)
        hostname, storage_key = route_pinned_workflow_run!(run, hostname, storage_key)
        ensure_worker_live!(hostname, storage_key)
        unless run.distributed_parallel_run?
          run.workflow.update_columns(worker_hostname: hostname, worker_storage_key: storage_key, updated_at: Time.current)
        end
        run.update_columns(last_heartbeat_at: Time.current, updated_at: Time.current) if run.running?
        return if run.spawned_processes.running.exists?

        run.spawned_processes.create!(
          workflow: run.workflow,
          kind: simulated_process_kind_for(run),
          command: simulated_process_command_for(run),
          hostname: hostname,
          pid: simulated_pid_for(run),
          started_at: run.started_at || Time.current,
          last_chunk_at: Time.current
        )
      end

      def route_pinned_workflow_run!(run, hostname, storage_key)
        required_storage_key = run.workflow&.worker_storage_key.presence
        return [ hostname, storage_key ] if required_storage_key.blank?
        return [ hostname, storage_key ] if run.distributed_parallel_run?
        return [ hostname, storage_key ] if storage_key == required_storage_key

        required_hostname = worker_hostname_for_storage_key(required_storage_key)
        return [ hostname, storage_key ] if required_hostname.blank?

        events << "placement rerouted #{run.slug} #{run.step&.kind} from #{hostname}/#{storage_key} to #{required_hostname}/#{required_storage_key}"
        [ required_hostname, required_storage_key ]
      end

      def worker_hostname_for_storage_key(storage_key)
        runtime.fetch("worker_storage_keys", {}).find { |_hostname, candidate| candidate.to_s == storage_key.to_s }&.first
      end

      def finish_simulated_processes!(run, outcome)
        run.spawned_processes.running.update_all(
          finished_at: Time.current,
          outcome: outcome,
          updated_at: Time.current
        )
      end

      def worker_hostname_for(run, outcome)
        simulated_outcome_field(outcome, "worker").presence ||
          simulated_outcome_field(outcome, "hostname").presence ||
          runtime.fetch("step_workers", {})[run_worker_key(run)].presence ||
          next_worker_hostname
      end

      def worker_storage_key_for(hostname, outcome)
        simulated_outcome_field(outcome, "worker_storage_key").presence ||
          runtime.fetch("worker_storage_keys", {})[hostname].presence ||
          "storage-#{hostname}"
      end

      def run_worker_key(run)
        [ run.step&.kind, run.step&.details.to_h["name"] ].compact.join(":")
      end

      def next_worker_hostname
        workers = Array(runtime["workers"]).presence || [ "simulation-worker" ]
        worker = workers[@worker_index % workers.length]
        @worker_index += 1
        worker.to_s
      end

      def ensure_worker_live!(hostname, storage_key)
        InstanceVersion.find_or_initialize_by(hostname: hostname, role: "worker").tap do |instance|
          instance.version = "simulation"
          instance.started_at ||= Time.current
          instance.last_heartbeat_at = Time.current
          instance.finished_at = nil
          instance.outcome = nil
          instance.save!
        end
        return unless defined?(SolidQueue::Process)

        SolidQueue::Process.find_or_initialize_by(name: "#{hostname}:simulation").tap do |process|
          process.hostname = hostname
          process.kind = "worker"
          process.pid ||= simulated_pid_for_hostname(hostname)
          process.metadata = { "queues" => [ "runs", "merges", Workflow.resume_queue_name(storage_key) ] }
          process.last_heartbeat_at = Time.current
          process.save!
        end
      end

      def simulated_process_kind_for(run)
        return "grader" if run.step&.kind.in?(%w[grader preflight_grader])
        return "agent" if run.step&.agentic?

        "git"
      end

      def simulated_process_command_for(run)
        run.step&.details.to_h["command"].presence || "#{run.step&.kind} simulation"
      end

      def simulated_pid_for(run)
        10_000 + run.id.to_i
      end

      def simulated_pid_for_hostname(hostname)
        20_000 + hostname.hash.abs % 10_000
      end

      def simulated_sha(run)
        Digest::SHA1.hexdigest("#{scenario}:#{run.job_id}:#{run.id}:#{run.step&.kind}")
      end

      def complete?
        return expectations_complete? if expectations.present?

        jobs.all? { |job| success_state_for(job).include?(job.reload.state) }
      end

      def expectations_complete?
        expected_jobs_match? &&
          expected_epics_match? &&
          expected_queues_match? &&
          expected_grader_conclusion_cache_match? &&
          expected_absent_active_steps_match? &&
          expected_events_match? &&
          expected_absent_events_match? &&
          expected_ordered_events_match?
      end

      # Like expected_events_match?, but the required substrings must appear
      # in order (not necessarily consecutively). For proving sequencing --
      # contended landings dispatch in priority order, a pause precedes its
      # resume -- rather than mere occurrence.
      def expected_ordered_events_match?
        required = Array(expectations["events_ordered"])
        return true if required.empty?

        position = 0
        events.each do |line|
          position += 1 if line.include?(required[position].to_s)
          return true if position >= required.length
        end
        false
      end

      # Narrative assertions: required substrings over the tick event log.
      # Lets orchestration scenarios (pause-then-resume, failover, ...) pin
      # that the middle of the story happened, not just the final state --
      # without this, a scenario whose middle silently stops engaging still
      # passes on the final state alone.
      def expected_events_match?
        Array(expectations["events"]).all? do |expected|
          events.any? { |line| line.include?(expected.to_s) }
        end
      end

      def expected_absent_events_match?
        Array(expectations["absent_events"]).none? do |unexpected|
          events.any? { |line| line.include?(unexpected.to_s) }
        end
      end

      def expected_jobs_match?
        expectations.fetch("jobs", {}).all? do |id, expected|
          Array(expected).map(&:to_s).include?(Job.find(id).state)
        end
      end

      def expected_epics_match?
        expectations.fetch("epics", {}).all? do |id, expected|
          Array(expected).map(&:to_s).include?(Epic.find(id).state)
        end
      end

      def expected_queues_match?
        expectations.fetch("queues", {}).all? do |key, expected|
          case key.to_s
          when "active_runs" then matches_queue_state?(active_runs.empty?, expected)
          when "active_work_units" then matches_queue_state?(active_work_units.empty?, expected)
          when "landing" then matches_queue_state?(landing_queue.empty?, expected)
          when "landing_blocked_reasons" then expected_landing_blocked_reasons_match?(expected)
          else raise ArgumentError, "unknown simulation queue expectation #{key.inspect}"
          end
        end
      end

      def expected_absent_active_steps_match?
        unexpected_kinds = Array(expectations["absent_active_steps"]).map(&:to_s)
        return true if unexpected_kinds.empty?

        active_runs.none? { |run| unexpected_kinds.include?(run.step&.kind.to_s) }
      end

      def expected_grader_conclusion_cache_match?
        Array(expectations["grader_conclusion_cache"]).all? do |entry|
          attrs = entry.to_h
          job = Job.find(attrs.fetch("job"))
          GraderConclusionCache.failed?(
            repository: job.repository,
            commit_sha: attrs.fetch("commit_sha"),
            grader_fingerprint: attrs.fetch("grader_fingerprint")
          ) == attrs.fetch("failed")
        end
      end

      def expected_landing_blocked_reasons_match?(expected)
        entries = LandingQueueProcessor.entries(Job.where(id: job_ids)).index_by(&:job_id)
        expected.to_h.all? do |id, reason|
          entries[id.to_i]&.blocked_reason&.fetch(:key, nil).to_s == reason.to_s
        end
      end

      def valid_waiting?
        return expectations_waiting? if expectations.present?

        jobs.all? do |job|
          state = job.reload.state
          success_state_for(job).include?(state) || wait_state_for(job).include?(state)
        end
      end

      def expectations_waiting?
        expected = expectations.fetch("waiting", nil)
        return false if expected.blank?

        Array(expected.fetch("jobs", [])).all? do |job_id|
          expectations.fetch("jobs", {}).fetch(job_id.to_s, []).include?(Job.find(job_id).state)
        end
      end

      def success_state_for(job)
        Array(success_states[job.id.to_s] || success_states[job.slug] || SUCCESS_JOB_STATES)
      end

      def wait_state_for(job)
        Array(wait_states[job.id.to_s] || wait_states[job.slug])
      end

      def no_active_runs?
        active_runs.empty?
      end

      def active_runs
        Run.joins(step: :workflow)
          .where(job_id: job_ids, state: %w[queued running])
          .where(steps: { state: %w[queued running] })
          .where(workflows: { state: %w[queued running] })
          .includes(:job, step: :workflow)
          .to_a
          .reject { |run| queued_run_blocked_by_explicit_solid_queue_state?(run) }
          .reject { |run| run.running? && terminal_spawned_process_for?(run) }
          .reject { |run| run.running? && stale_simulated_worker_evidence?(run) }
      end

      def queued_run_blocked_by_explicit_solid_queue_state?(run)
        return false unless run.queued?

        jobs = explicit_solid_queue_jobs_for_run(run)
        return false if jobs.empty?

        jobs.none? { |job| explicit_solid_queue_job_can_progress?(job) }
      end

      def explicit_solid_queue_jobs_for_run(run)
        return [] unless defined?(SolidQueue::Job)

        SolidQueue::Job.all.select { |job| solid_queue_job_run_id(job) == run.id }
      rescue ActiveRecord::StatementInvalid, NameError
        []
      end

      def explicit_solid_queue_job_can_progress?(job)
        return false if solid_queue_failed?(job)
        return false if dead_resume_queue?(job.queue_name)
        return true if solid_queue_ready?(job)
        return true if solid_queue_scheduled?(job)

        false
      end

      def solid_queue_job_run_id(job)
        payload = job.arguments.is_a?(String) ? JSON.parse(job.arguments) : job.arguments
        payload&.dig("arguments")&.first.to_i
      rescue JSON::ParserError, TypeError
        nil
      end

      def solid_queue_failed?(job)
        defined?(SolidQueue::FailedExecution) && SolidQueue::FailedExecution.where(job_id: job.id).exists?
      end

      def solid_queue_ready?(job)
        defined?(SolidQueue::ReadyExecution) && SolidQueue::ReadyExecution.where(job_id: job.id).exists?
      end

      def solid_queue_scheduled?(job)
        defined?(SolidQueue::ScheduledExecution) && SolidQueue::ScheduledExecution.where(job_id: job.id).exists?
      end

      def dead_resume_queue?(queue_name)
        queue_name = queue_name.to_s
        queue_name.start_with?("resume-") && !InstanceVersion.worker_queue_live?(queue_name)
      end

      def stale_simulated_worker_evidence?(run)
        processes = run.spawned_processes.running.to_a
        return false if processes.empty?

        processes.none? do |process|
          timestamp = process.last_chunk_at || process.started_at
          timestamp.present? && timestamp >= SpawnedProcess::STALE_THRESHOLD.ago
        end
      end

      def active_work_units
        WorkUnit
          .joins(:work_unit_members)
          .where(work_unit_members: { job_id: job_ids })
          .where(state: WorkUnits::Ownership::ACTIVE_STATES)
          .distinct
          .to_a
      end

      def scenario_work_intent_ids
        (
          work_intent_ids +
          WorkUnit.joins(:work_unit_members)
            .where(work_unit_members: { job_id: job_ids })
            .where.not(work_intent_id: nil)
            .pluck(:work_intent_id) +
          WorkUnit.where(workflow_id: Workflow.where(job_id: job_ids).select(:id))
            .where.not(work_intent_id: nil)
            .pluck(:work_intent_id)
        ).compact.uniq
      end

      def pending_auto_retry_attempts
        AutoRetryAttempt
          .where(job_id: job_ids)
          .pending
      end

      def landing_queue
        Job.where(id: job_ids).landing_queue.order(:id).to_a
      end

      def normalize_job_condition(condition)
        condition.is_a?(Hash) ? condition : { "id" => condition }
      end

      def normalize_epic_condition(condition)
        condition.is_a?(Hash) ? condition : { "id" => condition }
      end

      def matches_state?(actual, condition)
        expected = condition["state"] || condition["states"]
        expected.blank? || Array(expected).map(&:to_s).include?(actual)
      end

      def matches_boolean?(actual, expected)
        expected.nil? || actual == expected
      end

      def matches_queue_state?(empty, expected)
        case expected.to_s
        when "empty" then empty
        when "non_empty", "present" then !empty
        else raise ArgumentError, "unknown simulation queue state #{expected.inspect}"
        end
      end

      def simulated_main_sha(repository, attrs)
        Digest::SHA1.hexdigest("#{scenario}:main:#{repository.id}:#{attrs.inspect}")
      end

      def simulated_sha_for(prefix, id)
        Digest::SHA1.hexdigest("#{scenario}:#{prefix}:#{id}")
      end

      def terminal_spawned_process_for?(run)
        run.spawned_processes.where(kind: "agent").where.not(finished_at: nil).exists?
      end

      def jobs
        @jobs ||= Job.where(id: job_ids).includes(:dependencies, :epic, :repository).order(:id).to_a
      end

      def fingerprint
        [
          Job.where(id: job_ids).order(:id).pluck(:id, :state, :pr_number, :branch_name, :updated_at),
          Workflow.where(job_id: job_ids).order(:id).pluck(:id, :state, :updated_at),
          Step.joins(:workflow).where(workflows: { job_id: job_ids }).order(:id).pluck(:id, :state, :updated_at),
          Run.where(job_id: job_ids).order(:id).pluck(:id, :state, :updated_at),
          AutoRetryAttempt.where(job_id: job_ids).order(:id).pluck(:id, :performed_at, :skipped_reason, :scheduled_at, :updated_at),
          WorkIntent.where(scope_type: "job", scope_id: job_ids).order(:id).pluck(:id, :state, :wait_reason, :updated_at),
          WorkUnit.where(scope_type: "job", scope_id: job_ids).order(:id).pluck(:id, :state, :blocked_reason, :updated_at)
        ]
      end

      def success(ticks)
        Result.new(
          scenario: scenario,
          ticks: ticks,
          status: "success",
          events: events,
          stuck_reasons: [],
          wait_reasons: [],
          job_ids: job_ids,
          epic_ids: jobs.filter_map(&:epic_id).uniq,
          work_intent_ids: work_intent_ids
        )
      end

      def waiting(ticks)
        Result.new(
          scenario: scenario,
          ticks: ticks,
          status: "waiting",
          events: events,
          stuck_reasons: [],
          wait_reasons: wait_state,
          job_ids: job_ids,
          epic_ids: jobs.filter_map(&:epic_id).uniq,
          work_intent_ids: work_intent_ids
        )
      end

      def stuck(ticks, reason)
        Result.new(
          scenario: scenario,
          ticks: ticks,
          status: "stuck",
          events: events,
          stuck_reasons: [ reason, *stuck_state ],
          wait_reasons: [],
          job_ids: job_ids,
          epic_ids: jobs.filter_map(&:epic_id).uniq,
          work_intent_ids: work_intent_ids
        )
      end

      def wait_state
        jobs.filter_map do |job|
          state = job.reload.state
          next if success_state_for(job).include?(state)

          workflow = job.latest_workflow
          unit = WorkUnits::Ownership.active_units_for_job(job).first
          "#{job.slug}=#{state} allowed=#{wait_state_for(job).join(",")} latest=#{workflow&.slug}/#{workflow&.state} unit=#{unit&.slug}/#{unit&.state}:#{unit&.blocked_reason}"
        end
      end

      def stuck_state
        jobs.map do |job|
          workflow = job.latest_workflow
          unit = WorkUnits::Ownership.active_units_for_job(job).first
          "#{job.slug}=#{job.state} latest=#{workflow&.slug}/#{workflow&.state} unit=#{unit&.slug}/#{unit&.state}:#{unit&.blocked_reason}"
        end
      end
    end
  end
end
