module WorkEngine
  class RepairExecutor
    Execution = Data.define(:action, :target_type, :target_id, :status, :message) do
      def initialize(action:, target_type:, target_id:, status:, message:)
        super(
          action: action.to_s,
          target_type: target_type.to_s,
          target_id: target_id,
          status: status.to_s,
          message: message.to_s
        )
      end

      def as_json(*)
        {
          action: action,
          target_type: target_type,
          target_id: target_id,
          status: status,
          message: message
        }
      end
    end

    def self.call(...) = new(...).call

    def initialize(result:, now: Time.current)
      @result = result
      @now = now
    end

    def call
      result.repair_plans.map do |plan|
        policy_for(plan).execute
      end
    end

    private

    attr_reader :result, :now

    def policy_for(plan)
      Policies::Base.for(plan.action).new(plan: plan, now: now)
    end

    module Policies
      class Base
        def self.for(action)
          registry.fetch(action.to_s, Default)
        end

        def self.registry
          @registry ||= descendants.index_by(&:action)
        end

        def self.action
          name.demodulize.underscore
        end

        def initialize(plan:, now:)
          @plan = plan
          @now = now
        end

        def execute
          return skipped("plan is not marked safe for automatic execution") unless plan.auto_executable

          with_audit { perform }
        rescue StandardError => e
          Rails.logger.warn("[WorkEngine::RepairExecutor] #{plan.action} failed: #{e.class}: #{e.message}")
          failure("#{e.class}: #{e.message}")
        end

        private

        attr_reader :plan, :now

        def perform
          skipped("no executor policy exists for #{plan.action}")
        end

        def with_audit
          audit!("applying")
          result = yield
          audit!(result.status, result.message)
          result
        end

        def success(message)
          execution("applied", message)
        end

        def skipped(message)
          execution("skipped", message)
        end

        def failure(message)
          execution("failed", message)
        end

        def execution(status, message)
          Execution.new(
            action: plan.action,
            target_type: plan.target_type,
            target_id: plan.target_id,
            status: status,
            message: message
          )
        end

        def target_run
          @target_run ||= if plan.target_type == "Run"
            Run.includes(:job, :step, :provider_session_metadata, :run_failure_classification).find_by(id: plan.target_id)
          else
            first_run
          end
        end

        def target_workflow
          @target_workflow ||= if plan.target_type == "Workflow"
            Workflow.includes(:job, :steps).find_by(id: plan.target_id)
          else
            first_workflow || target_run&.workflow
          end
        end

        def target_job
          @target_job ||= if plan.target_type == "Job"
            Job.find_by(id: plan.target_id)
          else
            target_workflow&.job || target_run&.job || first_job
          end
        end

        def target_step
          @target_step ||= if plan.target_type == "Step"
            Step.includes(:workflow, :runs, :previous_step).find_by(id: plan.target_id)
          else
            Step.includes(:workflow, :runs, :previous_step).find_by(id: first_id("step_ids")) || target_run&.step
          end
        end

        def first_run
          Run.includes(:job, :step, :provider_session_metadata, :run_failure_classification).find_by(id: first_id("run_ids"))
        end

        def first_workflow
          Workflow.includes(:job, :steps).find_by(id: first_id("workflow_ids"))
        end

        def first_job
          Job.find_by(id: first_id("job_ids"))
        end

        def first_id(key)
          Array(plan.affected_ids[key]).first
        end

        def audit_run
          target_run || target_workflow&.runs&.order(created_at: :desc)&.first || target_job&.runs&.order(created_at: :desc)&.first
        end

        def audit!(status, message = nil)
          text = "[work-engine reconciler] #{status} #{plan.action}"
          text = "#{text}: #{message}" if message.present?
          Rails.logger.info("[WorkEngine::RepairExecutor] #{text} target=#{plan.target_type}##{plan.target_id}")
          run = audit_run
          append_audit_once!(run, text) if run
        rescue StandardError => e
          Rails.logger.warn("[WorkEngine::RepairExecutor] audit failed for #{plan.action}: #{e.class}: #{e.message}")
        end

        def append_audit_once!(run, text)
          JobLog.transaction do
            locked_run = Run.lock.find(run.id)
            next if JobLog.where(run_id: locked_run.id, kind: "system", chunk: text).exists?

            JobLog.append!(run: locked_run, chunk: text, kind: "system")
          end
        end

        def schedule_auto_retry!(retry_kind:, source_run: nil, workflow: nil, job: nil, respect_provider_circuit: true)
          source_run ||= target_run
          workflow ||= source_run&.workflow || target_workflow
          job ||= source_run&.job || workflow&.job || target_job
          return skipped("retry target is missing") unless workflow && job
          return skipped("retry already pending") if workflow.auto_retry_attempts.pending.exists?

          agent_provider = source_run&.agent_provider.presence || workflow.agent_provider || job.agent_provider
          classification = source_run&.run_failure_classification&.classification.presence ||
            source_run&.agent_outcome.presence ||
            "unknown"
          circuit = ProviderCircuitBreaker.call(agent_provider, now: now)
          if respect_provider_circuit && circuit.open?
            retry_at = circuit.retry_after ? " until #{circuit.retry_after.iso8601}" : ""
            return skipped("provider circuit is open for #{agent_provider}#{retry_at}: #{circuit.reason}")
          end

          attempt_number = AutoRetryAttempt.budget_scope_for(
            job: job,
            agent_provider: agent_provider,
            failure_classification: classification
          ).count + 1
          return skipped("retry budget exhausted for #{agent_provider}/#{classification}") if attempt_number > retry_budget_limit(classification)

          scheduled_at = plan.retry_after || now
          attempt = AutoRetryAttempt.create!(
            job: job,
            workflow: workflow,
            run: source_run,
            agent_provider: agent_provider,
            failure_classification: classification,
            retry_kind: retry_kind,
            attempt_number: attempt_number,
            scheduled_at: scheduled_at
          )
          AutoRetryJob.set(wait_until: scheduled_at, priority: job.solid_queue_priority).perform_later(attempt.id)
          success("scheduled #{retry_kind} auto-retry attempt ##{attempt.id} for #{scheduled_at.iso8601}")
        end

        def retry_budget_limit(classification)
          classification == AutoRetryAttempt::WORKER_DIED_CLASSIFICATION ? AutoRetryAttempt::MAX_WORKER_DIED_ATTEMPTS : AutoRetryAttempt::MAX_ATTEMPTS
        end

        def mark_worker_died!
          run = target_run
          return skipped("Run no longer exists") unless run
          return skipped("Run is #{run.state}, not running") unless run.running?
          return skipped("Run cannot transition to failed") unless run.may_fail?

          StateTransition.with_source("reconciler") do
            run.agent_outcome = AutoRetryAttempt::WORKER_DIED_CLASSIFICATION
            run.fail!
            run.save!
          end
          success("marked Run ##{run.id} worker_died; no automatic retry was scheduled, leaving follow-up to terminal-state reconciliation or operator review")
        end
      end

      class Default < Base; end

      class ReenqueueRun < Base
        def perform
          run = target_run
          return skipped("Run no longer exists") unless run
          return skipped("Run is #{run.state}, not queued") unless run.queued?
          return skipped("Workflow is not active") unless run.workflow&.queued? || run.workflow&.running?
          return skipped("retry already pending for workflow") if run.workflow.auto_retry_attempts.pending.exists?
          return skipped("required grader conclusion already cached failed for this commit") if blocked_by_cached_grader_failure?(run)

          run.reenqueue!
          success("re-enqueued Run ##{run.id}")
        end

        private

        # queued_run_without_queue_claim is the one queued-run issue kind where
        # re-enqueueing is safe even with a cached failed conclusion: the Run
        # never had a queue claim at all, so it has not executed yet and still
        # needs to run once to make the loop progress deterministically. The
        # other queued-run kinds (dead resume queue, failed SolidQueue
        # execution) mean a claim/attempt already happened, so replaying a
        # grader_collect Run against an already-known-failed commit just churns.
        def blocked_by_cached_grader_failure?(run)
          return false if plan.issue_kind == "queued_run_without_queue_claim"

          run.step&.kind == "grader_collect" && GraderConclusionCache.failed_for_workflow?(run.workflow)
        end
      end

      class ResumeQueuedStep < Base
        def perform
          step = target_step
          return skipped("Step no longer exists") unless step
          return skipped("Step is #{step.state}, not queued") unless step.queued?
          return skipped("Step already has a Run") if step.runs.exists?

          workflow = step.workflow
          return skipped("Workflow no longer exists") unless workflow
          return skipped("Workflow is #{workflow.state}, not running") unless workflow.running?

          previous = step.previous_step
          return skipped("Previous Step is not succeeded") unless previous&.succeeded?

          run = StepDispatcher.resume_deferred_phase(workflow.id, step.id)
          run ? success("resumed Step ##{step.id} with Run ##{run.id}") : skipped("queued Step remained deferred")
        end
      end

      class StartWorkflow < Base
        def perform
          workflow = target_workflow
          return skipped("Workflow no longer exists") unless workflow
          return skipped("Workflow is #{workflow.state}, not queued") unless workflow.queued?
          first = workflow.first_step
          return skipped("Workflow has no first Step") unless first
          return skipped("First Step already has a Run") if first.runs.exists?

          run = StepDispatcher.start_workflow(workflow)
          run ? success("started Workflow ##{workflow.id} with Run ##{run.id}") : skipped("workflow start remained blocked")
        end
      end

      class ClearStaleStartBlockAndStartWorkflow < Base
        def perform
          workflow = target_workflow
          return skipped("Workflow no longer exists") unless workflow
          return skipped("Workflow is #{workflow.state}, not queued") unless workflow.queued?
          return skipped("Workflow is not dependency-blocked") unless workflow.artifact("start_blocked_reason") == StepDispatcher::STACK_BLOCK_REASON
          return skipped("Dependencies are still unsatisfied") if workflow.job.unsatisfied_dependencies.any?

          StepDispatcher.clear_start_blocked!(workflow, StepDispatcher::STACK_BLOCK_REASON)
          run = StepDispatcher.start_workflow(workflow.reload)
          run ? success("cleared stale dependency block and started Workflow ##{workflow.id} with Run ##{run.id}") : skipped("workflow start remained blocked")
        end
      end

      class DeferLandingStartBlockedWorkflow < Base
        def perform
          workflow = target_workflow
          return skipped("Workflow no longer exists") unless workflow
          return skipped("Workflow is #{workflow.state}, not queued") unless workflow.queued?
          return skipped("Workflow is not a landing workflow") unless workflow.landing_workflow?
          return skipped("Job is #{workflow.job&.state}, not landing") unless workflow.job&.landing?
          return skipped("Workflow first step already has a Run") if workflow.first_step&.runs&.exists?
          return skipped("Job cannot transition to approved") unless workflow.job.may_defer_landing?

          reason = workflow.artifact("failure_reason").presence ||
            workflow.artifact("start_blocked_reason").presence ||
            "landing start blocked: workflow admission budget"
          reason = "workflow admission budget" if reason == StepDispatcher::ADMISSION_BLOCK_REASON
          reason = "landing start blocked: #{reason}" unless LandingQueueReentry.landing_start_blocker?(reason)

          StateTransition.with_source("reconciler") do
            StepDispatcher.fail_unstartable_landing_workflow!(workflow, reason)
          end

          success("failed blocked landing Workflow ##{workflow.id} and deferred Job ##{workflow.job_id} back to approved")
        end
      end

      class CancelStaleAutoRetryWorkflow < Base
        def perform
          workflow = target_workflow
          return skipped("Workflow no longer exists") unless workflow
          return skipped("Workflow is #{workflow.state}, not queued") unless workflow.queued?
          return skipped("Workflow is #{workflow.trigger_kind}, not retry") unless workflow.trigger_kind == "retry"

          attempt_id = workflow.artifact("auto_retry_attempt_id")
          attempt = AutoRetryAttempt.find_by(id: attempt_id)
          return skipped("Workflow is missing its auto-retry attempt") unless attempt
          return skipped("Source workflow is not superseded") unless source_superseded?(workflow.job, attempt.workflow)

          StateTransition.with_source("reconciler") do
            workflow.artifacts = (workflow.artifacts || {}).merge(
              "retry_cancelled_reason" => "stale_auto_retry",
              "retry_cancelled_at" => Time.current.iso8601
            )
            workflow.cancel! if workflow.may_cancel?
            workflow.save!
            attempt.update!(skipped_reason: "source workflow was already superseded") if attempt.skipped_reason.blank?
          end
          WorkEngine::Reconciler.request(source: self.class.name, job: workflow.job)
          success("cancelled stale auto-retry Workflow ##{workflow.id}")
        end

        private

        def source_superseded?(job, source)
          return false unless job && source
          return true if source.succeeded?
          return true if branch_divergence_recovered_by_current_pr_branch?(source)

          cutoff = source.finished_at || source.created_at
          return false unless cutoff

          job.workflows
             .where(state: "succeeded")
             .where("created_at > ? OR (created_at = ? AND id > ?)", cutoff, cutoff, source.id)
             .exists?
        end

        def branch_divergence_recovered_by_current_pr_branch?(workflow)
          workflow&.artifact("branch_divergence_recovery").is_a?(Hash) &&
            workflow.artifact("branch_divergence_recovery")["action"] == "superseded_by_current_pr_branch"
        end
      end

      class FinishWorkflowFromTerminalDescendants < Base
        def perform
          workflow = target_workflow
          return skipped("Workflow no longer exists") unless workflow
          return skipped("Workflow is #{workflow.state}, not running") unless workflow.running?
          return skipped("Workflow still has active descendants") if workflow.steps.active.exists? || workflow.runs.active.exists?

          outcome = orphaned_workflow_outcome(workflow)
          return skipped("No terminal outcome could be inferred") unless outcome

          StateTransition.with_source("reconciler") do
            if outcome == :succeeded
              return skipped("Workflow cannot transition to succeeded") unless workflow.may_succeed?

              workflow.succeed!
            else
              return skipped("Workflow cannot transition to failed") unless workflow.may_fail?

              workflow.fail!
            end
            workflow.save!
          end
          success("marked Workflow ##{workflow.id} #{outcome}")
        end

        private

        def orphaned_workflow_outcome(workflow)
          terminal_positions = workflow.steps.pluck(:state, :position)
          last_succeeded = terminal_positions.filter_map { |state, position| position if state == "succeeded" }.max
          last_failed = terminal_positions.filter_map { |state, position| position if state == "failed" }.max

          return :succeeded if last_succeeded && (last_failed.nil? || last_succeeded > last_failed)
          return :failed if last_failed && (last_succeeded.nil? || last_failed > last_succeeded)

          nil
        end
      end

      class FailWorkflowFromFailedStep < Base
        def perform
          workflow = target_workflow
          return skipped("Workflow no longer exists") unless workflow
          return skipped("Workflow is #{workflow.state}, not running") unless workflow.running?
          return skipped("Workflow still has active Runs") if workflow.runs.active.exists?
          return skipped("Workflow still has running Steps") if workflow.steps.where(state: "running").exists?

          failed_step = workflow.steps.where(state: "failed").order(position: :desc, id: :desc).first
          return skipped("Workflow has no failed Step") unless failed_step
          return skipped("Workflow cannot transition to failed") unless workflow.may_fail?

          StateTransition.with_source("reconciler") do
            workflow.fail!
            workflow.save!
          end
          success("marked Workflow ##{workflow.id} failed from failed Step ##{failed_step.id}")
        end
      end

      class ReconcileStepFromTerminalRun < Base
        def perform
          step = target_step
          return skipped("Step no longer exists") unless step
          return skipped("Step is #{step.state}, not active") unless step.running? || step.queued?
          return skipped("Workflow is not running") unless step.workflow&.running?

          step_runs = step.runs.to_a
          return skipped("Step has no Runs") if step_runs.empty?
          return skipped("Step still has active Runs") if step_runs.any? { |run| run.queued? || run.running? }

          run = latest_terminal_run(step_runs)
          return skipped("Step has no terminal Run") unless run

          StateTransition.with_source("reconciler") do
            case run.state
            when "succeeded"
              return skipped("Step cannot transition to succeeded") unless step.may_succeed?

              step.succeed!
            when "failed"
              return skipped("Step cannot transition to failed") unless step.may_fail?

              step.fail!
            when "cancelled"
              return skipped("Step cannot transition to cancelled") unless step.may_cancel?

              step.cancel!
            else
              return skipped("Run is #{run.state}, not terminal")
            end
            step.save!
          end

          success("reconciled Step ##{step.id} to #{step.state} from Run ##{run.id}")
        end

        private

        def latest_terminal_run(step_runs)
          step_runs.select(&:terminal?).max_by { |run| [ run.finished_at || run.updated_at || run.created_at || Time.zone.at(0), run.id || 0 ] }
        end
      end

      class CancelWorkflowForClosedJob < Base
        def perform
          workflow = target_workflow
          return skipped("Workflow no longer exists") unless workflow
          return skipped("Workflow is #{workflow.state}, not active") unless workflow.queued? || workflow.running?
          return skipped("Job is not closed") unless workflow.job&.closed?
          return skipped("Workflow cannot transition to cancelled") unless workflow.may_cancel?

          StateTransition.with_source("reconciler") do
            workflow.artifacts = (workflow.artifacts || {}).merge(
              "cancelled_reason" => "job_closed",
              "cancelled_by_reconciler_at" => Time.current.iso8601
            )
            workflow.cancel!
            workflow.save!
          end

          success("cancelled Workflow ##{workflow.id} because Job ##{workflow.job_id} is closed")
        end
      end

      class CancelEpicWorkflowConflict < Base
        def perform
          workflow = target_workflow
          return skipped("Workflow no longer exists") unless workflow
          return skipped("Workflow is #{workflow.state}, not active") unless workflow.queued? || workflow.running?
          return skipped("Workflow cannot transition to cancelled") unless workflow.may_cancel?

          keeper_id = plan.preconditions["keeper_workflow_id"]
          keeper = Workflow.find_by(id: keeper_id)
          return skipped("Keeper Workflow ##{keeper_id} is no longer active") unless keeper&.queued? || keeper&.running?

          StateTransition.with_source("reconciler") do
            workflow.artifacts = (workflow.artifacts || {}).merge(
              "cancelled_reason" => EpicWorkflowLock::BLOCK_REASON,
              "cancelled_by_reconciler_at" => Time.current.iso8601,
              "cancelled_details" => {
                "keeper_workflow_id" => keeper.id,
                "keeper_workflow_slug" => keeper.slug,
                "keeper_trigger_kind" => keeper.trigger_kind
              }
            )
            workflow.cancel!
            workflow.save!
          end

          success("cancelled Workflow ##{workflow.id} because Epic-wide Workflow ##{keeper.id} is active")
        end
      end

      class DeferOrphanedLandingJob < Base
        def perform
          job = target_job
          return skipped("Job no longer exists") unless job
          return skipped("Job is #{job.state}, not landing") unless job.landing?
          return skipped("Job has active workflow") if job.workflows.active.exists?
          return skipped("Job cannot transition to approved") unless job.may_defer_landing?

          StateTransition.with_source("reconciler") do
            job.defer_landing!
            job.save!
          end

          success("deferred orphaned landing Job ##{job.id} back to approved")
        end
      end

      class ClearLandingStartBlockerAndWakeQueue < Base
        def perform
          job = target_job
          return skipped("Job no longer exists") unless job
          return skipped("Job is #{job.state}, not approved") unless job.approved?
          return skipped("Job no longer has a landing-start blocker") unless LandingQueueReentry.landing_start_blocker?(job.landing_failure_reason)

          result = LandingQueueReentry.call(job)
          return skipped("Landing-start blocker is still active") unless result.any?

          success("cleared landing-start blocker for #{result.cleared_job_ids.size} Job(s) and woke the landing queue")
        end
      end

      class MarkWorkerDied < Base
        def perform = mark_worker_died!
      end

      class MarkWorkerDiedAndResumeFailedStep < Base
        def perform
          result = mark_worker_died!
          return result unless result.status == "applied"

          schedule_auto_retry!(retry_kind: "resume_failed_step")
        end
      end

      class MarkWorkerDiedAndRetryFailedStep < Base
        def perform
          result = mark_worker_died!
          return result unless result.status == "applied"
          return skipped("worker_died failure already created active replacement work") if target_job&.any_active_run?

          schedule_auto_retry!(retry_kind: "failed_step")
        end
      end

      class MarkWorkerDiedAndRetryWorkflow < Base
        def perform
          result = mark_worker_died!
          return result unless result.status == "applied"
          return skipped("worker_died failure already created active replacement work") if target_job&.any_active_run?

          schedule_auto_retry!(retry_kind: "retry_workflow")
        end
      end

      class ResumeFailedStep < Base
        def perform
          schedule_auto_retry!(retry_kind: "resume_failed_step")
        end
      end

      class RetryFailedStep < Base
        def perform
          schedule_auto_retry!(retry_kind: "failed_step")
        end
      end

      class RetryWorkflow < Base
        def perform
          schedule_auto_retry!(retry_kind: "retry_workflow")
        end
      end

      class DiscardSupersededBranchOutput < Base
        def perform
          workflow = target_workflow
          return skipped("Workflow no longer exists") unless workflow

          result = BranchDivergenceRecovery.discard_superseded!(workflow: workflow)
          result.success? ? success("discarded superseded branch output for Workflow ##{workflow.id}") : skipped(result.error)
        end
      end

      class ScheduleRetryAfterRateLimit < Base
        def perform
          schedule_auto_retry!(
            retry_kind: delayed_retry_kind,
            respect_provider_circuit: false
          )
        end

        private

        def delayed_retry_kind
          run = target_run
          workflow = run&.workflow || target_workflow
          if run&.provider_session_metadata.present? && workflow&.retry_available? && run.step&.agentic?
            "resume_failed_step"
          elsif workflow&.retry_available?
            "failed_step"
          else
            "retry_workflow"
          end
        end
      end

      class RebuildMergeTrain < Base
        def perform
          workflow = target_workflow
          return skipped("Workflow no longer exists") unless workflow

          result = RetryFailedStepEnqueuer.call(workflow: workflow)
          result.success? ? success("started merge-train rebuild with Run ##{result.run.id}") : skipped(result.error)
        end
      end

      class ReconcileJobState < Base
        def perform
          job = target_job
          return skipped("Job no longer exists") unless job

          state_plan = ReconcileJobStatesJob::Plan.for(job)
          return skipped("Job state drift is no longer present") unless state_plan

          state_plan.apply!
          success("reconciled Job ##{job.id} from #{state_plan.from_state} to #{state_plan.target_state}")
        end
      end

      class RetryJobAfterEpicWorkflowConflict < Base
        def perform
          job = target_job
          return skipped("Job no longer exists") unless job
          return skipped("Job is #{job.state}, not queued") unless job.queued?
          return skipped("Job has active work") if job.any_active_run? || job.workflows.active.exists?

          latest = job.latest_workflow
          return skipped("Latest Workflow is not cancelled") unless latest&.cancelled?
          return skipped("Latest Workflow was not cancelled by an Epic-wide workflow lock") unless latest.artifact("cancelled_reason") == EpicWorkflowLock::BLOCK_REASON
          return skipped("Epic-wide workflow is still active") if active_epic_wide_workflow_for_job?(job)
          return skipped("Dependencies are still unsatisfied") if job.unsatisfied_dependencies.any?

          result = RetryWorkflowEnqueuer.call(
            job: job,
            artifacts: {
              "retry_reason" => "epic_workflow_conflict_recovered",
              "cancelled_workflow_id" => latest.id,
              "cancelled_trigger_kind" => latest.trigger_kind
            },
            provider_validation: :none,
            automatic: true
          )
          return skipped(result.error) unless result.success?

          success("started retry Workflow ##{result.workflow.id} for Job ##{job.id} after Epic-wide workflow conflict cleared")
        end

        private

        def active_epic_wide_workflow_for_job?(job)
          return false unless job.epic_id

          Workflow
            .active
            .epic_wide
            .where(job_id: job.epic.jobs.select(:id))
            .exists?
        end
      end

      class RetryJobAfterCancelledWorkflow < Base
        RECOVERY_TRIGGER_KINDS = %w[
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
        DELIBERATE_REASONS = %w[
          job_closed
          operator_cancelled
          operator_stale_work_repair
          external_pr_closed
          external_pr_merged
          no_changes
        ].freeze

        def perform
          job = target_job
          return skipped("Job no longer exists") unless job
          return skipped("Job is #{job.state}, not queued") unless job.queued?
          return skipped("Job has active work") if job.any_active_run? || job.workflows.active.exists?

          latest = job.latest_workflow
          return skipped("Latest Workflow is not cancelled") unless latest&.cancelled?
          return skipped("Latest Workflow trigger_kind is not recoverable") unless RECOVERY_TRIGGER_KINDS.include?(latest.trigger_kind)
          return skipped("Latest Workflow was cancelled by an Epic-wide workflow lock") if cancelled_workflow_reason(latest) == EpicWorkflowLock::BLOCK_REASON
          return skipped("Latest Workflow cancellation appears deliberate") if deliberate_cancelled_workflow?(latest)
          return skipped("Epic-wide workflow is still active") if active_epic_wide_workflow_for_job?(job)
          return skipped("Dependencies are still unsatisfied") if job.unsatisfied_dependencies.any?

          result = RetryWorkflowEnqueuer.call(
            job: job,
            artifacts: {
              "retry_reason" => "cancelled_workflow_recovered",
              "cancelled_workflow_id" => latest.id,
              "cancelled_trigger_kind" => latest.trigger_kind
            },
            provider_validation: :none,
            automatic: true
          )
          return skipped(result.error) unless result.success?

          success("started retry Workflow ##{result.workflow.id} for Job ##{job.id} after cancelled Workflow ##{latest.id}")
        end

        private

        def deliberate_cancelled_workflow?(workflow)
          reason = cancelled_workflow_reason(workflow).to_s
          return true if DELIBERATE_REASONS.include?(reason)
          return true if reason.start_with?("operator_")
          return true if workflow.artifact("retry_cancelled_reason").present?

          false
        end

        def cancelled_workflow_reason(workflow)
          workflow.artifact("start_cancelled_reason").presence || workflow.artifact("cancelled_reason")
        end

        def active_epic_wide_workflow_for_job?(job)
          return false unless job.epic_id

          Workflow
            .active
            .epic_wide
            .where(job_id: job.epic.jobs.select(:id))
            .exists?
        end
      end

      class CloseCompletedMainGraderJob < Base
        def perform
          job = target_job
          return skipped("Job no longer exists") unless job
          return skipped("Job is not a main grader") unless job.kind == "main_grader"
          return skipped("Job is already closed") if job.closed?
          return skipped("Job cannot close") unless job.may_close?

          StateTransition.with_source("reconciler") do
            job.close_with_reason!(Job::MAIN_GRADER_CLOSURE_REASON)
          end
          success("closed completed main grader Job ##{job.id}")
        end
      end
    end
  end
end
