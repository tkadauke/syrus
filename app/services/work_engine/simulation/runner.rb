require "digest/sha1"

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
        success_states: {},
        wait_states: {},
        max_ticks: DEFAULT_MAX_TICKS,
        ignored_reconciler_issue_kinds: DEFAULT_IGNORED_RECONCILER_ISSUE_KINDS
      )
        @job_ids = Array(job_ids).map(&:to_i)
        @work_intent_ids = Array(work_intent_ids).map(&:to_i)
        @scenario = scenario
        @outcomes = outcomes.to_h
        @success_states = success_states.to_h
        @wait_states = wait_states.to_h
        @max_ticks = max_ticks.to_i.positive? ? max_ticks.to_i : DEFAULT_MAX_TICKS
        @ignored_reconciler_issue_kinds = Array(ignored_reconciler_issue_kinds).map(&:to_s)
        @events = []
        @run_attempts = Hash.new(0)
      end

      def call
        max_ticks.times do |tick|
          before = fingerprint
          reconcile!(tick)
          retry_failed_jobs!(tick)
          wake_jobs!
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

      attr_reader :job_ids, :work_intent_ids, :scenario, :outcomes, :success_states, :wait_states, :max_ticks, :ignored_reconciler_issue_kinds, :events, :run_attempts

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

      def retry_failed_jobs!(tick)
        jobs.each do |job|
          job.reload
          next unless job.failed?

          result = SmartRetryEnqueuer.call(job: job, automatic: false)
          next unless result.success?

          events << "tick #{tick}: retry #{job.slug} via #{result.action}"
        end
      end

      def retryable_failed_jobs?
        jobs.any?(&:failed?)
      end

      def execute_active_runs!(tick)
        active_runs.find_each do |run|
          execute_run!(run, tick)
        end
      end

      def execute_run!(run, tick)
        run_attempts[run_signature(run)] += 1
        outcome = outcome_for(run)
        events << "tick #{tick}: #{run.slug} #{run.step&.kind} -> #{outcome}"

        start_run!(run)
        case outcome
        when "success"
          simulate_side_effects!(run)
          succeed_run_and_step!(run)
        when "worker_died"
          fail_run!(run, agent_outcome: AutoRetryAttempt::WORKER_DIED_CLASSIFICATION)
        when "failure"
          fail_run!(run, agent_outcome: "error")
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

      def fail_run!(run, agent_outcome:)
        run.agent_outcome = agent_outcome
        run.fail!
        run.save!
        drain_run_failure!(run.reload)
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

      def simulate_side_effects!(run)
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
        end
      end

      def outcome_for(run)
        step_key = "#{run.job_id}:#{run.step&.kind}"
        scripted = outcomes.fetch("steps", {})[step_key] ||
          outcomes.fetch("steps", {})[run.step&.kind.to_s]
        sequence_outcome(scripted, run) || outcomes.fetch("default", "success")
      end

      def sequence_outcome(scripted, run)
        return scripted if scripted.is_a?(String)
        return nil unless scripted.is_a?(Array)

        scripted[[ run_attempts[run_signature(run)] - 1, scripted.length - 1 ].min]
      end

      def run_signature(run)
        "#{run.job_id}:#{run.step&.kind}"
      end

      def simulated_sha(run)
        Digest::SHA1.hexdigest("#{scenario}:#{run.job_id}:#{run.id}:#{run.step&.kind}")
      end

      def complete?
        jobs.all? { |job| success_state_for(job).include?(job.reload.state) }
      end

      def valid_waiting?
        jobs.all? do |job|
          state = job.reload.state
          success_state_for(job).include?(state) || wait_state_for(job).include?(state)
        end
      end

      def success_state_for(job)
        Array(success_states[job.id.to_s] || success_states[job.slug] || SUCCESS_JOB_STATES)
      end

      def wait_state_for(job)
        Array(wait_states[job.id.to_s] || wait_states[job.slug])
      end

      def no_active_runs?
        active_runs.none?
      end

      def active_runs
        Run.joins(step: :workflow)
          .where(job_id: job_ids, state: %w[queued running])
          .where(steps: { state: %w[queued running] })
          .where(workflows: { state: %w[queued running] })
          .includes(:job, step: :workflow)
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
