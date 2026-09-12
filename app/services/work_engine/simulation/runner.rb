require "digest/sha1"
require "ostruct"

module WorkEngine
  module Simulation
    class Runner
      TERMINAL_JOB_STATES = %w[implemented approved landing closed failed no_change_needed].freeze
      SUCCESS_JOB_STATES = %w[implemented approved landing closed no_change_needed].freeze
      DEFAULT_IGNORED_RECONCILER_ISSUE_KINDS = %w[workspace_missing].freeze

      def self.call(...) = new(...).call

      def initialize(
        job_ids:,
        work_intent_ids: [],
        scenario: "database",
        outcomes: {},
        scenario_events: [],
        expectations: {},
        success_states: {},
        wait_states: {},
        auto_retry_failed_jobs: true,
        max_ticks: DEFAULT_MAX_TICKS,
        ignored_reconciler_issue_kinds: DEFAULT_IGNORED_RECONCILER_ISSUE_KINDS
      )
        @job_ids = Array(job_ids).map(&:to_i)
        @work_intent_ids = Array(work_intent_ids).map(&:to_i)
        @scenario = scenario
        @outcomes = outcomes.to_h
        @scenario_events = Array(scenario_events).map.with_index { |event, index| event.to_h.merge("__index" => index, "__fired" => false) }
        @expectations = expectations.to_h
        @success_states = success_states.to_h
        @wait_states = wait_states.to_h
        @auto_retry_failed_jobs = auto_retry_failed_jobs
        @max_ticks = max_ticks.to_i.positive? ? max_ticks.to_i : DEFAULT_MAX_TICKS
        @ignored_reconciler_issue_kinds = Array(ignored_reconciler_issue_kinds).map(&:to_s)
        @events = []
        @run_attempts = Hash.new(0)
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

      attr_reader :job_ids, :work_intent_ids, :scenario, :outcomes, :scenario_events, :expectations, :success_states, :wait_states, :max_ticks, :ignored_reconciler_issue_kinds, :events, :run_attempts

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
        provider = attrs.fetch("provider")
        job.switch_job_provider_setting!(provider.to_s)
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
        attrs["provider"].presence || (value.is_a?(String) ? value : nil) || "codex"
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
        reconcile_result!(tick, WorkEngine::Reconciler.call(source: "simulation:#{scenario}:tick#{tick}", execute_repairs: true))
        work_intent_ids.each do |intent_id|
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

      def reconcile_result!(tick, result)
        result.issues.each do |issue|
          next if ignored_reconciler_issue_kinds.include?(issue.kind)

          events << "tick #{tick}: reconciler #{issue.kind}"
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

        events << "tick #{tick}: landing_queue dispatched #{workflow.slug} #{workflow.trigger_kind}"
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
        run_attempts[run_signature(run)] += 1
        outcome = outcome_for(run)
        events << "tick #{tick}: #{run.slug} #{run.step&.kind} -> #{outcome_label(outcome)}"

        start_run!(run)
        case outcome_status(outcome)
        when "success"
          simulate_side_effects!(run, outcome)
          succeed_run_and_step!(run)
        when "worker_died"
          fail_run!(run, agent_outcome: AutoRetryAttempt::WORKER_DIED_CLASSIFICATION)
        when "failure"
          fail_run!(run, agent_outcome: "error", failure_code: simulated_failure_code(outcome))
        else
          raise ArgumentError, "unknown simulation outcome #{outcome.inspect} for #{run.slug}"
        end
      end

      def start_run!(run)
        workflow = run.workflow
        workflow.start! && workflow.save! if workflow&.may_start?
        step = run.step
        step.start! && step.save! if step&.may_start?
        run.start! && run.save! if run.may_start?
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

      def fail_run!(run, agent_outcome:, failure_code: nil)
        if failure_code.present?
          stamp_simulated_failure_code!(run, failure_code)
        end
        run.agent_outcome = agent_outcome
        run.fail!
        run.save!
        drain_run_failure!(run.reload)
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
        return nil unless outcome.is_a?(Hash)

        outcome["failure_code"].presence || outcome[:failure_code].presence
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
        StepDispatcher.fail_from(step) if step.reload.failed? && step.workflow.reload.may_fail?
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
        member_jobs = train&.member_jobs&.to_a.presence || run.workflow.work_unit&.member_jobs&.to_a || [ run.job ]
        member_jobs.compact.each { |member_job| close_job_if_possible!(member_job, "pr_merged") }
        train&.update!(state: "succeeded", finished_at: Time.current) unless train&.state == "succeeded"
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
        scripted = outcomes.fetch("steps", {})[step_key] ||
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
        "#{run.job_id}:#{run.step&.kind}"
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
          expected_events_match?
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
          .reject { |run| run.running? && terminal_spawned_process_for?(run) }
      end

      def active_work_units
        WorkUnit
          .joins(:work_unit_members)
          .where(work_unit_members: { job_id: job_ids })
          .where(state: WorkUnits::Ownership::ACTIVE_STATES)
          .distinct
          .to_a
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
