require "digest/sha1"
require "fileutils"
require "ostruct"

module WorkEngine
  module Simulation
    class Runner
      TERMINAL_JOB_STATES = %w[implemented approved landing closed failed no_change_needed].freeze
      SUCCESS_JOB_STATES = %w[implemented approved landing closed no_change_needed].freeze
      DEFAULT_IGNORED_RECONCILER_ISSUE_KINDS = %w[workspace_missing].freeze
      SIMULATED_ALTERNATE_PROVIDER = "claude".freeze

      module SideEffects
        class Base
          def initialize(runner)
            @runner = runner
          end

          def apply(run, outcome = nil); end

          private

          attr_reader :runner
        end

        class BranchUpdate < Base
          def apply(run, outcome = nil)
            job = run.job
            sha = runner.send(:simulated_sha, run)
            run.update_columns(head_sha: sha)
            job.update_columns(
              branch_name: job.branch_name.presence || "syrus/simulated-#{job.id}",
              mergeability_head_sha: sha
            )
          end
        end

        class PullRequestOpen < Base
          def apply(run, outcome = nil)
            job = run.job
            sha = job.head_sha.presence || runner.send(:simulated_sha, run)
            run.update_columns(head_sha: sha)
            job.update_columns(
              branch_name: job.branch_name.presence || "syrus/simulated-#{job.id}",
              pr_number: job.pr_number.presence || job.id + 10_000,
              pr_checks_state: "passing",
              pr_checks_sha: sha,
              mergeability_head_sha: sha,
              github_mergeable: true,
              github_mergeable_state: "clean",
              pr_mergeable: true,
              pr_mergeable_checked_at: Time.current,
              mergeability_checked_at: Time.current
            )
          end
        end

        class AutoMerge < Base
          def apply(run, outcome = nil)
            runner.send(:close_job_if_possible!, run.job, "pr_merged")
          end
        end

        class MergeTrainLand < Base
          def apply(run, outcome = nil)
            if runner.send(:simulated_outcome_field, outcome, "unverified_members").present?
              return runner.send(:mark_merge_train_members_unverified!, run, outcome)
            end

            runner.send(:close_merge_train_members!, run)
          end
        end

        class StackAutoRebase < Base
          def apply(run, outcome = nil)
            runner.send(:simulate_stack_auto_rebase!, run, outcome)
          end
        end
      end

      SIDE_EFFECTS_BY_STEP_KIND = {
        "implement" => SideEffects::BranchUpdate,
        "respond" => SideEffects::BranchUpdate,
        "analyze_and_fix" => SideEffects::BranchUpdate,
        "landing_fix" => SideEffects::BranchUpdate,
        "run_skill" => SideEffects::BranchUpdate,
        "pr_open" => SideEffects::PullRequestOpen,
        "auto_merge" => SideEffects::AutoMerge,
        "merge_train_land" => SideEffects::MergeTrainLand,
        "merge_train_land_after_rebase" => SideEffects::MergeTrainLand,
        "stack_auto_rebase" => SideEffects::StackAutoRebase
      }.freeze

      def self.call(...) = new(...).call

      # Set by a `wedged: true` Run fixture: a thread hung inside a live worker.
      WEDGED_RUN_ARTIFACT = "simulation_wedged"

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
        phase_admission_jobs: true,
        global_reconcile: false,
        max_ticks: DEFAULT_MAX_TICKS,
        ignored_reconciler_issue_kinds: DEFAULT_IGNORED_RECONCILER_ISSUE_KINDS,
        tick_observer: nil,
        invariant_assertions: nil,
        git_world: nil
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
        @phase_admission_jobs = phase_admission_jobs
        @pending_phase_admissions = []
        @global_reconcile = global_reconcile
        @max_ticks = max_ticks.to_i.positive? ? max_ticks.to_i : DEFAULT_MAX_TICKS
        @ignored_reconciler_issue_kinds = Array(ignored_reconciler_issue_kinds).map(&:to_s)
        # Called with the tick number at the start of each tick, before the
        # reconciler acts. The Lean oracle conformance spec compares the two
        # reconcilers on every intermediate world through it (DOC-44 Phase 2).
        @tick_observer = tick_observer
        # An InvariantAssertions (or nil): evaluated at the end of every tick,
        # after the engine acted, and once more when the scenario ends.
        @invariant_assertions = invariant_assertions
        @outcome_overrides = []
        @current_tick = 0
        @events = []
        @run_attempts = Hash.new(0)
        @worker_index = 0
        # Scenarios with a `git:` block model branch topology and GitHub PR
        # state (GitWorld); everything else keeps the always-clean answers.
        @git_effects = git_world && GitEffects.new(world: git_world, job_ids: @job_ids, events: @events)
      end

      def call
        with_lock_order_recording { run_ticks }
      end

      def run_ticks
        with_git_world { run_ticks_inside_boundaries }
      end

      def with_git_world(&block)
        return yield unless @git_effects

        @git_effects.install(&block)
      end

      def run_ticks_inside_boundaries
        with_simulated_repository_revisions do
          with_simulated_workspaces do
            with_stubbed_judgment_runner do
              register_runtime_fleet!
              seed_worker_environments!
              @mergeability_poll_cursor = enqueued_job_backlog
              @phase_admission_cursor = enqueued_job_backlog
              max_ticks.times do |tick|
                @current_tick = tick
                before = fingerprint
                apply_scenario_events!(tick)
                @tick_observer&.call(tick)
                reconcile!(tick)
                process_auto_retry_attempts!(tick)
                retry_failed_jobs!(tick)
                wake_jobs!(tick)
                process_landing_queue!(tick)
                answer_mergeability_polls!(tick)
                execute_active_runs!(tick)
                run_due_phase_admissions!(tick)
                if (failures = observe_invariants!(tick)).present?
                  return violated(tick + 1, failures)
                end
                next if retryable_failed_jobs?
                return finish(success(tick + 1), quiescent: false) if complete?
                return finish(waiting(tick + 1), quiescent: true) if no_active_runs? && valid_waiting?

                after = fingerprint
                if after == before && no_active_runs? && !pending_scheduled_events?
                  return finish(stuck(tick + 1, "no state changed"), quiescent: true)
                end
              end

              return finish(waiting(max_ticks), quiescent: true) if valid_waiting? && no_active_runs?

              finish(stuck(max_ticks, "max ticks exhausted"), quiescent: false)
            end
          end
        end
      end

      private

      # Agentic *steps* never reach a real agent here -- the harness decides
      # their outcome from the scenario's `outcomes:`. But some production
      # paths consult an agent inline through Judgment rather than as a Step:
      # PrCommentIngester classifies whether a review comment is actionable
      # that way. Those calls fall back to `RunJob.agent_runner`, which the
      # simulator leaves unset, so Judgment would try to spawn a real agent
      # CLI, fail, and -- because classification fails CLOSED -- silently
      # drop every injected review comment as "not actionable". A scenario
      # that reports PR feedback then goes nowhere, for a reason that has
      # nothing to do with what it is testing.
      #
      # So stub exactly that boundary (the LLM call) and let ingestion,
      # dedup, attribution, watermarking, and dispatch run for real. The
      # verdict is deliberately fixed rather than scenario-configurable:
      # no current scenario tests classification itself, and a knob no
      # fixture sets would just be dead surface.
      def with_stubbed_judgment_runner
        previous = RunJob.agent_runner
        RunJob.agent_runner = ->(**_kwargs) {
          AgentInvocation::Result.new(
            turns: 1, exit_status: 0, timed_out: false, is_error: false,
            outcome: "success", final_text: { actionable: true }.to_json, session_id: nil
          )
        }
        yield
      ensure
        RunJob.agent_runner = previous
      end

      attr_reader :job_ids, :work_intent_ids, :scenario, :outcomes, :scenario_events, :expectations, :runtime, :success_states, :wait_states, :max_ticks, :ignored_reconciler_issue_kinds, :events, :run_attempts

      def with_simulated_repository_revisions
        revisions = runtime.fetch("repository_revisions", {}).to_h
        return yield if revisions.blank?

        previous = RepositoryContent.provider_classes_override
        fallbacks = RepositoryContent.provider_classes
        provider = Class.new do
          include Syrus::Plugin::RepositoryContentProvider

          define_singleton_method(:provider_key) { "simulation_revisions" }
          define_singleton_method(:display_name) { "Simulation revisions" }
          define_singleton_method(:role) { :replica }
          define_singleton_method(:available_for?) { |_repository| true }
          define_singleton_method(:build) { |repository:, user:| new(revisions) }

          define_method(:initialize) { |configured| @configured = configured }
          define_method(:resolve) do |ref, max_age:|
            sha = @configured[ref.to_s]
            raise RepositoryContent::UnknownRevision, "unknown simulated ref #{ref}" unless sha

            RepositoryContent::Revision.new(id: sha, ref: ref, observed_at: Time.current)
          end
          define_method(:tree) { |_revision_id| raise RepositoryContent::Unsupported, "simulation revisions do not provide trees" }
          define_method(:read) { |_revision_id, _path| raise RepositoryContent::Unsupported, "simulation revisions do not provide blobs" }
        end
        RepositoryContent.provider_classes_override = [ provider, *fallbacks ]
        yield
      ensure
        RepositoryContent.provider_classes_override = previous if defined?(previous)
      end

      def apply_scenario_events!(tick)
        scenario_events.each do |event|
          next if event["__fired"] && event.fetch("once", true)
          next unless condition_matches?(event["when"])

          apply_injected_action!(tick, event)
          event["__fired"] = true
        end
      end

      # A fuzzer-injected event (`fuzz:` set) lands at a random tick, where
      # its fixture-level preconditions may not hold -- storage loss for a
      # workflow the simulation never gave a workspace, say. Such an event is
      # recorded as inapplicable rather than aborting the scenario. Scripted
      # events still raise: their preconditions are the fixture's to keep.
      # The action is deliberately not wrapped in a transaction of its own:
      # production calls these services outside one, and a wrapper would make
      # every row they write a lock held across the whole action, which the
      # row-lock order checker rightly rejects.
      def apply_injected_action!(tick, event)
        apply_scenario_action!(tick, event)
      rescue StandardError => e
        raise if event["fuzz"].blank?

        events << "tick #{tick}: fuzz event #{event["name"]} inapplicable: #{e.class}: #{e.message.to_s.truncate(200)}"
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
          when "tick" then tick_condition_matches?(value)
          when "pull_request" then git_effects!("pull_request").pull_request_condition_matches?(value)
          else raise ArgumentError, "unknown simulation event condition #{key.inspect}"
          end
        end
      end

      # `tick: 7` fires on exactly tick 7; `tick: { at_least: 7 }` (usually
      # with `once: true`) on the first tick from 7 on. The fuzzer schedules
      # its perturbations this way.
      def tick_condition_matches?(condition)
        return @current_tick == condition.to_i unless condition.is_a?(Hash)

        at_least = condition["at_least"] || condition[:at_least]
        at_most = condition["at_most"] || condition[:at_most]
        (at_least.nil? || @current_tick >= at_least.to_i) && (at_most.nil? || @current_tick <= at_most.to_i)
      end

      # An unfired event scheduled purely by tick for a later tick. A world
      # that has gone quiet is not stuck yet while one is still due: the
      # event is the external actor the scenario said would come.
      def pending_scheduled_events?
        scenario_events.any? do |event|
          next false if event["__fired"]

          condition = event["when"].to_h
          next false unless condition.keys.map(&:to_s) == [ "tick" ]

          value = condition.values.first
          due = value.is_a?(Hash) ? (value["at_least"] || value[:at_least]).to_i : value.to_i
          due > @current_tick
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
          when "landing_blocked_reasons" then expected_landing_blocked_reasons_match?(value)
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
          when "repair_worker_environment" then repair_worker_environment!(value)
          when "lose_storage" then lose_storage!(value)
          when "cycle_queued_run_job" then cycle_queued_run_job!(value)
          when "reroute_host_rejected_run" then reroute_host_rejected_run!(value)
          when "wake" then wake_jobs_event!(tick, value)
          when "inject_outcome" then inject_outcome!(value)
          when "pause_work" then pause_work!(value)
          when "unpause_work" then unpause_work!(value)
          when "rewrite_stack_parent" then rewrite_stack_parent!(tick, value)
          when "advance_branch" then git_effects!(key).advance_branch!(value)
          when "pr_becomes_dirty" then git_effects!(key).pr_becomes_dirty!(value)
          when "pr_mergeability_unknown" then git_effects!(key).pr_mergeability_unknown!(value)
          when "rewrite_branch" then git_effects!(key).rewrite_branch!(value)
          when "force_push_branch" then git_effects!(key).force_push_branch!(value)
          when "delete_branch" then git_effects!(key).delete_branch!(value)
          else raise ArgumentError, "unknown simulation event action #{key.inspect}"
          end
        end
      end

      # `wake: all` or `wake: [job_id, ...]` models the real wake a production
      # event would have performed, for scenarios that legitimately need one
      # after tick 0.
      def wake_jobs_event!(tick, value)
        explicit_wake_ticks << tick
        wake_all_jobs!(only: value == "all" ? nil : value)
      end

      # Overrides the scripted outcome of the next Run of `job` (optionally of
      # one step kind) to execute: a worker dying under it (`worker_died`), a
      # transient failure (`{ status: failure, failure_code: timeout }`), and
      # so on. Takes `{ job:, step:, outcome:, count: }`; `count` defaults to
      # one Run.
      def inject_outcome!(value)
        attrs = value.to_h
        @outcome_overrides << {
          "job_id" => attrs.fetch("job").to_i,
          "step" => attrs["step"].presence&.to_s,
          "outcome" => attrs.fetch("outcome"),
          "remaining" => attrs.fetch("count", 1).to_i
        }
        events << "armed outcome #{outcome_label(attrs.fetch("outcome"))} for the next #{attrs["step"].presence || "run"} of job #{attrs.fetch("job")}"
      end

      # The operator's pause and unpause (JobManualPause, the same service the
      # Job page and the API call).
      def pause_work!(value)
        job = Job.find(value.is_a?(Hash) ? value.fetch("job") : value)
        if !job.open? || job.manual_paused?
          events << "pause #{job.slug} skipped: #{job.manual_paused? ? "already paused" : job.state}"
          return
        end

        JobManualPause.pause!(job, by_user: job.user)
        events << "operator paused #{job.slug}"
      end

      def unpause_work!(value)
        job = Job.find(value.is_a?(Hash) ? value.fetch("job") : value)
        unless job.manual_paused?
          events << "unpause #{job.slug} skipped: not paused"
          return
        end

        JobManualPause.unpause!(job)
        events << "operator unpaused #{job.slug}"
      end

      def git_effects!(name)
        @git_effects || raise(ArgumentError, "simulation #{name} needs the scenario's git: block")
      end

      # A stacked child's parent branch is rewritten (rebased and
      # force-pushed) while the child works. The parent's recorded head moves,
      # and the child's next publication meets the StackBaseFreshness barrier
      # the real pr_open step runs: the parent did not hold still, so it
      # fails with awaiting_stable_base. Takes the child's fixture key.
      def rewrite_stack_parent!(tick, value)
        child = Job.find(value.is_a?(Hash) ? value.fetch("job") : value)
        # With a git world the parent really moves, and the child's pr_open
        # meets the real StackBaseFreshness barrier instead of an injected
        # failure.
        return @git_effects.rewrite_stack_parent!(child) if @git_effects

        parent = child.parent_job
        unless parent
          events << "rewrite stack parent of #{child.slug} skipped: no parent"
          return
        end

        parent.update_columns(mergeability_head_sha: simulated_sha_for("rewritten-#{tick}", parent.id), updated_at: Time.current)
        @outcome_overrides << {
          "job_id" => child.id,
          "step" => "pr_open",
          "outcome" => {
            "status" => "failure",
            "failure_code" => "awaiting_stable_base",
            "error_message" => "stack parent #{parent.branch_name} moved during publication"
          },
          "remaining" => 1
        }
        events << "rewrote stack parent #{parent.slug} under #{child.slug}"
      end

      def approve_job!(job_id)
        job = Job.find(job_id)
        # An approval the Job's state refuses is no operator action at all:
        # saving anyway would touch the Job and reset the stall clocks the
        # reconciler reads, which no real refused click does.
        return unless job.may_approve?

        job.approve!(via: "operator")
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
        return unless job.may_force_fail?

        job.force_fail!
        job.save!
      end

      def set_pr_checks!(value)
        attrs = value.to_h
        job = Job.find(attrs.fetch("job"))
        @git_effects&.set_pr_checks!(job, attrs.fetch("state"))
        job.update!(
          pr_checks_state: attrs.fetch("state"),
          pr_checks_sha: attrs["sha"] || job.mergeability_head_sha || job.head_sha
        )
      end

      def advance_main!(value)
        attrs = value.is_a?(Hash) ? value : { "sha" => value }
        attrs = attrs.merge("sha" => @git_effects.advance_main!(attrs)) if @git_effects
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
        unless workflow
          events << "deferred phase resume for #{job.slug}: no workflow"
          return
        end
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
        # switch_job_provider_setting! finishes by calling
        # ProviderAvailabilityWakeup, which only *enqueues*
        # WorkflowPhaseAdmissionJob. There are no queue workers here, so admit
        # the repinned workflows inline -- same stand-in as
        # resume_blocked_workflows! below.
        resumed = resume_blocked_workflows!(WorkUnits::Gates::ProviderAvailability::REASON, provider: provider)
        events << "switched #{job.slug} provider to #{provider}, #{resumed} deferred phases resumed"
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
        @git_effects&.merge_externally!(job) if merged
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
          job.reload(lock: true)
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
        resumed = resume_blocked_workflows!("main_branch_health")
        events << "healed main branch health, #{resumed} deferred phases resumed"
      end

      # `runtime.worker_environment` seeds live workers with an environment
      # smoke report (WorkerEnvironmentSmoke) before the first tick, so the
      # real RunQueueResolver sees which checks each worker fails:
      #
      #   runtime:
      #     worker_environment:
      #       simulation-worker:
      #         failed: [mysql_client]
      def seed_worker_environments!
        runtime.fetch("worker_environment", {}).to_h.each do |hostname, config|
          hostname = hostname.to_s
          ensure_worker_live!(hostname, worker_storage_key_for(hostname, nil))
          record_worker_environment!(hostname, Array(config.to_h["failed"]).map(&:to_s))
        end
      end

      # The operator fixing a worker's toolchain: its next smoke report passes.
      # Takes a hostname or `{ hostname: }`.
      # The repaired report passes every check the worker was known to fail --
      # its own earlier smoke failures and what failed installs found missing
      # there (WorkerEnvironmentGap) -- which is how a real smoke report clears
      # both.
      def repair_worker_environment!(value)
        hostname = (value.is_a?(Hash) ? value.fetch("hostname") : value).to_s
        previously_failed = InstanceVersion.where(hostname: hostname, role: "worker").flat_map do |instance|
          WorkerEnvironmentSmoke.failed_checks(instance.capability_diagnostics.to_h[WorkerEnvironmentSmoke::DIAGNOSTIC_KEY])
        end
        gap_checks = WorkerEnvironmentGap.uncleared.where(hostname: hostname).map(&:check_name)
        record_worker_environment!(hostname, [], passed: previously_failed | gap_checks)
        events << "repaired worker environment on #{hostname}"
      end

      def record_worker_environment!(hostname, failed, passed: [])
        checks = passed.to_h { |name| [ name, { "status" => WorkerEnvironmentSmoke::PASSED, "essential" => false } ] }
          .merge(failed.to_h { |name| [ name, { "status" => WorkerEnvironmentSmoke::FAILED, "reason" => "simulated #{name} failure", "essential" => false } ] })
        report = {
          "version" => WorkerEnvironmentSmoke::REPORT_VERSION,
          "status" => failed.empty? ? WorkerEnvironmentSmoke::PASSED : WorkerEnvironmentSmoke::DEGRADED,
          "observed_at" => Time.current.utc.iso8601(6),
          "failed" => failed.sort,
          "checks" => checks
        }
        InstanceVersion.where(hostname: hostname, role: "worker").find_each do |instance|
          diagnostics = instance.capability_diagnostics.is_a?(Hash) ? instance.capability_diagnostics : {}
          instance.update!(capability_diagnostics: diagnostics.merge(WorkerEnvironmentSmoke::DIAGNOSTIC_KEY => report))
        end
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

      def lose_storage!(value)
        attrs = value.is_a?(Hash) ? value : { "job" => value }
        workflow = Job.find(attrs.fetch("job")).latest_workflow
        remove_simulated_workspace!(workflow)
        WorkflowWorkspaceLifecycle.clear_routing_affinity!(
          workflow,
          actor: "simulation",
          reason: attrs.fetch("reason", "simulated worker storage loss")
        )
        events << "lost workspace storage for workflow #{workflow.id}"
      end

      def cycle_queued_run_job!(value)
        attrs = value.to_h
        run = queued_run_for_event!(attrs)
        workflow = run.workflow
        now = Time.current
        queue_name = attrs["queue_name"].presence || run.resume_worker_queue || "runs"
        scheduled_at = attrs["scheduled_at"].present? ? Time.zone.parse(attrs.fetch("scheduled_at")) : now + 30.seconds

        if queue_name.to_s.start_with?("resume-")
          ensure_worker_live!(
            attrs["hostname"].presence || workflow&.worker_hostname.presence || "simulation-worker",
            attrs["worker_storage_key"].presence || workflow&.worker_storage_key.presence || queue_name.to_s.delete_prefix("resume-")
          )
        end
        delete_solid_queue_jobs_for_run!(run)
        queue_job = SolidQueue::Job.create!(
          class_name: "RunJob",
          queue_name: queue_name,
          priority: attrs.fetch("priority", 10),
          arguments: { "arguments" => [ run.id ] },
          scheduled_at: scheduled_at,
          created_at: now,
          updated_at: now
        )
        SolidQueue::ScheduledExecution.find_or_create_by!(job: queue_job) do |execution|
          execution.priority = queue_job.priority
          execution.queue_name = queue_job.queue_name
          execution.scheduled_at = scheduled_at
          execution.created_at = now
        end
        workflow.update_columns(updated_at: now) if workflow
        events << "cycled RunJob for #{run.slug} on #{queue_name}"
      end

      def reroute_host_rejected_run!(value)
        attrs = value.to_h
        run = queued_run_for_event!(attrs)
        run.job.repository.update!(distributed_workflow_dag_enabled: true)
        run.step.update!(placement_policy: Step::PlacementPolicy::IMMUTABLE_SOURCE_CHECKOUT)
        rejecting_hostname = attrs.fetch("rejecting_hostname")
        target_hostname = attrs.fetch("target_hostname")
        shared_storage_key = attrs.fetch("worker_storage_key", "shared-storage")
        ensure_worker_live!(rejecting_hostname, shared_storage_key)
        ensure_worker_live!(target_hostname, shared_storage_key)
        record_simulated_worker_health!(rejecting_hostname, shared_storage_key, critical: true)
        record_simulated_worker_health!(target_hostname, shared_storage_key, critical: false)
        admission = RunHostAdmission::Decision.new(
          action: "defer",
          reason: attrs.fetch("reason", "local_worker_pressure_critical"),
          delay: RunHostAdmission::RETRY_DELAY,
          details: { "hostname" => rejecting_hostname, "worker_storage_key" => shared_storage_key }
        )
        routing = DistributedRunAdmissionRouter.call(run: run, admission: admission)
        raise "simulation expected a worker-specific reroute, got #{routing.inspect}" unless routing.reroute?

        delete_solid_queue_jobs_for_run!(run)
        queue_job = SolidQueue::Job.create!(
          class_name: "RunJob",
          queue_name: routing.queue_name,
          priority: run.solid_queue_priority,
          arguments: { "arguments" => [ run.id ] },
          scheduled_at: Time.current,
          created_at: Time.current,
          updated_at: Time.current
        )
        events << "admission rerouted #{run.step.kind}:#{run.step.details.to_h['name']} from #{rejecting_hostname} to #{routing.details['routed_worker']} on #{routing.queue_name}"
      end

      def record_simulated_worker_health!(hostname, storage_key, critical:)
        WorkerHostHealthSample.create!(
          hostname: hostname,
          role: "worker",
          version: "simulation",
          worker_storage_key: storage_key,
          observed_at: Time.current,
          cpu_used_percent: 5,
          memory_used_percent: 10,
          data_root_used_percent: 10,
          cpu_pressure_some: critical ? 55 : 0,
          cpu_pressure_full: critical ? 6 : 0,
          raw_metrics: {}
        )
      end

      def simulation_repository
        jobs.first&.repository
      end

      def record_simulated_base_health!(job, base_sha)
        BaseBranchHealth.checks.create!(
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
        Syrus::PluginRegistry.register_direct(:agent_provider, provider_class)
        provider
      end

      def simulation_user
        jobs.first&.user
      end

      def record_simulated_provider_usage!(provider, status:)
        user = simulation_user
        provider_account = user.default_provider_account(provider)
        ProviderAvailabilityEvidence.create!(
          user: user,
          provider: provider.to_s,
          account_id: provider_account&.public_id,
          status: status,
          source: "simulation",
          observed_at: Time.current
        )
        App::ProviderAvailability.clear_cache!(user: user, provider: provider.to_s)
        ProviderCircuitBreaker.clear_read_cache!
      end

      def reconcile!(tick)
        if global_reconcile?
          reconcile_result!(tick, WorkEngine::Reconciler.call(
            source: "simulation:#{scenario}:tick#{tick}",
            execute_repairs: true,
            skipped_repair_issue_kinds: ignored_reconciler_issue_kinds
          ))
        else
          job_ids.each do |job_id|
            reconcile_result!(
              tick,
              WorkEngine::Reconciler.call(
                source: "simulation:#{scenario}:tick#{tick}:job#{job_id}",
                job_id: job_id,
                execute_repairs: true,
                skipped_repair_issue_kinds: ignored_reconciler_issue_kinds
              )
            )
          end
        end
        uncovered_scenario_work_intent_ids.each do |intent_id|
          reconcile_result!(
            tick,
            WorkEngine::Reconciler.call(
              source: "simulation:#{scenario}:tick#{tick}:#{intent_id}",
              work_intent_id: intent_id,
              execute_repairs: true,
              skipped_repair_issue_kinds: ignored_reconciler_issue_kinds
            )
          )
        end
      end

      # A job-scoped reconciliation already includes intents whose units
      # contain that job. Re-running the same reconciler for each of those
      # intents made multi-job simulations scan the same workflows and runs
      # twice on every tick. Direct intents without a unit still need their
      # intent-scoped pass so missing-runtime repairs retain their exact scope.
      def uncovered_scenario_work_intent_ids
        intent_ids = scenario_work_intent_ids
        return intent_ids if global_reconcile? || intent_ids.empty?

        member_ids = WorkIntent
          .where(id: intent_ids)
          .joins(work_units: :work_unit_members)
          .where(work_unit_members: { job_id: job_ids })
          .distinct
          .pluck(:id)

        intent_ids - member_ids
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

      # Production only wakes a Job when something happens to it: a dependency
      # closes, an Epic releases its children, a landing defers, an operator
      # acts. There are a couple of dozen such call sites, and
      # Maintenance::ReleaseStuckEpicBlockedJobs exists purely to repair Jobs
      # that were never woken -- so a missing wake is a real and recurring
      # production bug.
      #
      # Waking every open Job on every tick hid that entire class: a scenario
      # progressed whether or not the code under test actually woke anything,
      # and a `LockConflict` here was retried next tick where production simply
      # loses the wake. Tick 0 still wakes, because a scenario seeds Jobs that
      # were "just created" and something has to start them; after that a
      # Workflow moves only if the engine, a reconciler repair, or an explicit
      # `wake` event moves it.
      def wake_jobs!(tick)
        return unless tick.zero? || explicit_wake_ticks.include?(tick)

        wake_all_jobs!
      end

      def wake_all_jobs!(only: nil)
        jobs.each do |job|
          next if only.present? && !Array(only).map(&:to_s).include?(job.id.to_s)

          job.reload
          job.start_pending_workflows_if_dependencies_satisfied! if job.open?
        rescue WorkUnits::Launcher::LockConflict => e
          events << "wakeup #{job.slug}: active lock #{e.lock_key}"
        end
      end

      def explicit_wake_ticks
        @explicit_wake_ticks ||= Set.new
      end

      def process_landing_queue!(tick)
        workflow = LandingQueueProcessor.new.call
        return unless workflow
        return unless job_ids.include?(workflow.job_id)

        events << "tick #{tick}: landing_queue dispatched #{workflow.slug} #{workflow.trigger_kind} for #{workflow.job.title}"

      rescue WorkUnits::Launcher::LockConflict => e
        events << "tick #{tick}: landing_queue active lock #{e.lock_key}"
      end

      # The landing queue refuses to land on stale mergeability evidence and
      # enqueues PollMergeStateJob instead, which in production re-reads the
      # PR from GitHub within seconds and wakes the queue. There are no queue
      # workers here, so without a stand-in a Job whose evidence went stale
      # (or was never recorded, as for a seeded mid-landing Job that falls
      # back to approved) waits forever on a poll that never runs. Answer each
      # poll enqueued for a scenario Job with GitHub's reply as the injected
      # fact: the PR is cleanly mergeable at its recorded head.
      # A blocked start (an Epic sibling's turn, a gate) or a provider
      # backoff schedules a WorkflowPhaseAdmissionJob to look again later.
      # There are no queue workers here, so the runner performs the scheduled
      # admissions itself once the world is quiet -- the backoff has elapsed
      # when nothing else is moving. Without this, a transient failure the
      # dispatcher deferred never resumes. Scenarios that model the wake
      # explicitly with `resume_deferred_phase` events can opt out with
      # `runner: { phase_admission_jobs: false }`.
      def run_due_phase_admissions!(tick)
        return unless @phase_admission_jobs

        adapter = ActiveJob::Base.queue_adapter
        if adapter.respond_to?(:enqueued_jobs)
          fresh = adapter.enqueued_jobs.drop(@phase_admission_cursor)
          @phase_admission_cursor = adapter.enqueued_jobs.size
          fresh.each do |entry|
            next unless entry[:job] == WorkflowPhaseAdmissionJob

            args = Array(entry[:args]).first(2)
            @pending_phase_admissions << args unless @pending_phase_admissions.include?(args)
          end
        end
        return if @pending_phase_admissions.empty? || !no_active_runs?

        scenario_workflow_ids = Workflow.where(job_id: job_ids).pluck(:id).to_set
        due = @pending_phase_admissions.select { |workflow_id, _| scenario_workflow_ids.include?(workflow_id.to_i) }
        @pending_phase_admissions -= due
        # An admission that already ran against this exact world state (only
        # timestamps differ) would decide the same again: production would
        # keep polling a gate that waits on something outside the scenario,
        # such as a main-branch health check. Running it once per state keeps
        # that wait from looking like progress, so the world can go quiet.
        state = state_fingerprint
        @phase_admission_states ||= {}
        unchanged, due = due.partition { |args| @phase_admission_states[args.compact] == state }
        @pending_phase_admissions.concat(unchanged)
        due.each do |workflow_id, step_id|
          @phase_admission_states[[ workflow_id, step_id ].compact] = state
          fast_forward_step_retry_not_before!(step_id)
          WorkflowPhaseAdmissionJob.new.perform(*[ workflow_id, step_id ].compact)
          events << "tick #{tick}: phase admission ran for workflow #{workflow_id}"
        end
      end

      # Simulated time does not pass, so a Step reopened behind a provider
      # backoff (`retry_not_before`) would never become due. The world is
      # quiet when admissions run, which is when the wait would elapse in
      # production; move the not-before to now, as auto-retry attempts are
      # fast-forwarded.
      def fast_forward_step_retry_not_before!(step_id)
        step = Step.find_by(id: step_id)
        return unless step

        not_before = step.details.to_h[StepDispatcher::RETRY_NOT_BEFORE_DETAIL]
        return if not_before.blank? || Time.zone.parse(not_before.to_s) <= Time.current

        step.update!(details: step.details.to_h.merge(StepDispatcher::RETRY_NOT_BEFORE_DETAIL => Time.current.iso8601))
      end

      def enqueued_job_backlog
        adapter = ActiveJob::Base.queue_adapter
        adapter.respond_to?(:enqueued_jobs) ? adapter.enqueued_jobs.size : 0
      end

      def answer_mergeability_polls!(tick)
        adapter = ActiveJob::Base.queue_adapter
        return unless adapter.respond_to?(:enqueued_jobs)

        fresh = adapter.enqueued_jobs.drop(@mergeability_poll_cursor)
        @mergeability_poll_cursor = adapter.enqueued_jobs.size
        polled_ids = fresh.filter_map { |entry| Array(entry[:args]).first.to_i if entry[:job] == PollMergeStateJob } & job_ids
        # With a git world the poll itself runs for real against the modeled
        # PR (see GitEffects#poll_merge_states!).
        if @git_effects
          return @git_effects.poll_merge_states!(tick, requested_ids: polled_ids.uniq, state_fingerprint: state_fingerprint)
        end

        Job.where(id: polled_ids.uniq).find_each do |job|
          job.update_columns(
            mergeability_checked_at: Time.current,
            github_mergeable: true,
            github_mergeable_state: "clean",
            pr_mergeable: true,
            pr_mergeable_checked_at: Time.current,
            updated_at: Time.current
          )
          events << "tick #{tick}: mergeability poll answered clean for #{job.slug}"
        end
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
        if next_attempt.scheduled_at&.future? && fast_forward_auto_retry_attempt?(next_attempt)
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
          effect = simulate_side_effects!(run, outcome)
          if effect.is_a?(GitEffects::Failure)
            finish_simulated_processes!(run, "failed")
            fail_run!(run, agent_outcome: "error", failure_code: effect.failure_code,
                           error_message: effect.error_message, problem_code: effect.problem_code)
          elsif effect == :failed
            finish_simulated_processes!(run, "failed")
            fail_run!(run, agent_outcome: "error",
                           failure_code: simulated_failure_code(outcome),
                           error_message: simulated_outcome_field(outcome, "error_message"),
                           error_class: simulated_outcome_field(outcome, "error_class"),
                           problem_code: simulated_outcome_field(outcome, "problem_code"),
                           problem_evidence: simulated_outcome_field(outcome, "problem_evidence"))
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
                         error_class: simulated_outcome_field(outcome, "error_class"),
                         problem_code: simulated_outcome_field(outcome, "problem_code"),
                         problem_evidence: simulated_outcome_field(outcome, "problem_evidence"))
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

      def fail_run!(run, agent_outcome:, failure_code: nil, error_message: nil, error_class: nil, problem_code: nil,
                    problem_evidence: nil)
        if failure_code.present?
          stamp_simulated_failure_code!(run, failure_code)
        end
        if error_message.present? || error_class.present? || problem_code.present?
          record_simulated_diagnostic!(run, error_class: error_class, error_message: error_message,
                                            problem_code: problem_code, problem_evidence: problem_evidence)
        end
        run.agent_outcome = agent_outcome
        run.fail!
        run.save!
        drain_run_failure!(run.reload)
      end

      # Gives the failed run the diagnostic a real handler would have
      # captured, so reason-text matching downstream (transient blockers,
      # quota resets, failure_reason_for) reads the injected fact instead
      # of a generic message. `problem_code` is the Problem the real handler
      # would have declared (Steps::Base#fail_with!), which the run
      # classifiers read before any of that text.
      def record_simulated_diagnostic!(run, error_class:, error_message:, problem_code: nil, problem_evidence: nil)
        RunDiagnostic.create!(
          run: run,
          error_class: error_class.presence || "Steps::Base::StepFailed",
          error_message: error_message.presence || "simulated failure",
          problem_code: problem_code.presence,
          problem_evidence: problem_evidence.presence&.to_h
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
        # Run#fail! already propagates on commit (Runs::LifecyclePropagation
        # fails the Step and dispatches). When that dispatch reopened the Step
        # -- the provider-transient backoff, an infrastructure rerun -- failing
        # it a second time here undid the reopen and then hard-failed the
        # Workflow production keeps running, so every transient failure the
        # simulator injected looked fatal. Only a Step propagation left alone
        # is still drained here.
        return if step.queued? || step.succeeded? || step.skipped?
        # Runs::LifecyclePropagation already scheduled an in-place retry of
        # this step and deliberately left it unfailed; failing it here would
        # model a cascade production never performs.
        return if in_place_step_retry_scheduled?(run)

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

      def in_place_step_retry_scheduled?(run)
        AutoRetryAttempt.pending.where(
          run_id: run.id,
          retry_kind: "failed_step",
          failure_classification: AutoRetryAttempt::IN_PLACE_STEP_CLASSIFICATIONS
        ).exists?
      end

      def step_fail_policy(step)
        Step::Kind.fetch(step.kind).fail_policy
      rescue ArgumentError
        :fail_workflow
      end

      def simulate_side_effects!(run, outcome = nil)
        if @git_effects&.handles?(run.step&.kind)
          effect = @git_effects.apply(run, outcome)
          return effect if effect
          return unless GitEffects::CHAINED_STEP_KINDS.include?(run.step.kind)
        end

        SIDE_EFFECTS_BY_STEP_KIND[run.step&.kind]&.new(self)&.apply(run, outcome)
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

        train.update!(integration_sha: simulated_sha_for("merge-train-integration", train.id)) if train.integration_sha.blank?

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
          "merge_train: landed integration #{train.integration_sha.to_s.first(9)} but could not verify #{slugs.size}/#{train.members.size} member(s): #{slugs.join(', ')}; landing succeeded and unresolved members remain open for reconciliation"
        members.each_with_index do |member, index|
          # The real merge-train build records each member's rebased commits.
          # Preserve that evidence in the simulation so the post-land
          # reconciler can repair bookkeeping without publishing the already
          # merged integration a second time.
          LandedCommit.find_or_create_by!(
            landable: member.job,
            sha: simulated_sha_for("merge-train-member", "#{train.id}-#{member.job_id}"),
            kind: "implementation"
          ) { |commit| commit.position = index }
          member.update!(state: "failed", reason: reason.truncate(500))
          LandingFailureHandler.call(job: member.job, reason: reason, run: run) if member.job.landing?
        end
        train.update!(state: "succeeded", failure_reason: nil, finished_at: Time.current)
        run.workflow.set_artifact!(
          Steps::MergeTrainLand::MEMBER_RECONCILIATION_ARTIFACT,
          {
            "status" => "partial",
            "integration_sha" => train.integration_sha,
            "member_count" => train.members.size,
            "unresolved_job_ids" => members.map(&:job_id)
          }
        )
        nil
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
        overridden = take_outcome_override(run)
        return overridden unless overridden.nil?

        step_key = "#{run.job_id}:#{run.step&.kind}"
        named_step_key = "#{step_key}:#{run.step&.details.to_h["name"]}" if run.step&.details.to_h["name"].present?
        named_kind_key = "#{run.step&.kind}:#{run.step&.details.to_h["name"]}" if run.step&.details.to_h["name"].present?
        scripted = outcomes.fetch("steps", {})[step_key] ||
          outcomes.fetch("steps", {})[named_step_key] ||
          outcomes.fetch("steps", {})[named_kind_key] ||
          outcomes.fetch("steps", {})[run.step&.kind.to_s]
        sequence_outcome(scripted, run) || outcomes.fetch("default", "success")
      end

      def take_outcome_override(run)
        override = @outcome_overrides.find do |entry|
          entry["job_id"] == run.job_id && (entry["step"].nil? || entry["step"] == run.step&.kind.to_s)
        end
        return nil unless override

        override["remaining"] -= 1
        @outcome_overrides.delete(override) unless override["remaining"].positive?
        override["outcome"]
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
        hostname = simulated_outcome_field(outcome, "worker").presence ||
          simulated_outcome_field(outcome, "hostname").presence ||
          runtime.fetch("step_workers", {})[run_worker_key(run)].presence ||
          next_worker_hostname
        avoid_unprovisioned_worker(run, hostname)
      end

      # A worker recorded as missing a dependency this Run's install needs
      # hands the Run back (RunJob#hand_back_incapable_run?); the simulated
      # fleet's next provisioned worker picks it up, as the shared queue would.
      def avoid_unprovisioned_worker(run, hostname)
        return hostname unless RunQueueResolver.worker_environment_blocks?(run: run, hostname: hostname)

        workers = Array(runtime["workers"]).map(&:to_s)
        alternative = workers.find { |worker| !RunQueueResolver.worker_environment_blocks?(run: run, hostname: worker) }
        return hostname unless alternative

        events << "placement avoided #{run.slug} #{run.step&.kind} on #{hostname} (worker environment missing); ran on #{alternative}"
        alternative
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

      # A declared `runtime.workers` fleet exists before any work lands on it,
      # as a real one does: placement decisions (RunQueueResolver) see every
      # worker from the first tick, not only the ones a Run already touched.
      def register_runtime_fleet!
        Array(runtime["workers"]).map(&:to_s).each do |hostname|
          ensure_worker_live!(hostname, worker_storage_key_for(hostname, nil))
        end
      end

      def ensure_worker_live!(hostname, storage_key)
        InstanceVersion.find_or_initialize_by(hostname: hostname, role: "worker").tap do |instance|
          instance.version = "simulation"
          instance.started_at ||= Time.current
          instance.last_heartbeat_at = Time.current
          instance.finished_at = nil
          instance.outcome = nil
          instance.capabilities = { "os" => [ "linux" ], "arch" => [ "amd64" ] }
          instance.save!
        end
        return unless defined?(SolidQueue::Process)

        SolidQueue::Process.find_or_initialize_by(name: "#{hostname}:simulation").tap do |process|
          process.hostname = hostname
          process.kind = "worker"
          process.pid ||= simulated_pid_for_hostname(hostname)
          process.metadata = {
            "queues" => [
              "runs", "merges", Workflow.resume_queue_name(storage_key),
              WorkerStorageIdentity.dispatch_queue_name(hostname: hostname)
            ],
            "capabilities" => { "os" => [ "linux" ], "arch" => [ "amd64" ] }
          }
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
          expected_merge_train_counts_match? &&
          expected_queues_match? &&
          expected_workspace_evidence_match? &&
          expected_workflow_artifacts_match? &&
          expected_run_evidence_match? &&
          expected_grader_conclusion_cache_match? &&
          expected_absent_active_steps_match? &&
          expected_events_match? &&
          expected_absent_events_match? &&
          expected_ordered_events_match? &&
          expected_git_match?
      end

      def expected_git_match?
        return true if expectations["git"].blank?

        git_effects!("expect.git").expectations_match?(expectations["git"])
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

      # `merge_train_counts: { epic_key: n }`: how many MergeTrains the Epic
      # ever had -- pins that a failed train was not relaunched.
      def expected_merge_train_counts_match?
        expectations.fetch("merge_train_counts", {}).all? do |id, expected|
          MergeTrain.where(epic_id: id).count == expected.to_i
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

      def expected_workspace_evidence_match?
        Array(expectations["workspace_events"]).all? do |entry|
          attrs = entry.to_h
          scope = WorkflowWorkspaceEvent.where(workflow_id: Workflow.where(job_id: attrs.fetch("job")))
          scope = scope.where(event_type: attrs["event_type"]) if attrs["event_type"].present?
          scope = scope.where(actor: attrs["actor"]) if attrs["actor"].present?
          scope.exists?
        end
      end

      def expected_run_evidence_match?
        Array(expectations["run_evidence"]).all? do |entry|
          attrs = entry.to_h
          scope = Run.where(job_id: attrs.fetch("job"))
          scope = scope.joins(:step).where(steps: { kind: attrs["step"] }) if attrs["step"].present?
          scope = scope.where(agent_outcome: attrs["agent_outcome"]) if attrs["agent_outcome"].present?
          if attrs["classification"].present?
            scope = scope.joins(:run_failure_classification)
              .where(run_failure_classifications: { classification: attrs["classification"] })
          end
          scope.exists?
        end
      end

      def expected_workflow_artifacts_match?
        Array(expectations["workflow_artifacts"]).all? do |entry|
          attrs = entry.to_h
          workflows = Workflow.where(job_id: attrs.fetch("job"))
          workflows.any? do |workflow|
            attrs.fetch("values", {}).all? { |key, value| expected_value_matches?(workflow.artifact(key), value) }
          end
        end
      end

      def expected_value_matches?(actual, expected)
        return expected.all? { |key, value| expected_value_matches?(actual.to_h[key.to_s] || actual.to_h[key.to_sym], value) } if expected.is_a?(Hash)

        actual.to_s == expected.to_s
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

      def fast_forward_auto_retry_attempt?(attempt)
        return true if no_active_runs?

        worker_died_step_retry_waiting_on_replacement_run?(attempt)
      end

      def worker_died_step_retry_waiting_on_replacement_run?(attempt)
        return false unless attempt.retry_kind == "failed_step"
        return false unless attempt.failure_classification == AutoRetryAttempt::WORKER_DIED_CLASSIFICATION

        step = attempt.run&.step
        step&.running? && attempt.workflow&.running?
      end

      def active_runs
        Run.joins(step: :workflow)
          .where(job_id: job_ids, state: %w[queued running])
          .where(steps: { state: %w[queued running] })
          .where(workflows: { state: %w[queued running] })
          .includes(:job, step: :workflow)
          .to_a
          .reject { |run| queued_run_blocked_by_explicit_solid_queue_state?(run) }
          .reject { |run| queued_run_held_for_worker_environment?(run) }
          .reject { |run| run.running? && terminal_spawned_process_for?(run) }
          .reject { |run| run.running? && stale_simulated_worker_evidence?(run) }
          .reject { |run| run.running? && run.artifacts.to_h[WEDGED_RUN_ARTIFACT] }
      end

      # Run#enqueue never hands a Run to SolidQueue while every live worker
      # lacks what its install needs (it records a no_capable_worker hold
      # instead), so no worker can pick it up until that changes.
      def queued_run_held_for_worker_environment?(run)
        return false unless run.queued?

        RunQueueResolver.resolve(run: run).blocked_reason == RunQueueResolver::ENVIRONMENT_CHECK_BLOCKED_REASON
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
        return true if solid_queue_scheduled?(job) && job.scheduled_at.present? && job.scheduled_at <= Time.current

        false
      end

      def queued_run_for_event!(attrs)
        scope = Run.joins(:step).where(job_id: attrs.fetch("job"), state: "queued")
        scope = scope.where(steps: { kind: attrs["step"] || attrs["kind"] }) if attrs["step"].present? || attrs["kind"].present?
        if attrs["name"].present?
          scope.includes(:step).detect { |run| run.step&.details.to_h["name"].to_s == attrs["name"].to_s } ||
            raise(ActiveRecord::RecordNotFound, "queued simulation Run named #{attrs["name"].inspect} not found")
        else
          scope.order(:id).first!
        end
      end

      def delete_solid_queue_jobs_for_run!(run)
        ids = explicit_solid_queue_jobs_for_run(run).map(&:id)
        return if ids.empty?

        SolidQueue::ReadyExecution.where(job_id: ids).delete_all if defined?(SolidQueue::ReadyExecution)
        SolidQueue::ScheduledExecution.where(job_id: ids).delete_all if defined?(SolidQueue::ScheduledExecution)
        SolidQueue::ClaimedExecution.where(job_id: ids).delete_all if defined?(SolidQueue::ClaimedExecution)
        SolidQueue::FailedExecution.where(job_id: ids).delete_all if defined?(SolidQueue::FailedExecution)
        SolidQueue::Job.where(id: ids).delete_all
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

      def with_simulated_workspaces
        config = runtime.fetch("workspace", {}).to_h
        return yield if config.blank?

        @simulated_workspace_paths = []
        jobs.each do |job|
          workflow = job.latest_workflow
          create_simulated_workspace!(workflow) if config.fetch("exists", true)
        end
        previous = WorkflowWorkspaceRecovery.simulation_runner
        WorkflowWorkspaceRecovery.simulation_runner = ->(workflow:, **) { simulate_workspace_recovery!(workflow, config) }
        yield
      ensure
        WorkflowWorkspaceRecovery.simulation_runner = previous if defined?(previous)
        Array(@simulated_workspace_paths).each { |path| FileUtils.remove_entry(path) if path.exist? }
      end

      def simulate_workspace_recovery!(workflow, config)
        unless config.fetch("reconstructable", true)
          message = config.fetch("failure_reason", "durable reconstruction evidence is unavailable")
          events << "workspace reconstruction failed for workflow #{workflow.id}: #{message}"
          return WorkflowWorkspaceRecovery::Result.new(status: "retry_required", workflow: workflow, run: workflow.runs.active.last, message: message)
        end

        create_simulated_workspace!(workflow)
        hostname = config.fetch("recovered_worker", "simulation-recovery-worker")
        storage_key = config.fetch("recovered_storage_key", "simulation-recovered-storage")
        ensure_worker_live!(hostname, storage_key)
        WorkflowWorkspaceLifecycle.created!(workflow, actor: "workspace_recovery")
        WorkflowWorkspaceLifecycle.record_identity!(workflow, hostname: hostname, storage_key: storage_key, actor: "workspace_recovery")
        stranded = workflow.runs.active.includes(:step).to_a
        stranded.each do |run|
          if run.running?
            run.update_columns(state: "queued", started_at: nil, finished_at: nil, updated_at: Time.current)
            run.step.update_columns(state: "queued", started_at: nil, finished_at: nil, updated_at: Time.current)
          end
          SolidQueueRunJobPruner.delete_pending_for_run!(run.id)
          run.reenqueue!(ignore_workflow_affinity: true)
        end
        events << "workspace reconstructed for workflow #{workflow.id}; resumed #{stranded.size} stranded runs"
        recovery_message = "workspace reconstructed and #{stranded.size} stranded runs resumed"
        WorkflowWorkspaceRecovery::Result.new(
          status: "recovered", workflow: workflow, run: stranded.last,
          message: recovery_message
        )
      end

      def create_simulated_workspace!(workflow)
        path = WorkflowWorkspace.path_for(workflow)
        if path.exist? && !Array(@simulated_workspace_paths).include?(path)
          raise "simulation refuses to claim pre-existing workspace #{path}"
        end

        FileUtils.mkdir_p(path)
        @simulated_workspace_paths << path unless @simulated_workspace_paths.include?(path)
      end

      def remove_simulated_workspace!(workflow)
        path = WorkflowWorkspace.path_for(workflow)
        unless Array(@simulated_workspace_paths).include?(path)
          raise "simulation refuses to remove unowned workspace #{path}"
        end

        FileUtils.remove_entry(path) if path.exist?
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

      # The fingerprint without update timestamps: what the world is, not
      # when it was last touched.
      def state_fingerprint
        [
          Job.where(id: job_ids).order(:id).pluck(:id, :state, :pr_number, :branch_name, :manual_paused),
          Workflow.where(job_id: job_ids).order(:id).pluck(:id, :state),
          Step.joins(:workflow).where(workflows: { job_id: job_ids }).order(:id).pluck(:id, :state),
          Run.where(job_id: job_ids).order(:id).pluck(:id, :state),
          WorkUnit.where(scope_type: "job", scope_id: job_ids).order(:id).pluck(:id, :state, :blocked_reason)
        ]
      end

      def fingerprint
        [
          Job.where(id: job_ids).order(:id).pluck(:id, :state, :pr_number, :branch_name, :updated_at),
          Workflow.where(job_id: job_ids).order(:id).pluck(:id, :state, :updated_at),
          Step.joins(:workflow).where(workflows: { job_id: job_ids }).order(:id).pluck(:id, :state, :updated_at),
          Run.where(job_id: job_ids).order(:id).pluck(:id, :state, :updated_at),
          AutoRetryAttempt.where(job_id: job_ids).order(:id).pluck(:id, :performed_at, :skipped_reason, :scheduled_at, :updated_at),
          @git_effects&.fingerprint,
          WorkIntent.where(scope_type: "job", scope_id: job_ids).order(:id).pluck(:id, :state, :wait_reason, :updated_at),
          WorkUnit.where(scope_type: "job", scope_id: job_ids).order(:id).pluck(:id, :state, :blocked_reason, :updated_at)
        ]
      end

      def observe_invariants!(tick)
        return [] unless @invariant_assertions

        @invariant_assertions.observe!(tick)
      end

      # The row-lock order (Syrus::LockOrder) is part of what a scenario
      # asserts. Where the checker is installed -- the test suite, and
      # bin/simulator -- the run records inversions instead of raising them:
      # a raise inside the engine is often rescued and logged, which hid an
      # inversion the simulation had driven a service into. Recorded ones fail
      # the scenario like an invariant violation.
      def with_lock_order_recording
        checker = defined?(Syrus::LockOrder::Checker) ? Syrus::LockOrder::Checker : nil
        return yield if @invariant_assertions.nil? || checker.nil? || checker.mode.nil?

        previous_mode = checker.mode
        previous_violations = checker.violations.dup
        checker.violations.clear
        checker.mode = :record
        @lock_order_checker = checker
        yield
      ensure
        if @lock_order_checker
          checker.violations.replace(previous_violations)
          checker.mode = previous_mode
          @lock_order_checker = nil
        end
      end

      def lock_order_failures
        return [] unless @lock_order_checker

        @lock_order_checker.violations.uniq.map do |violation|
          "invariant lock_order: took #{violation.taking} at #{violation.site} while holding #{violation.held} from #{violation.held_site}"
        end
      end

      def finish(result, quiescent:)
        return result unless @invariant_assertions

        failures = lock_order_failures + @invariant_assertions.finish!([ result.ticks - 1, 0 ].max, quiescent: quiescent)
        return result if failures.empty?

        violated(result.ticks, failures, ended_as: result.status)
      end

      def violated(ticks, failures, ended_as: nil)
        Result.new(
          scenario: scenario,
          ticks: ticks,
          status: "violated",
          events: events,
          stuck_reasons: [ ("scenario otherwise ended #{ended_as}" if ended_as), *failures, *stuck_state ].compact,
          wait_reasons: [],
          job_ids: job_ids,
          epic_ids: jobs.filter_map(&:epic_id).uniq,
          work_intent_ids: work_intent_ids,
          invariant_violations: failures,
          final_states: final_states
        )
      end

      def final_states
        Job.where(id: job_ids).order(:id).to_h { |job| [ job.slug, job.manual_paused? ? "#{job.state}:manual_paused" : job.state ] }
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
          work_intent_ids: work_intent_ids,
          final_states: final_states
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
          work_intent_ids: work_intent_ids,
          final_states: final_states
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
          work_intent_ids: work_intent_ids,
          final_states: final_states
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
