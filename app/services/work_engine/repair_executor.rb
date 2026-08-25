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
          if transient_database_lock_error?(e)
            result = skipped("deferred due to transient database lock: #{e.message}")
            audit!(result.status, result.message)
            return result
          end

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

        def target_work_unit
          @target_work_unit ||= if plan.target_type == "WorkUnit"
            WorkUnit.includes(:work_unit_locks, :workflow, :work_unit_members).find_by(id: plan.target_id)
          else
            first_work_unit || target_workflow&.work_unit
          end
        end

        def target_work_intent
          @target_work_intent ||= if plan.target_type == "WorkIntent"
            WorkIntent.find_by(id: plan.target_id)
          else
            WorkIntent.find_by(id: first_id("work_intent_ids")) || target_work_unit&.work_intent
          end
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

        def review_publication_step_kinds_for(workflow)
          WorkDefinitions.for(workflow.trigger_kind).review_publication_step_kinds
        rescue WorkDefinitions::UnknownKind
          []
        end

        def retry_cancelled_workflow(job, latest, retry_reason:)
          WorkUnits::TerminalWorkflowSync.for_job(job)
          WorkUnits::TerminalWorkflowSync.call(latest)

          artifacts = latest.artifacts.to_h.deep_dup.merge(
            "retry_reason" => retry_reason,
            "cancelled_workflow_id" => latest.id,
            "cancelled_trigger_kind" => latest.trigger_kind
          )

          if Workflow::TriggerKind.feedback_kind_for(latest.trigger_kind)
            workflow = WorkUnits::Launcher.instantiate(kind: latest.trigger_kind, job: job, artifacts: artifacts)
            WorkUnits::Launcher.start!(workflow)
            RetryWorkflowEnqueuer::Result.new(workflow: workflow, error: nil, circuit: nil)
          else
            RetryWorkflowEnqueuer.call(
              job: job,
              artifacts: artifacts,
              provider_validation: :none,
              automatic: true
            )
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

        def first_work_unit
          WorkUnit.includes(:work_unit_locks, :workflow, :work_unit_members).find_by(id: first_id("work_unit_ids"))
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

        def with_transition_reason(&block)
          StateTransition.with_source(
            "reconciler",
            reason: plan.action,
            metadata: {
              "repair_action" => plan.action,
              "repair_reason" => plan.reason,
              "issue_kind" => plan.issue_kind
            }.compact,
            &block
          )
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
          circuit = ProviderCircuitBreaker.call(agent_provider, now: now, include_logs: false)
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
          WorkUnits::AutoRetryBackoff.record!(attempt)
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

          existing_run_ids = run.step&.runs&.pluck(:id) || []
          with_transition_reason do
            run.agent_outcome = AutoRetryAttempt::WORKER_DIED_CLASSIFICATION
            run.fail!
            run.save!
          end
          if (replacement_run = worker_died_replacement_run(run, existing_run_ids: existing_run_ids))
            return success("marked Run ##{run.id} worker_died; queued replacement Run ##{replacement_run.id} on Step ##{run.step_id}")
          end

          success("marked Run ##{run.id} worker_died; no automatic retry was scheduled, leaving follow-up to terminal-state reconciliation or operator review")
        end

        def worker_died_replacement_run(run, existing_run_ids:)
          run.step&.runs&.where.not(id: existing_run_ids)&.order(:id)&.last
        end

        def transient_database_lock_error?(error)
          return true if defined?(ActiveRecord::LockWaitTimeout) && error.is_a?(ActiveRecord::LockWaitTimeout)

          error.is_a?(ActiveRecord::StatementInvalid) &&
            error.message.match?(/Lock wait timeout|database is locked/i)
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

      class SkipObsoleteRun < Base
        def perform
          run = target_run
          return skipped("Run no longer exists") unless run
          return skipped("Run is #{run.state}, not active") unless run.queued? || run.running?

          step = run.step
          return skipped("Run has no Step") unless step
          return skipped("Step is #{step.state}, not terminal") unless step.terminal?
          return skipped("Run cannot transition to skipped") unless run.may_skip?

          with_transition_reason do
            run.skip!
            run.save!
          end
          success("skipped obsolete Run ##{run.id} on terminal Step ##{step.id}")
        end
      end

      class MarkCachedGraderCollectFailed < Base
        def perform
          run = target_run
          return skipped("Run no longer exists") unless run
          return skipped("Run is #{run.state}, not queued") unless run.queued?

          step = run.step
          return skipped("Run has no Step") unless step
          return skipped("Step is #{step.state}, not queued") unless step.queued?
          return skipped("Step is #{step.kind}, not grader_collect") unless step.kind == "grader_collect"
          return skipped("Workflow is not running") unless run.workflow&.running?
          return skipped("required grader conclusion is no longer cached failed") unless GraderConclusionCache.failed_for_workflow?(run.workflow)

          RunDiagnostic.find_or_create_by!(run: run) do |diagnostic|
            diagnostic.error_class = "Steps::Base::StepFailed"
            diagnostic.error_message = "required graders failed: cached grader conclusion failed"
          end

          with_transition_reason do
            run.agent_outcome = "grader_failure"
            run.fail!
            run.save!
          end

          success("marked cached grader_collect Run ##{run.id} failed so retry-until can continue")
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

          run = WorkUnits::DeferredPhaseResume.call(workflow.id, step.id).run
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

          run = WorkUnits::Launcher.start!(workflow).run
          run ? success("started Workflow ##{workflow.id} with Run ##{run.id}") : skipped("workflow start remained blocked")
        end
      end

      class ReleaseLandingSlotForMainRepair < Base
        def perform
          workflow = target_workflow
          return skipped("Workflow no longer exists") unless workflow
          return skipped("Workflow is #{workflow.state}, not queued") unless workflow.queued?
          return skipped("Workflow is not a landing workflow") unless workflow.landing_workflow?
          return skipped("Workflow first step already has a Run") if workflow.first_step&.runs&.exists?
          return skipped("Workflow is not main-health blocked") unless WorkUnits::StartBlock.for(workflow).blocked_for?(StepDispatcher::MAIN_HEALTH_BLOCK_REASON)

          repair_job = Job.find_by(id: plan.preconditions["repair_job_id"])
          return skipped("Main repair Job no longer exists") unless repair_job
          return skipped("#{repair_job.slug} is #{repair_job.state}, not approved") unless repair_job.approved?
          return skipped("#{repair_job.slug} is not a main-branch repair Job") unless MainHealthChangedService.fix_main_job?(repair_job)

          with_transition_reason do
            if workflow.job&.landing? && workflow.job.may_defer_landing?
              workflow.job.defer_landing!
              workflow.job.save!
            end
            StepDispatcher.fail_unstartable_landing_workflow!(workflow, StepDispatcher::MAIN_HEALTH_BLOCK_REASON)
          end

          repair_workflow = LandingQueueProcessor.try_land!(repair_job)
          repair_workflow ? success("released blocked landing slot and dispatched #{repair_workflow.slug} for #{repair_job.slug}") : skipped("main repair Job did not land")
        end
      end

      class ClearStaleStartBlockAndStartWorkflow < Base
        def perform
          workflow = target_workflow
          return skipped("Workflow no longer exists") unless workflow
          return skipped("Workflow is #{workflow.state}, not queued") unless workflow.queued?
          dependency_blocked = WorkUnits::StartBlock.for(workflow).blocked_for?(StepDispatcher::STACK_BLOCK_REASON)
          return skipped("Workflow is not dependency-blocked") unless dependency_blocked
          return skipped("Dependencies are still not ready for execution") unless workflow.job.dependencies_satisfied_for_execution?

          StepDispatcher.clear_start_blocked!(workflow, StepDispatcher::STACK_BLOCK_REASON)
          workflow.work_unit&.unblock! if workflow.work_unit&.blocked_reason == "stack_dependencies_not_ready"
          run = WorkUnits::Launcher.start!(workflow.reload).run
          run ? success("cleared stale dependency block and started Workflow ##{workflow.id} with Run ##{run.id}") : skipped("workflow start remained blocked")
        end
      end

      class ResumeDeferredPhase < Base
        def perform
          workflow = target_workflow
          return skipped("Workflow no longer exists") unless workflow
          return skipped("Workflow is #{workflow.state}, not running") unless workflow.running?
          return skipped("Workflow is not resource-admission paused") unless WorkflowAdmissionCapacityWakeup.admission_or_resource_paused?(workflow)

          step_id = plan.preconditions["phase_step_id"]
          step = workflow.steps.find_by(id: step_id)
          return skipped("Paused phase step no longer exists") unless step
          return skipped("Paused phase step is #{step.state}, not queued") unless step.queued?
          return skipped("Paused phase step already has a Run") if step.runs.exists?

          before_run_ids = step.runs.pluck(:id)
          result = WorkUnits::DeferredPhaseResume.call(workflow.id, step.id)

          step.reload
          new_run = result.run || step.runs.where.not(id: before_run_ids).order(:id).last
          if new_run
            success("resumed deferred phase for Workflow ##{workflow.id} with Run ##{new_run.id}")
          elsif result.blocked? || WorkflowAdmissionCapacityWakeup.admission_or_resource_paused?(workflow.reload)
            skipped("phase remains paused after admission recheck")
          else
            success("cleared deferred phase block for Workflow ##{workflow.id}")
          end
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
            WorkUnits::StartBlock.for(workflow).reason ||
            "landing start blocked: workflow admission budget"
          reason = "workflow admission budget" if reason == StepDispatcher::ADMISSION_BLOCK_REASON
          reason = "landing start blocked: #{reason}" unless LandingQueueReentry.landing_start_blocker?(reason)

          with_transition_reason do
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
          return skipped("Workflow is #{workflow.trigger_kind}, not retry") unless retry_workflow_attempt?(workflow)

          attempt_id = workflow.artifact("auto_retry_attempt_id")
          attempt = AutoRetryAttempt.find_by(id: attempt_id)
          return skipped("Workflow is missing its auto-retry attempt") unless attempt
          return skipped("Source workflow is not superseded") unless source_superseded?(workflow.job, attempt.workflow)

          with_transition_reason do
            workflow.artifacts = (workflow.artifacts || {}).merge(
              "retry_cancelled_reason" => "stale_auto_retry",
              "retry_cancelled_at" => Time.current.iso8601
            )
            WorkUnits::WorkflowCancellation.cancel!(
              workflow,
              reason: "stale_auto_retry",
              artifacts: workflow.artifacts
            )
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

        def retry_workflow_attempt?(workflow)
          definition = WorkDefinitions.for(workflow.work_unit&.kind || workflow.trigger_kind)
          definition.retry_workflow_attempt?
        rescue WorkDefinitions::UnknownKind
          false
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
          return skipped("Workflow still has active descendants") if workflow.active_descendants?

          outcome = orphaned_workflow_outcome(workflow)
          return skipped("No terminal outcome could be inferred") unless outcome

          with_transition_reason do
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
          return skipped("Workflow still has running descendants") if workflow.live_descendants?

          failed_step = workflow.steps.where(state: "failed").order(position: :desc, id: :desc).first
          return skipped("Workflow has no failed Step") unless failed_step
          return skipped("Workflow cannot transition to failed") unless workflow.may_fail?

          with_transition_reason do
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

          with_transition_reason do
            @sync_result = Steps::StateSynchronizer.from_latest_terminal_run!(step, runs: step_runs)
          end
          return skipped(@sync_result.reason) unless @sync_result.synchronized?

          success(@sync_result.reason)
        end
      end

      class CancelWorkflowForClosedJob < Base
        def perform
          workflow = target_workflow
          return skipped("Workflow no longer exists") unless workflow
          return skipped("Workflow is #{workflow.state}, not active") unless workflow.queued? || workflow.running?
          return skipped("Job is not closed") unless workflow.job&.closed?
          return skipped("Workflow cannot transition to cancelled") unless workflow.may_cancel?

          with_transition_reason do
            workflow.artifacts = (workflow.artifacts || {}).merge(
              "cancelled_reason" => "job_closed",
              "cancelled_by_reconciler_at" => Time.current.iso8601
            )
            WorkUnits::WorkflowCancellation.cancel!(
              workflow,
              reason: "job_closed",
              artifacts: workflow.artifacts
            )
          end

          success("cancelled Workflow ##{workflow.id} because Job ##{workflow.job_id} is closed")
        end
      end

      class FinishWorkUnitForClosedJob < Base
        def perform
          unit = target_work_unit
          return skipped("WorkUnit no longer exists") unless unit
          return skipped("WorkUnit is #{unit.state}, not active") unless unit.active?
          return skipped("WorkUnit is not job-scoped") unless unit.scope_type == "job"

          job = Job.find_by(id: unit.scope_id)
          return skipped("Job ##{unit.scope_id} no longer exists") unless job
          return skipped("Job ##{job.id} is #{job.state}, not closed") unless job.closed?

          workflow = unit.workflow
          if workflow&.active?
            return skipped("Workflow ##{workflow.id} is still active; closed-job workflow repair owns that cleanup")
          end

          with_transition_reason do
            if workflow&.terminal?
              unit.mark_terminal!(workflow.state)
              @message = "marked WorkUnit ##{unit.id} #{workflow.state} because closed Job ##{job.id}'s Workflow is #{workflow.state}"
            else
              unit.preempt!(reason: "job_closed")
              @message = "cancelled WorkUnit ##{unit.id} because Job ##{job.id} is closed and no Workflow is attached"
            end
          end

          success(@message)
        end
      end

      class CancelTerminalWorkflowActiveDescendants < Base
        def perform
          workflow = target_workflow
          return skipped("Workflow no longer exists") unless workflow
          return skipped("Workflow is #{workflow.state}, not terminal") unless workflow.terminal?
          return skipped("Workflow has no active descendants") unless workflow.active_descendants?

          with_transition_reason do
            workflow.cancel_active_descendants!
          end

          workflow.reload
          remaining_steps = workflow.projected_active_step_ids
          remaining_runs = workflow.runs.active.pluck(:id)
          if remaining_steps.any? || remaining_runs.any?
            failure("active descendants remain: steps=#{remaining_steps.inspect} runs=#{remaining_runs.inspect}")
          else
            success("cancelled active descendants for terminal Workflow ##{workflow.id}")
          end
        end
      end

      class ReleaseTerminalWorkUnitLocks < Base
        def perform
          unit = target_work_unit
          return skipped("WorkUnit no longer exists") unless unit
          return skipped("WorkUnit is #{unit.state}, not terminal") unless unit.terminal?

          active_locks = unit.work_unit_locks.active.to_a
          return skipped("WorkUnit has no active locks") if active_locks.empty?

          active_locks.each(&:release!)
          remaining = unit.work_unit_locks.active.pluck(:id)
          if remaining.any?
            failure("active locks remain for WorkUnit ##{unit.id}: #{remaining.inspect}")
          else
            success("released #{active_locks.size} active locks for terminal WorkUnit ##{unit.id}")
          end
        end
      end

      class CancelTerminalWorkUnitActiveChildren < Base
        def perform
          parent = target_work_unit
          return skipped("Parent WorkUnit no longer exists") unless parent
          return skipped("Parent WorkUnit is #{parent.state}, not terminal") unless parent.terminal?

          child_ids = Array(plan.preconditions["child_work_unit_ids"]).map(&:to_i).select(&:positive?)
          children = WorkUnit.includes(:workflow, :work_unit_locks).where(id: child_ids, parent_work_unit_id: parent.id).to_a
          active_children = children.select(&:active?)
          return skipped("Parent WorkUnit has no active children") if active_children.empty?

          active_children.each { |child| cancel_child_work_unit!(child) }

          remaining_ids = WorkUnit.where(id: child_ids, parent_work_unit_id: parent.id, state: WorkUnits::Ownership::ACTIVE_STATES).pluck(:id)
          if remaining_ids.any?
            failure("active child WorkUnits remain for terminal parent ##{parent.id}: #{remaining_ids.inspect}")
          else
            success("cancelled #{active_children.size} active child WorkUnit(s) for terminal parent ##{parent.id}")
          end
        end

        private

        def cancel_child_work_unit!(child)
          workflow = child.workflow
          if workflow&.may_cancel?
            with_transition_reason do
              WorkUnits::WorkflowCancellation.cancel!(
                workflow,
                reason: "terminal_parent_work_unit",
                artifacts: {
                  "cancelled_reason" => "terminal_parent_work_unit",
                  "cancelled_by_reconciler_at" => Time.current.iso8601
                }
              )
            end
            return
          end

          child.preempt!(reason: "terminal_parent_work_unit")
        end
      end

      class CancelActiveWorkUnitWithoutWorkflow < Base
        def perform
          unit = target_work_unit
          return skipped("WorkUnit no longer exists") unless unit
          return skipped("WorkUnit is #{unit.state}, not active") unless unit.active?
          return skipped("WorkUnit already has Workflow ##{unit.workflow_id}") if unit.workflow_id.present?

          unit.preempt!(reason: "missing_workflow")
          remaining_lock_ids = unit.work_unit_locks.active.pluck(:id)
          if remaining_lock_ids.any?
            failure("cancelled WorkUnit ##{unit.id}, but active locks remain: #{remaining_lock_ids.inspect}")
          else
            success("cancelled active WorkUnit ##{unit.id} without a Workflow")
          end
        end
      end

      class RecheckWaitingWorkIntent < Base
        def perform
          intent = target_work_intent
          return skipped("WorkIntent no longer exists") unless intent
          return skipped("WorkIntent is #{intent.state}, not waiting") unless intent.waiting?

          result = WorkIntents::Scheduler.evaluate!(intent)
          intent.reload
          if result.pass?
            success("rechecked WorkIntent ##{intent.id}; wait cleared=#{intent.requested?}")
          else
            skipped("WorkIntent ##{intent.id} still waits on #{result.reason}")
          end
        end
      end

      class ClearWaitingWorkIntentActiveUnit < Base
        def perform
          intent = target_work_intent
          return skipped("WorkIntent no longer exists") unless intent
          return skipped("WorkIntent is #{intent.state}, not waiting") unless intent.waiting?

          active_unit_ids = intent.work_units
            .where(state: WorkIntents::TerminalUnitSync::ACTIVE_UNIT_STATES)
            .pluck(:id)
          return skipped("WorkIntent ##{intent.id} no longer has active WorkUnits") if active_unit_ids.empty?

          intent.request!
          success("cleared stale wait on WorkIntent ##{intent.id}; active WorkUnits: #{active_unit_ids.inspect}")
        end
      end

      class LaunchRequestedWorkIntent < Base
        def perform
          intent = target_work_intent
          return skipped("WorkIntent no longer exists") unless intent
          return skipped("WorkIntent is #{intent.state}, not requested") unless intent.requested?

          result = WorkIntents::Scheduler.start_ready!(
            intent,
            artifacts: latest_artifacts_for(intent),
            agent_provider: latest_agent_provider_for(intent)
          )

          if result.already_active?
            skipped("WorkIntent ##{intent.id} already has #{result.reason}")
          elsif result.waiting?
            skipped("WorkIntent ##{intent.id} now waits on #{result.reason}")
          elsif result.blocked?
            success("launched WorkIntent ##{intent.id} as blocked WorkUnit ##{result.work_unit&.id}: #{result.reason}")
          else
            success("launched WorkIntent ##{intent.id} as Workflow ##{result.workflow.id}")
          end
        end

        private

        def latest_artifacts_for(intent)
          latest_workflow_for(intent)&.artifacts.presence || intent.payload_artifacts.presence || {}
        end

        def latest_agent_provider_for(intent)
          latest_workflow_for(intent)&.agent_provider
        end

        def latest_workflow_for(intent)
          @latest_workflow_for ||= {}
          @latest_workflow_for[intent.id] ||= intent.work_units
            .includes(:workflow)
            .order(created_at: :desc, id: :desc)
            .map(&:workflow)
            .compact
            .first
        end
      end

      class WakeDispatcherForRequestedWorkIntent < Base
        def perform
          intent = target_work_intent
          return skipped("WorkIntent no longer exists") unless intent
          return skipped("WorkIntent is #{intent.state}, not requested") unless intent.requested?

          dispatcher = plan.preconditions["dispatcher"].to_s
          return skipped("unsupported dispatcher #{dispatcher.inspect}") unless dispatcher == "landing_queue"

          LandingQueueProcessorJob.perform_later
          success("woke landing queue for WorkIntent ##{intent.id} (#{intent.kind})")
        end
      end

      class SatisfyWorkIntentFromSucceededWorkUnit < Base
        def perform
          intent = target_work_intent
          return skipped("WorkIntent no longer exists") unless intent
          return skipped("WorkIntent is #{intent.state}, not requested/waiting") unless intent.requested? || intent.waiting?

          unit_id = plan.preconditions["work_unit_id"]
          unit = WorkUnit.find_by(id: unit_id)
          return skipped("WorkUnit ##{unit_id} no longer exists") unless unit
          return skipped("WorkUnit ##{unit.id} belongs to WorkIntent ##{unit.work_intent_id}, not ##{intent.id}") unless unit.work_intent_id == intent.id
          return skipped("WorkUnit ##{unit.id} is #{unit.state}, not succeeded") unless unit.succeeded?

          active_sibling_ids = intent.work_units
            .where(state: WorkIntents::TerminalUnitSync::ACTIVE_UNIT_STATES)
            .where.not(id: unit.id)
            .pluck(:id)
          return skipped("WorkIntent ##{intent.id} still has active WorkUnits: #{active_sibling_ids.inspect}") if active_sibling_ids.any?

          intent.satisfy!
          success("satisfied WorkIntent ##{intent.id} from succeeded WorkUnit ##{unit.id}")
        end
      end

      class CancelWorkIntentFromSupersededWorkUnit < Base
        def perform
          intent = target_work_intent
          return skipped("WorkIntent no longer exists") unless intent
          return skipped("WorkIntent is #{intent.state}, not requested/waiting") unless intent.requested? || intent.waiting?

          unit_id = plan.preconditions["work_unit_id"]
          unit = WorkUnit.find_by(id: unit_id)
          return skipped("WorkUnit ##{unit_id} no longer exists") unless unit
          return skipped("WorkUnit ##{unit.id} belongs to WorkIntent ##{unit.work_intent_id}, not ##{intent.id}") unless unit.work_intent_id == intent.id
          return skipped("WorkUnit ##{unit.id} is #{unit.state}, not cancelled") unless unit.cancelled?

          expected_reason = plan.preconditions["preemption_reason"].to_s
          allowed_reasons = WorkIntents::TerminalUnitSync::SUPERSEDING_CANCEL_REASONS
          return skipped("WorkUnit ##{unit.id} preemption reason #{unit.preemption_reason.inspect} is not superseding") unless allowed_reasons.include?(unit.preemption_reason.to_s)
          return skipped("WorkUnit ##{unit.id} preemption reason changed from #{expected_reason.inspect} to #{unit.preemption_reason.inspect}") if expected_reason.present? && unit.preemption_reason.to_s != expected_reason

          active_sibling_ids = intent.work_units
            .where(state: WorkIntents::TerminalUnitSync::ACTIVE_UNIT_STATES)
            .where.not(id: unit.id)
            .pluck(:id)
          return skipped("WorkIntent ##{intent.id} still has active WorkUnits: #{active_sibling_ids.inspect}") if active_sibling_ids.any?

          intent.cancel!
          success("cancelled WorkIntent ##{intent.id} from superseded WorkUnit ##{unit.id}")
        end
      end

      class CancelSupersededActiveWorkflow < Base
        def perform
          workflow = target_workflow
          return skipped("Workflow no longer exists") unless workflow
          return skipped("Workflow is #{workflow.state}, not active") unless workflow.queued? || workflow.running?
          return skipped("Workflow cannot transition to cancelled") unless workflow.may_cancel?

          keeper_id = plan.preconditions["keeper_workflow_id"]
          keeper = Workflow.find_by(id: keeper_id)
          return skipped("Keeper Workflow ##{keeper_id} is no longer active") unless keeper&.queued? || keeper&.running?
          return skipped("Keeper Workflow ##{keeper.id} belongs to a different Job") unless keeper.job_id == workflow.job_id
          return skipped("Workflow ##{workflow.id} is not older than keeper Workflow ##{keeper.id}") unless workflow.created_at < keeper.created_at || (workflow.created_at == keeper.created_at && workflow.id < keeper.id)

          with_transition_reason do
            workflow.artifacts = (workflow.artifacts || {}).merge(
              "cancelled_reason" => Workflow::SUPERSEDED_BY_NEWER_WORKFLOW_REASON,
              "cancelled_by_reconciler_at" => Time.current.iso8601,
              "cancelled_details" => {
                "keeper_workflow_id" => keeper.id,
                "keeper_workflow_slug" => keeper.slug,
                "keeper_trigger_kind" => keeper.trigger_kind
              }
            )
            WorkUnits::WorkflowCancellation.cancel!(
              workflow,
              reason: Workflow::SUPERSEDED_BY_NEWER_WORKFLOW_REASON,
              by_work_unit: keeper.work_unit,
              artifacts: workflow.artifacts
            )
          end

          success("cancelled superseded Workflow ##{workflow.id} because newer Workflow ##{keeper.id} is active")
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

          with_transition_reason do
            workflow.artifacts = (workflow.artifacts || {}).merge(
              "cancelled_reason" => EpicWorkflowLock::BLOCK_REASON,
              "cancelled_by_reconciler_at" => Time.current.iso8601,
              "cancelled_details" => {
                "keeper_workflow_id" => keeper.id,
                "keeper_workflow_slug" => keeper.slug,
                "keeper_trigger_kind" => keeper.trigger_kind
              }
            )
            WorkUnits::WorkflowCancellation.cancel!(
              workflow,
              reason: EpicWorkflowLock::BLOCK_REASON,
              by_work_unit: keeper.work_unit,
              artifacts: workflow.artifacts
            )
          end

          success("cancelled Workflow ##{workflow.id} because Epic-wide Workflow ##{keeper.id} is active")
        end
      end

      class DeferOrphanedLandingJob < Base
        def perform
          job = target_job
          return skipped("Job no longer exists") unless job
          return skipped("Job is #{job.state}, not landing") unless job.landing?
          return skipped("Job is owned by active landing work") if active_landing_work_for_job?(job)
          return skipped("Job cannot transition to approved") unless job.may_defer_landing?

          with_transition_reason do
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
          return skipped("worker_died failure already created active replacement work") if active_runtime_work_for_job?(target_job)

          schedule_auto_retry!(retry_kind: "failed_step")
        end
      end

      class MarkWorkerDiedAndRetryWorkflow < Base
        def perform
          result = mark_worker_died!
          return result unless result.status == "applied"
          return skipped("worker_died failure already created active replacement work") if active_runtime_work_for_job?(target_job)

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

      class CancelWorkIntentForClosedJob < Base
        def perform
          intent = target_work_intent
          return skipped("WorkIntent no longer exists") unless intent
          return skipped("WorkIntent is #{intent.state}, not requested/waiting") unless intent.requested? || intent.waiting?
          return skipped("WorkIntent is not job-scoped") unless intent.scope_type == "job"

          job = Job.find_by(id: intent.scope_id)
          return skipped("Job ##{intent.scope_id} no longer exists") unless job
          return skipped("Job ##{job.id} is #{job.state}, not closed") unless job.closed?

          active_unit_ids = intent.work_units
            .where(state: WorkIntents::TerminalUnitSync::ACTIVE_UNIT_STATES)
            .pluck(:id)
          return skipped("WorkIntent ##{intent.id} still has active WorkUnits: #{active_unit_ids.inspect}") if active_unit_ids.any?

          intent.cancel!
          success("cancelled WorkIntent ##{intent.id} because Job ##{job.id} is closed")
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

      class FailImplementedJobMissingPr < Base
        def perform
          job = target_job
          return skipped("Job no longer exists") unless job
          return skipped("Job is #{job.state}, not implemented") unless job.implemented?
          return skipped("Job already has a tracked PR") if job.pr_number.present? || job.external_pr_number.present? || job.fork_review_pr_number.present?
          return skipped("Job has active work") if active_runtime_work_for_job?(job)

          latest_workflow = job.latest_workflow
          return skipped("Latest Workflow is not terminal") unless latest_workflow && %w[succeeded failed cancelled].include?(latest_workflow.state)
          review_publication_step_kinds = review_publication_step_kinds_for(latest_workflow)
          return skipped("Latest Workflow has no review publication policy") if review_publication_step_kinds.empty?
          return skipped("Latest Workflow did not include a review publication Step") unless latest_workflow.steps.where(kind: review_publication_step_kinds).exists?
          return skipped("Latest Workflow has a succeeded review publication Step") if latest_workflow.steps.where(kind: review_publication_step_kinds, state: "succeeded").exists?
          return skipped("Job cannot transition to failed") unless job.may_force_fail?

          with_transition_reason do
            job.force_fail!
            job.save!
          end
          success("marked Job ##{job.id} failed because it was implemented without a tracked PR")
        end
      end

      class FailApprovedJobMissingPr < Base
        def perform
          job = target_job
          return skipped("Job no longer exists") unless job
          return skipped("Job is #{job.state}, not approved") unless job.approved?
          return skipped("Job already has a tracked PR") if job.pr_number.present? || job.external_pr_number.present? || job.fork_review_pr_number.present?
          return skipped("Job is internal infrastructure") if job.infrastructure_job? || job.main_branch_repair?
          return skipped("Job has active work") if active_runtime_work_for_job?(job)
          return skipped("Job cannot transition to failed") unless job.may_force_fail?

          with_transition_reason do
            job.force_fail!
            job.save!
          end
          success("marked Job ##{job.id} failed because it was approved without a tracked PR")
        end
      end

      class RetryJobAfterEpicWorkflowConflict < Base
        def perform
          job = target_job
          return skipped("Job no longer exists") unless job
          return skipped("Job is #{job.state}, not queued") unless job.queued?
          return skipped("Job has active work") if active_runtime_work_for_job?(job)

          latest = job.latest_workflow
          return skipped("Latest Workflow is not cancelled") unless latest&.cancelled?
          return skipped("Latest Workflow was not cancelled by an Epic-wide workflow lock") unless latest.artifact("cancelled_reason") == EpicWorkflowLock::BLOCK_REASON
          return skipped("Epic-wide workflow is still active") if active_epic_wide_workflow_for_job?(job)
          return skipped("Dependencies are still not ready for execution") unless job.dependencies_satisfied_for_execution?

          result = retry_cancelled_workflow(job, latest, retry_reason: "epic_workflow_conflict_recovered")
          return skipped(result.error) unless result.success?

          success("started #{result.workflow.trigger_kind} Workflow ##{result.workflow.id} for Job ##{job.id} after Epic-wide workflow conflict cleared")
        end

        private
      end

      class RetryJobAfterCancelledWorkflow < Base
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
          return skipped("Job has active work") if active_runtime_work_for_job?(job)

          latest = job.latest_workflow
          return skipped("Latest Workflow is not cancelled") unless latest&.cancelled?
          return skipped("Latest Workflow trigger_kind is not recoverable") unless recoverable_cancelled_workflow?(latest)
          return skipped("Latest Workflow was cancelled by an Epic-wide workflow lock") if cancelled_workflow_reason(latest) == EpicWorkflowLock::BLOCK_REASON
          return skipped("Latest Workflow cancellation appears deliberate") if deliberate_cancelled_workflow?(latest)
          return skipped("Epic-wide workflow is still active") if active_epic_wide_workflow_for_job?(job)
          return skipped("Dependencies are still not ready for execution") unless job.dependencies_satisfied_for_execution?

          result = retry_cancelled_workflow(job, latest, retry_reason: "cancelled_workflow_recovered")
          return skipped(result.error) unless result.success?

          success("started #{result.workflow.trigger_kind} Workflow ##{result.workflow.id} for Job ##{job.id} after cancelled Workflow ##{latest.id}")
        end

        private

        def recoverable_cancelled_workflow?(workflow)
          WorkDefinitions.for(workflow.work_unit&.kind || workflow.trigger_kind).recoverable_cancelled_workflow?
        rescue WorkDefinitions::UnknownKind
          false
        end

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
      end

      class CloseCompletedInfrastructureJob < Base
        def perform
          job = target_job
          return skipped("Job no longer exists") unless job
          closure_reason = completed_internal_closure_reason(job)
          return skipped("Job is not a completed internal job") unless closure_reason
          return skipped("Job is already closed") if job.closed?
          return skipped("Job cannot close") unless job.may_close?

          with_transition_reason do
            job.close_with_reason!(closure_reason)
          end
          success("closed completed #{job.kind} Job ##{job.id}")
        end

        private

        def completed_internal_closure_reason(job)
          return job.kind if job.infrastructure_job?

          expected_reason = plan.preconditions["closure_reason"].to_s
          return unless expected_reason == "preflight_passed"
          return unless job.main_branch_repair?

          latest_workflow = job.latest_workflow
          return unless latest_workflow&.trigger_kind == "main_branch_repair"
          return unless latest_workflow.succeeded?
          return unless latest_workflow.artifact("preflight_passed")
          return if job.pr_number.present? || job.external_pr_number.present?

          expected_reason
        end
      end
    end
  end
end
