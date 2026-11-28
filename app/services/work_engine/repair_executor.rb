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

        def job_label(job)
          job.slug
        end

        def workflow_label(workflow)
          workflow&.slug || "Workflow missing"
        end

        def cancelled_workflow_reason(workflow)
          workflow.artifact("start_cancelled_reason").presence || workflow.artifact("cancelled_reason")
        end

        def workflow_id_label(id)
          id.present? ? "WF-#{id}" : "Workflow missing"
        end

        def step_label(step)
          step&.slug || "Step missing"
        end

        def run_label(run)
          run&.slug || "Run missing"
        end

        def work_unit_label(unit)
          unit&.slug || "WorkUnit missing"
        end

        def work_unit_id_label(id)
          id.present? ? "WU-#{id}" : "WorkUnit missing"
        end

        def work_unit_id_list_label(ids)
          Array(ids).map { |id| work_unit_id_label(id) }.inspect
        end

        def work_intent_label(intent)
          intent&.slug || "WorkIntent missing"
        end

        def work_intent_id_label(id)
          id.present? ? "WI-#{id}" : "WorkIntent missing"
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
        rescue WorkUnits::Launcher::LockConflict
          RetryWorkflowEnqueuer::Result.new(workflow: nil, error: "a workflow is already queued or running for this job", circuit: nil)
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
          target_run || target_workflow&.runs&.reorder(created_at: :desc)&.first || target_job&.runs&.reorder(created_at: :desc)&.first
        end

        def audit!(status, message = nil)
          text = "[work-engine reconciler] #{status} #{plan.action}"
          text = "#{text}: #{message}" if message.present?
          Rails.logger.info("[WorkEngine::RepairExecutor] #{text} target=#{plan.target_type}##{plan.target_id}")
          run = audit_run
          return unless run

          # After the outermost commit: the append locks the Run, and a repair
          # can run inside a transaction that already holds its Job or
          # WorkUnit (Syrus::LockOrder puts Run first). A rolled-back repair is
          # not audited as applied.
          action = plan.action
          ActiveRecord.after_all_transactions_commit do
            append_audit_once!(run, text)
          rescue StandardError => e
            Rails.logger.warn("[WorkEngine::RepairExecutor] audit failed for #{action}: #{e.class}: #{e.message}")
          end
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

          previous_provider = source_run&.agent_provider.presence || workflow.agent_provider || job.agent_provider
          classification = source_run&.run_failure_classification&.classification.presence ||
            source_run&.agent_outcome.presence ||
            "unknown"
          agent_provider = retry_agent_provider_for(
            job: job,
            previous_provider: previous_provider,
            classification: classification
          )
          provider_switched = agent_provider != previous_provider
          if retry_kind == "retry_workflow" && workflow.auto_retry_attempts.retry_workflow.pending.exists?
            return skipped("retry_workflow already pending")
          end

          skip_stale_default_provider_attempts!(
            workflow: workflow,
            previous_provider: previous_provider,
            current_provider: agent_provider,
            classification: classification
          ) if provider_switched
          retry_blocker = auto_retry_blocker_for(workflow, retry_kind, source_run)
          return skipped(retry_blocker) if retry_blocker

          account = workflow.provider_account if workflow.agent_provider == agent_provider
          account ||= workflow.user.default_provider_account(agent_provider)
          circuit_options = { now: now, include_logs: false }
          circuit_options.merge!(user: workflow.user, provider_account: account) if account
          circuit = ProviderCircuitBreaker.call(agent_provider, **circuit_options)
          if respect_provider_circuit && circuit.open?
            retry_at = circuit.retry_after ? " until #{circuit.retry_after.iso8601}" : ""
            return skipped("provider circuit is open for #{agent_provider}#{retry_at}: #{circuit.reason}")
          end

          attempt = nil
          locked_skip = nil
          scheduled_at = provider_switched ? now : (plan.retry_after || now)
          # Ancestry first, top down (NY40): cancelling rolls up to the Job.
          Workflow.transaction do
            Lineage.lock!(workflow)
            workflow.reload(lock: true)
            # The dedupe and budget reads below are locking reads: Lineage's
            # plain discovery reads fixed this transaction's REPEATABLE READ
            # snapshot before it waited on the Workflow lock, so a plain read
            # would miss an attempt a concurrent scheduler (an in-place Step
            # retry, another repair) committed while this one waited, and
            # schedule a second retry for the same failure or overrun the
            # budget.
            retry_blocker = auto_retry_blocker_for(workflow, retry_kind, source_run, lock: true)
            if retry_blocker
              locked_skip = skipped(retry_blocker)
            elsif delayed_retry_already_scheduled?(
              workflow: workflow,
              source_run: source_run,
              classification: classification,
              retry_kind: retry_kind,
              scheduled_at: scheduled_at,
              lock: true
            )
              locked_skip = skipped("retry already pending until #{scheduled_at.iso8601}")
            else
              attempt_number = AutoRetryAttempt.budget_scope_for(
                job: job,
                agent_provider: agent_provider,
                failure_classification: classification
              ).lock.count + 1
              if attempt_number > retry_budget_limit(classification)
                locked_skip = skipped("retry budget exhausted for #{agent_provider}/#{classification}")
              else
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
              end
            end
          end
          return locked_skip if locked_skip

          WorkUnits::AutoRetryBackoff.record!(attempt)
          AutoRetryJob.set(wait_until: scheduled_at, priority: job.solid_queue_priority).perform_later(attempt.id)
          success("scheduled #{retry_kind} auto-retry attempt ##{attempt.id} for #{scheduled_at.iso8601}")
        rescue ActiveRecord::RecordNotUnique
          skipped(retry_kind == "retry_workflow" ? "retry_workflow already scheduled for workflow" : "retry already pending")
        end

        def retry_agent_provider_for(job:, previous_provider:, classification:)
          return previous_provider unless classification == ProviderUsageLimit::CLASSIFICATION
          return previous_provider unless job&.job_provider_setting_default?

          job.workflow_agent_provider.presence || previous_provider
        end

        def skip_stale_default_provider_attempts!(workflow:, previous_provider:, current_provider:, classification:)
          return unless previous_provider.present? && current_provider.present?

          workflow.auto_retry_attempts
            .pending
            .where(agent_provider: previous_provider, failure_classification: classification)
            .find_each do |attempt|
              attempt.skip_stale_pending!(
                "default provider changed from #{previous_provider} to #{current_provider}; reconciler will retry with #{current_provider}"
              )
            end
        end

        def retry_budget_limit(classification)
          AutoRetryAttempt.retry_budget_limit_for(classification)
        end

        DELAYED_RETRY_DEDUP_CLASSIFICATIONS = [ "rate_limited", ProviderUsageLimit::CLASSIFICATION ].freeze

        def delayed_retry_already_scheduled?(workflow:, source_run:, classification:, retry_kind:, scheduled_at:, lock: false)
          if classification == AutoRetryAttempt::WORKER_DIED_CLASSIFICATION
            return worker_died_retry_already_scheduled?(workflow: workflow, source_run: source_run, retry_kind: retry_kind, lock: lock)
          end
          return false unless classification.in?(DELAYED_RETRY_DEDUP_CLASSIFICATIONS)
          return false unless scheduled_at&.future?

          scope = auto_retry_attempts_of(workflow, lock: lock)
            .unskipped
            .where(
              run: source_run,
              retry_kind: retry_kind,
              failure_classification: classification
            )
            .where("scheduled_at >= ?", now)

          scope.exists?
        end

        # A shared idempotency key across retry_workflow/failed_step/resume_failed_step:
        # once ANY retry has been scheduled for a specific failed Run (pending or already
        # performed), no other retry_kind may be scheduled for that same Run. Without this,
        # separate repair paths -- mark_worker_died_and_resume_failed_step, then the plain
        # resume_failed_step/retry_failed_step/retry_workflow issue-driven repairs -- can
        # each independently decide "no pending attempt on the workflow" is true (true only
        # because the earlier attempt already flipped from pending to performed) and schedule
        # a second, overlapping retry for the exact same failure. Scoped to the Run (not the
        # Job) so unrelated sibling Runs -- e.g. other grader_fanout Steps still running in
        # the same Workflow -- are never blocked by this check.
        # worker_died can be (re)detected by more than one issue classifier for
        # the same still-failed Run in one reconciler pass -- e.g. a missing
        # resumable session and a worker_died failure classification both
        # propose the same repair, one with an immediate scheduled_at and one
        # backed off. Keep an explicit worker_died delayed-retry guard too so
        # delayed scheduling remains idempotent independent of scheduled_at.
        def worker_died_retry_already_scheduled?(workflow:, source_run:, retry_kind:, lock: false)
          auto_retry_attempts_of(workflow, lock: lock)
            .unskipped
            .where(run: source_run, retry_kind: retry_kind, failure_classification: AutoRetryAttempt::WORKER_DIED_CLASSIFICATION)
            .exists?
        end

        def auto_retry_blocker_for(workflow, retry_kind, source_run, lock: false)
          return "retry already pending" if auto_retry_attempts_of(workflow, lock: lock).pending.exists?
          if (existing = existing_unskipped_attempt_for_run(workflow, source_run, lock: lock))
            return "#{existing.retry_kind} auto-retry ##{existing.id} was already scheduled for this Run"
          end
          return nil unless retry_kind == "retry_workflow"

          "retry_workflow already scheduled for workflow" if AutoRetryAttempt.retry_workflow_scheduled_for?(workflow, lock: lock)
        end

        def existing_unskipped_attempt_for_run(workflow, source_run, lock: false)
          return nil unless source_run

          auto_retry_attempts_of(workflow, lock: lock).unskipped.where(run: source_run).order(:id).first
        end

        # lock: true inside a transaction that holds row locks: a locking read
        # returns the latest committed attempts, not the transaction's snapshot.
        def auto_retry_attempts_of(workflow, lock: false)
          lock ? workflow.auto_retry_attempts.lock : workflow.auto_retry_attempts
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
          orphan_running_spawned_processes_for!(run)
          if (replacement_run = worker_died_replacement_run(run, existing_run_ids: existing_run_ids))
            return success("marked #{run_label(run)} worker_died; queued replacement #{run_label(replacement_run)} on #{step_label(run.step)}")
          end

          success("marked #{run_label(run)} worker_died; no automatic retry was scheduled, leaving follow-up to terminal-state reconciliation or operator review")
        end

        def orphan_running_spawned_processes_for!(run)
          SpawnedProcess.running.where(run_id: run.id).update_all(
            finished_at: Time.current,
            outcome: "orphaned",
            updated_at: Time.current
          )
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

      class RecoverMissingWorkspace < Base
        def perform
          workflow = target_workflow
          return skipped("Workflow no longer exists") unless workflow
          return skipped("Workflow is no longer active") unless workflow.running? || workflow.queued?
          return skipped("workspace is already present") if File.directory?(WorkflowWorkspace.path_for(workflow))
          # The plan may predate a heartbeat from the owning worker; re-check
          # before failing a Run that worker may still be executing.
          return skipped("workspace is held by another worker") if WorkflowWorkspace.remote_owner_may_hold_workspace?(workflow)

          record_storage_loss!(workflow)
          result = WorkflowWorkspaceRecovery.call(workflow: workflow)
          return success(result.message) if result.recovered?

          fail_for_retry!(workflow, result.message)
          success("workspace reconstruction was unsafe; failed the attempt for automatic retry: #{result.message}")
        end

        WORKSPACE_RECOVERY_SUMMARY =
          "The workflow workspace could not be reconstructed safely from durable state.".freeze

        def fail_for_retry!(workflow, reason)
          now = Time.current
          workflow.set_artifact!("failure_reason", "workspace_recovery_failed")
          workflow.set_artifact!("workspace_recovery_failure", {
            "classification" => "workspace_recovery_failed",
            "retryable" => true,
            "reason" => reason,
            "failed_at" => now.iso8601
          })
          active_runs = workflow.runs.active.to_a
          active_runs.each { |run| declare_workspace_recovery_failure!(workflow, run, reason, now) }
          workflow.runs.active.update_all(state: "failed", finished_at: now, agent_outcome: "workspace_recovery_failed", updated_at: now)
          failed_step_ids = active_runs.map(&:step_id).compact.uniq
          workflow.steps.active.where(id: failed_step_ids).update_all(state: "failed", finished_at: now, updated_at: now)
          workflow.finished_at = now
          workflow.fail! if workflow.may_fail?
          workflow.cancel_active_descendants!(reason: "workspace_recovery_failed")
          schedule_auto_retry!(
            retry_kind: "retry_workflow",
            source_run: active_runs.last,
            workflow: workflow,
            job: workflow.job,
            respect_provider_circuit: false
          )
        end

        # This verdict has to survive a re-derivation. AutoRetryJob
        # re-classifies before it will act on the retry scheduled below, and
        # these Runs carry no exception and no agent output -- this method is
        # what ended them -- so there is nothing for a classifier to work from.
        # It used to fall through every branch to `application_error,
        # retryable: false`, overwrite what is written here, and skip the retry
        # as "failure is not retryable"; the Job then stayed failed with
        # failure_count 0 and never got a second attempt. The same happened
        # when the Run did carry text: a grader this repair killed mid-run
        # left "grader X failed", which re-classified as a non-retryable
        # grader_failure. The verdict is therefore marked as the repair's
        # (RunFailureClassification.repair_inputs), and
        # RunFailureClassifier.persist! never re-derives over it.
        def declare_workspace_recovery_failure!(workflow, run, reason, now)
          classifier_inputs = RunFailureClassification.repair_inputs(
            "work_engine_repair:recover_missing_workspace",
            "workflow_id" => workflow.id,
            "workspace_lifecycle_state" => workflow.workspace_lifecycle_state
          )

          classification = run.run_failure_classification || run.build_run_failure_classification
          classification.assign_attributes(
            classification: "workspace_recovery_failed",
            retryable: true,
            confidence: 1.0,
            reason: reason,
            diagnostic_summary: WORKSPACE_RECOVERY_SUMMARY,
            classifier_inputs: classifier_inputs,
            classified_at: now
          )
          classification.save!
        end

        def record_storage_loss!(workflow)
          if workflow.worker_hostname.present? || workflow.worker_storage_key.present?
            WorkflowWorkspaceLifecycle.clear_routing_affinity!(
              workflow,
              actor: "work_engine_repair",
              reason: "workspace missing from inactive storage owner"
            )
          elsif workflow.workspace_lifecycle_state != "storage_lost"
            WorkflowWorkspaceLifecycle.storage_lost!(
              workflow,
              actor: "work_engine_repair",
              reason: "active workflow workspace is missing"
            )
          end
        end
      end

      class ReenqueueRun < Base
        def perform
          run = target_run
          return skipped("Run no longer exists") unless run
          return skipped("Run is #{run.state}, not queued") unless run.queued?
          return skipped("Workflow is not active") unless run.workflow&.queued? || run.workflow&.running?
          return skipped("retry already pending for workflow") if run.workflow.auto_retry_attempts.pending.exists?
          return skipped("required grader conclusion already cached failed for this commit") if blocked_by_cached_grader_failure?(run)

          # Ancestry first, top down (NY40): relaunching writes the Workflow.
          Run.transaction do
            Lineage.lock!(run)
            run.reload(lock: true)
            return skipped("Run is #{run.state}, not queued") unless run.queued?
            return skipped("Workflow is not active") unless run.workflow&.queued? || run.workflow&.running?
            # A locking read, not the snapshot Lineage's discovery reads fixed.
            return skipped("retry already pending for workflow") if run.workflow.auto_retry_attempts.pending.lock.exists?
            return skipped("required grader conclusion already cached failed for this commit") if blocked_by_cached_grader_failure?(run)

            old_queue = nil
            if plan.issue_kind == "queued_run_on_dead_resume_queue"
              old_queue = remove_stranded_affinity_queue(run)
              return skipped("affinity queue is no longer stranded") unless old_queue
            end

            # A wedged claim needs the same treatment as a dead resume queue, for
            # the opposite reason: the worker is still heartbeating, so routing
            # would hand the Run straight back to the storage key it is stuck
            # on and the repair would loop. Delete the existing queue rows
            # before dropping affinity so no old resume-queue job can stamp the
            # same storage key back onto the workflow while repair is running.
            # Dropping affinity then sends the replacement to the general queue
            # (the workspace is re-prepared, as it is for a dead queue).
            if plan.issue_kind.in?(%w[queued_run_on_dead_resume_queue queued_run_with_wedged_queue_claim queued_run_with_orphaned_queue_job queued_run_host_admission_deferral_budget_exhausted queued_run_in_healthy_reenqueue_loop])
              delete_stale_solid_queue_jobs! unless old_queue
              clear_dead_resume_affinity!(run)
            end
            run.reenqueue!(ignore_workflow_affinity: old_queue.present?)
            message = "re-enqueued #{run_label(run)}"
            message += " from #{old_queue} after clearing stale affinity" if old_queue
            success(message)
          end
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

        def clear_dead_resume_affinity!(run)
          workflow = run.workflow
          return unless workflow

          WorkflowWorkspaceLifecycle.clear_routing_affinity!(
            workflow,
            actor: "work_engine_repair",
            reason: plan.issue_kind.humanize(capitalize: false)
          )
          run.step&.association(:workflow)&.reset
          run.association(:step).reset
          run.association(:job).reset
        end

        # The plan is based on a point-in-time queue snapshot. Re-read the
        # exact affected execution immediately before deleting it: a worker may
        # have resumed heartbeating, or another repair may already have removed
        # or claimed the row. Either race makes this repair a no-op.
        def remove_stranded_affinity_queue(run)
          old_queue = nil
          job_ids = Array(plan.affected_ids["solid_queue_job_ids"])
          return unless job_ids.one?

          deleted = SolidQueueRunJobPruner.delete_ready_job_if!(job_ids.first) do |queue_job|
            next false unless queue_job.class_name == "RunJob"
            next false unless SolidQueueRunJobQuery.matching(scope: SolidQueue::Job.where(id: queue_job.id), run_id: run.id).any?
            next false unless queue_job.queue_name.to_s.start_with?("resume-", "worker-")

            diagnosis = RunQueueDiagnosis.call(run)
            next false unless diagnosis&.dig(:kind).in?(%w[ready_no_consumer no_live_workers])
            next false unless diagnosis.dig(:details, :queue_name) == queue_job.queue_name

            old_queue = queue_job.queue_name
            true
          end
          old_queue if deleted
        rescue NameError, ActiveRecord::StatementInvalid
          nil
        end

        def delete_stale_solid_queue_jobs!
          SolidQueueRunJobPruner.delete_job_ids!(plan.affected_ids["solid_queue_job_ids"])
        rescue NameError, ActiveRecord::StatementInvalid => e
          Rails.logger.warn("[WorkEngine::RepairExecutor] failed to delete stale SolidQueue jobs for dead resume queue: #{e.class}: #{e.message}")
        end
      end

      # workflow-engine-v3 C2. What ReapClassifierPendingJob used to do on its
      # own timer, expressed as a repair the engine plans and audits like any
      # other -- so intake stops having a private copy of stale-work reaping.
      class ReclassifyStalledIntake < Base
        def perform
          job_ids = Array(plan.affected_ids["job_ids"])
          return skipped("no stalled intake Jobs") if job_ids.empty?

          reclassified = 0
          blocked = 0
          Job.where(id: job_ids).find_each do |job|
            next unless job.state == "triaging"
            next unless Job::Kind.classifiable?(job.kind)

            reclassified += 1 if prepare_for_reclassification!(job)
          rescue ClassifyIssueJob::EnqueueBlockedError => e
            blocked += 1
            Rails.logger.warn("[WorkEngine::RepairExecutor] classifier repair blocked for #{job_label(job)}: #{e.message}")
          end
          return skipped("classification enqueue blocked for #{blocked} Job(s)") if reclassified.zero? && blocked.positive?
          return skipped("intake Jobs are no longer awaiting classification") if reclassified.zero?

          message = "re-enqueued classification for #{reclassified} Job(s)"
          message += "; #{blocked} Job(s) remain blocked" if blocked.positive?
          success(message)
        end

        private

        def prepare_for_reclassification!(job)
          original_reason = job.triaging_reason.to_s
          job.with_lock do
            job.reload(lock: true)
            return false unless job.triaging?
            return false unless Job::Kind.classifiable?(job.kind)
            return false unless job.classifier_attempts < Job::MAX_CLASSIFIER_ATTEMPTS

            if original_reason == "classifier_pending"
              return false unless job.triaging_reason_classifier_pending?
            else
              # An uncertain Job has to be put back in the classifier's queue
              # first: IngestionClassifier and ClassifyIssueJob both refuse to
              # run against any reason but `classifier_pending`.
              return false unless job.may_retry_classification?

              with_transition_reason { job.retry_classification! }
              job.reload(lock: true)
            end

            # Keep enqueueing in the lock transaction so a blocked enqueue
            # rolls back the uncertain-to-pending transition. Only a real
            # IngestionClassifier invocation owns the attempt counter.
            ClassifyIssueJob.enqueue_for_job!(job)
            audit_classifier_repair!(job, from_reason: original_reason, to_reason: job.triaging_reason)
          end
          true
        end

        def audit_classifier_repair!(job, from_reason:, to_reason:)
          StateTransition.create!(
            subject: job,
            from_state: job.state,
            to_state: job.state,
            event_name: "reclassify_stalled_intake",
            source: "reconciler",
            metadata: {
              "reason_key" => plan.action,
              "repair_action" => plan.action,
              "repair_reason" => plan.reason,
              "issue_kind" => plan.issue_kind,
              "from_triaging_reason" => from_reason,
              "triaging_reason" => to_reason,
              "classifier_attempts" => job.classifier_attempts
            }.compact
          )
        rescue StandardError => e
          Rails.logger.warn("[WorkEngine::RepairExecutor] failed to audit stalled intake repair for #{job_label(job)}: #{e.class}: #{e.message}")
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
          success("skipped obsolete #{run_label(run)} on terminal #{step_label(step)}")
        end
      end

      class RetryAgentBlockedWorkflow < Base
        def perform
          workflow = target_workflow
          return skipped("Workflow no longer exists") unless workflow
          return skipped("Workflow is #{workflow.state}, not blocked") unless workflow.blocked?

          result = RetryWorkflowEnqueuer.call(
            job: workflow.job,
            artifacts: {
              "retry_reason" => "agent blocker cleared by satisfied dependencies",
              "blocked_workflow_id" => workflow.id,
              "cannot_proceed" => workflow.artifact("cannot_proceed")
            },
            provider_validation: :none,
            automatic: true
          )
          return skipped(result.error) unless result.success?

          success("retried #{workflow_label(workflow)} as #{workflow_label(result.workflow)} after its added dependencies were satisfied")
        end
      end

      class CancelStarvedGrader < Base
        def perform
          run = target_run
          return skipped("Run no longer exists") unless run
          return skipped("Run is #{run.state}, not queued") unless run.queued? && run.started_at.nil?

          step = run.step
          return skipped("Run has no grader Step") unless step&.kind == "grader"
          return skipped("Step is #{step.state}, not queued") unless step.queued?
          return skipped("Workflow is not running") unless step.workflow&.running?

          # Neither cancel may cascade. A cancelled Run cancels its Workflow,
          # and a cancelled Step cancels grader_collect and the rest of the
          # chain; either way the Workflow ends cancelled -- which for a merge
          # train reads as an operator abort, skipping multisect and the
          # landing fix and clearing every member's approval. grader_collect
          # counts a cancelled required grader as unsuccessful, so it must be
          # left to judge the failure.
          #
          # A worker can claim the grader after the checks above, so they are
          # repeated under the lineage lock (which the claim also takes);
          # cancel_without_step_cascade! writes past the AASM guard and would
          # otherwise cancel a Run whose process has just started.
          cancelled = Step.suppress_cancel_cascade do
            Workflow.transaction do
              Lineage.lock!(run)
              # Locking reads: a plain reload answers from the snapshot
              # Lineage.lock! took before waiting on the claim's locks.
              run.reload(lock: true)
              step.reload(lock: true)
              workflow = Workflow.lock.find_by(id: step.workflow_id)
              next false unless run.queued? && run.started_at.nil? && step.queued? && workflow&.running?

              with_transition_reason do
                run.cancel_without_step_cascade!
                step.cancel!
                step.save!
              end
              true
            end
          end
          return skipped("#{run_label(run)} was claimed before it could be cancelled") unless cancelled

          StepDispatcher.advance_from(step.reload)
          success("cancelled starved #{run_label(run)} on #{step_label(step)}; a required sibling grader already failed")
        end
      end

      class FailRunAfterRepeatedQueueFailure < Base
        def perform
          run = target_run
          return skipped("Run no longer exists") unless run
          return skipped("Run is #{run.state}, not queued") unless run.queued?
          return skipped("Workflow is not active") unless run.workflow&.queued? || run.workflow&.running?

          error = latest_queue_error(run)
          # Keyed by run_id, as in MarkCachedGraderCollectFailed: two passes may
          # repair the same Run concurrently.
          RunDiagnostic.create_or_find_by!(run_id: run.id) do |diagnostic|
            diagnostic.error_class = error["exception_class"].presence || "RunJobCrashed"
            diagnostic.error_message = "RunJob crashed before the Run started: #{error["message"].presence || "unknown error"}".truncate(1_000)
            diagnostic.problem_code = "run_job_crashed"
          end

          with_transition_reason do
            run.fail!
            run.save!
          end
          classification = run.run_failure_classification || run.build_run_failure_classification
          classification.assign_attributes(
            classification: "run_job_crashed",
            retryable: true,
            confidence: 1.0,
            reason: "The Run's RunJob crashed #{plan.evidence.to_h["failed_executions"] || "repeatedly"} times before the Run started; " \
                    "this is the worker, not the Run's work.",
            diagnostic_summary: "#{error["exception_class"] || "RunJobCrashed"}: #{error["message"]}".truncate(500),
            classifier_inputs: RunFailureClassification.repair_inputs(
              "work_engine_repair:fail_crashed_run_job",
              "failed_executions" => plan.evidence.to_h["failed_executions"]
            ),
            classified_at: Time.current
          )
          classification.save!

          success("failed #{run_label(run)} after its RunJob crashed repeatedly (#{error["exception_class"] || "unknown"})")
        end

        private

        def latest_queue_error(run)
          raw = SolidQueue::FailedExecution
            .joins(:job)
            .where(solid_queue_jobs: { class_name: "RunJob" })
            .where("solid_queue_jobs.arguments LIKE ?", "%[#{run.id}]%")
            .order(created_at: :desc)
            .pick(:error)
          parsed = raw.is_a?(String) ? JSON.parse(raw) : raw.to_h
          parsed.to_h.stringify_keys
        rescue StandardError
          {}
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

          # Keyed by `run_id`, deliberately, not by `run:`.
          #
          # `run_diagnostics.run_id` is uniquely indexed, and two passes
          # repairing the same Run concurrently made the loser raise
          # RecordNotUnique — not out of this write, but out of `run.save!`
          # below. Passing the record assigns the candidate into Run's
          # `has_one :run_diagnostic` inverse. When the insert loses the race
          # its savepoint rolls back and the row is reloaded, but that unsaved
          # candidate stays the association target, so the Run's own save
          # autosaves it and attempts the duplicate insert a second time. The
          # bare id never touches the association, so there is nothing left
          # behind to re-insert.
          RunDiagnostic.create_or_find_by!(run_id: run.id) do |diagnostic|
            diagnostic.error_class = "Steps::Base::StepFailed"
            diagnostic.error_message = "required graders failed: cached grader conclusion failed"
          end

          with_transition_reason do
            run.agent_outcome = "grader_failure"
            run.fail!
            run.save!
          end

          success("marked cached grader_collect #{run_label(run)} failed so retry-until can continue")
        end
      end

      class ReviveCleanupCancelledStep < Base
        def perform
          step = target_step
          return skipped("Step no longer exists") unless step
          return skipped("Step is #{step.state}, not cancelled") unless step.cancelled?

          workflow = step.workflow
          return skipped("Workflow is #{workflow&.state}, not running") unless workflow&.running?
          return skipped("Workflow has an active Run") if workflow.runs.active.exists?
          unless step.details.to_h["cancelled_by"] == "terminal_workflow_cleanup" && step.runs.none? { |run| run.queued? || run.running? || run.succeeded? }
            return skipped("Step was not interrupted by failure cleanup")
          end

          step.update_columns(
            state: "queued",
            started_at: nil,
            finished_at: nil,
            cancellation_reason: nil,
            details: step.details.to_h.except(*Step::CANCELLATION_DETAIL_KEYS),
            updated_at: Time.current
          )
          resume = WorkUnits::DeferredPhaseResume.call(workflow.id, step.id)
          return success("revived #{step_label(step)} and resumed it with #{run_label(resume.run)}") if resume.run

          skipped(["revived #{step_label(step)}; its resume stayed deferred", resume.status, resume.reason].compact_blank.join(": "))
        end
      end

      class ResumeQueuedStep < Base
        def perform
          step = target_step
          return skipped("Step no longer exists") unless step
          return skipped("Step is #{step.state}, not queued") unless step.queued?
          if step.runs.exists? && !WorkEngine::Reconciler.reopened_awaiting_run_at(step)
            return skipped("Step already has a Run")
          end

          workflow = step.workflow
          return skipped("Workflow no longer exists") unless workflow
          return skipped("Workflow is #{workflow.state}, not running") unless workflow.running?

          return skipped("Upstream handoff is not ready") unless StepDispatcher.deferred_phase_handoff_ready?(step)

          resume = WorkUnits::DeferredPhaseResume.call(workflow.id, step.id)
          run = resume.run
          return success("resumed #{step_label(step)} with #{run_label(run)}") if run

          if resume.reason.to_s == WorkUnits::Gates::CiRepairSafety::REASON &&
              (cancelled = cancel_superseded_ci_repair(workflow, step))
            return success(cancelled)
          end

          # Say why. A bare "remained deferred" left workflows parked behind a
          # scheduler gate for weeks with nothing in the activity log naming
          # the gate.
          skipped(["queued Step remained deferred", resume.status, resume.reason].compact_blank.join(": "))
        end

        private

        # A CI repair that already ran `prepare` can still be held at its
        # repair step waiting for its base to be known healthy. If main has
        # moved past that base, no health check will ever grade it, so the
        # workflow would sit "running" forever -- cancel it as superseded, the
        # same outcome CancelSupersededCiRepair gives a repair still queued.
        def cancel_superseded_ci_repair(workflow, step)
          return nil unless workflow.trigger_kind == "ci_failure" && workflow.work_unit

          gate = WorkUnits::Gates::CiRepairSafety.call(workflow.work_unit, step: step)
          # A superseded base makes the repair moot whatever holds it: waiting
          # for an old base to be graded, or behind a main repair of that old
          # base -- which kept an approved Job's CI repair parked all afternoon
          # after main had moved four commits on.
          # A branch behind its base is moot the same way: it must be rebased
          # first, and the rebase preempts the repair.
          return nil unless gate.blocked?

          base_sha = gate.details["base_sha"]
          return nil unless WorkUnits::Gates::CiRepairSafety.moot_block?(workflow.job, gate.details["kind"], base_sha, since: workflow.created_at)
          return nil unless workflow.may_cancel?

          with_transition_reason do
            WorkUnits::WorkflowCancellation.cancel!(
              workflow,
              reason: WorkUnits::Gates::CiRepairSafety::SUPERSEDED_BASE_REASON,
              artifacts: {
                "cancelled_reason" => WorkUnits::Gates::CiRepairSafety::SUPERSEDED_BASE_REASON,
                "cancelled_by_reconciler_at" => Time.current.iso8601,
                "superseded_ci_repair_base_sha" => base_sha
              }
            )
          end
          "cancelled #{workflow_label(workflow)}: CI repair base #{base_sha} was superseded and will never be health-checked"
        end
      end

      class CancelUnsafeReviewBarrierRun < Base
        def perform
          run = target_run
          return skipped("Run no longer exists") unless run
          return skipped("Run is #{run.state}, not queued") unless run.queued?
          return skipped("Required review barrier is now satisfied") if Workflows::ImmutableReviewHeadBarrier.satisfied_for?(run.step)

          Workflows::ImmutableReviewHeadBarrier.cancel_run_without_cascade!(run)
          run.workflow.set_artifact!("review_head_barrier_block", {
            "code" => "required_review_head_unresolved",
            "step_id" => run.step_id,
            "run_id" => run.id,
            "recovered_by" => "work_engine_reconciler",
            "recorded_at" => now.iso8601
          })
          success("cancelled unsafe queued #{run_label(run)} before required review completion")
        end
      end

      class ReopenCancelledRetryUntilBarrier < Base
        CANCELLATION_DETAIL_KEYS = Step::CANCELLATION_DETAIL_KEYS

        def perform
          step = target_step
          return skipped("Barrier Step no longer exists") unless step
          return skipped("Barrier Step is #{step.state}, not cancelled") unless step.cancelled?
          return skipped("Barrier Step already has Runs") if step.runs.exists?
          return skipped("Step is not a retry-until barrier") unless retry_until_barrier?(step)

          workflow = step.workflow
          return skipped("Workflow no longer exists") unless workflow
          return skipped("Workflow is #{workflow.state}, not running") unless workflow.running?
          return skipped("Barrier dependencies are not settled") unless step.dependencies_settled?

          step.update_columns(
            state: "queued",
            started_at: nil,
            finished_at: nil,
            cancellation_reason: nil,
            details: step.details.to_h.except(*CANCELLATION_DETAIL_KEYS),
            updated_at: Time.current
          )

          run = StepDispatcher.create_run_and_enqueue(step.reload, workflow)
          run ? success("reopened cancelled retry-until barrier #{step_label(step)} with #{run_label(run)}") : skipped("retry-until barrier remained deferred")
        end

        private

        def retry_until_barrier?(step)
          step.loop_id.present? && Step::Kind.fetch(step.kind).fail_policy == :loop_iteration
        rescue ArgumentError
          false
        end
      end

      class ResumeReviewLoopRepair < Base
        def perform
          step = target_step
          return skipped("Step no longer exists") unless step
          return skipped("Step is #{step.state}, not succeeded") unless step.succeeded?
          return skipped("Step has no loop id") unless step.loop_id.present?

          gate = Step::Kind.review_gate_for(step.details.to_h["panel_review_kind"].presence || step.kind)
          return skipped("Step is not a review loop Step") unless gate

          workflow = step.workflow
          return skipped("Workflow no longer exists") unless workflow
          return skipped("Workflow is #{workflow.state}, not running") unless workflow.running?
          verdict = workflow.artifacts&.dig(gate.fetch(:artifact_key))&.last&.fetch("verdict", nil)
          return skipped("Review verdict no longer requires repair") if verdict.blank? || gate.fetch(:exit_verdicts).include?(verdict)

          if workflow.steps.where(loop_id: step.loop_id, iteration: step.iteration + 1).exists?
            return skipped("Repair iteration already exists")
          end

          StepDispatcher.advance_from(step.reload)
          repair = workflow.reload.steps
            .where(loop_id: step.loop_id, iteration: step.iteration + 1)
            .order(:position)
            .first
          return skipped("review loop repair remained deferred") unless repair

          success("resumed review loop repair from #{step_label(step)} with #{step_label(repair)}")
        rescue ArgumentError
          skipped("Step kind does not declare a review gate")
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

          # Ancestry first, top down (NY40): starting writes the WorkUnit.
          Workflow.transaction do
            Lineage.lock!(workflow)
            workflow.reload(lock: true)
            return skipped("Workflow is #{workflow.state}, not queued") unless workflow.queued?
            first = workflow.first_step
            return skipped("Workflow has no first Step") unless first
            return skipped("First Step already has a Run") if first.runs.exists?

            run = WorkUnits::Launcher.start!(workflow).run
            return run ? success("started #{workflow_label(workflow)} with #{run_label(run)}") : skipped("workflow start remained blocked")
          end
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
          return skipped("#{repair_job.slug} is not a main-branch repair Job") unless BaseBranchHealth.repair_job?(repair_job)

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
          run ? success("cleared stale dependency block and started #{workflow_label(workflow)} with #{run_label(run)}") : skipped("workflow start remained blocked")
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
            success("resumed deferred phase for #{workflow_label(workflow)} with #{run_label(new_run)}")
          elsif result.blocked? || WorkflowAdmissionCapacityWakeup.admission_or_resource_paused?(workflow.reload)
            skipped("phase remains paused after admission recheck")
          else
            success("cleared deferred phase block for #{workflow_label(workflow)}")
          end
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
            cancel_requesting_intent!(workflow)
          end
          WorkEngine::Reconciler.request(source: self.class.name, job: workflow.job)
          success("cancelled stale auto-retry #{workflow_label(workflow)}")
        end

        private

        # Cancelling the workflow and its WorkUnit is not enough on its own.
        # The WorkIntent behind the unit stays `requested`, and a requested
        # intent is exactly what the launcher materializes a WorkUnit from --
        # so the next pass builds another retry workflow, this repair cancels
        # that one too, and the pair loops. One intent produced seven
        # workflows this way in half an hour, each leaving a workspace behind.
        #
        # Only retired once the unit this repair just cancelled is terminal, so
        # the intent is never cancelled out from under work that is still
        # live. (`work_units.active_dedup_key` already forbids a second
        # non-terminal unit in the same scope, so that unit is the only one
        # this intent can have in flight.)
        def cancel_requesting_intent!(workflow)
          unit = WorkUnit.where(workflow_id: workflow.id).order(:id).last
          intent = unit&.work_intent
          return if intent.nil?
          return unless intent.requested? || intent.waiting?
          return unless unit.terminal?

          intent.cancel!
        end

        # The same rule the classifier and AutoRetryJob apply.
        def source_superseded?(job, source)
          return false unless job && source

          Workflows::AutoRetrySupersession.superseded?(source)
        end

        def retry_workflow_attempt?(workflow)
          definition = WorkDefinitions.for(workflow.work_unit&.kind || workflow.trigger_kind)
          definition.retry_workflow_attempt?
        rescue WorkDefinitions::UnknownKind
          false
        end
      end

      class FinishWorkflowFromTerminalDescendants < Base
        def perform
          workflow = target_workflow
          return skipped("Workflow no longer exists") unless workflow
          return skipped("Workflow is #{workflow.state}, not running") unless workflow.running?
          return skipped("Workflow still has active descendants") if workflow.active_descendants?
          return skipped("A Step is waiting for an in-place retry") if AutoRetryAttempt.pending_in_place_step_retry_in?(workflow)

          outcome = workflow.terminal_descendant_outcome
          return failure("No terminal outcome could be inferred; operator review is required") unless outcome

          with_transition_reason do
            if outcome == :succeeded
              StepDispatcher.finish_workflow!(workflow)
            else
              return skipped("Workflow cannot transition to failed") unless workflow.may_fail?

              cancelled_ids = workflow.steps.cancelled.order(:position).pluck(:id)
              if cancelled_ids.any?
                workflow.failure_reason = "no_runnable_steps_after_cancellation"
                workflow.set_artifact!("failure_reason", "no_runnable_steps_after_cancellation")
                workflow.set_artifact!("no_runnable_steps_after_cancellation", {
                  "cancelled_step_ids" => cancelled_ids
                })
              end
              workflow.fail!
              workflow.save!
            end
          end

          workflow.reload
          return skipped("Workflow completion remains blocked") if workflow.running?

          success("marked #{workflow_label(workflow)} #{workflow.state}")
        end
      end

      class FailWorkflowFromFailedStep < Base
        def perform
          workflow = target_workflow
          return skipped("Workflow no longer exists") unless workflow
          return skipped("Workflow is #{workflow.state}, not queued/running") unless workflow.queued? || workflow.running?
          return skipped("Workflow still has running descendants") if workflow.live_descendants?

          failed_step = workflow.steps.where(state: "failed").reorder(position: :desc, id: :desc).detect { |step| !step.superseded_retry_until_failure? }
          return skipped("Workflow has no failed Step") unless failed_step
          return skipped("Workflow cannot transition to failed") unless workflow.may_fail?

          # Replay the cascade the lost dispatch would have run, so recovery
          # reaches the same outcome: advance, a loop iteration, an
          # infrastructure retry, a try branch, or (only when none applies)
          # a hard fail.
          with_transition_reason do
            StepDispatcher.fail_from(failed_step)
          end
          workflow.reload
          success("replayed the failure cascade of #{step_label(failed_step)} on #{workflow_label(workflow)}: workflow #{workflow.state}")
        end
      end

      class ContinueLoopIterationFromFailedStep < Base
        def perform
          step = target_step
          return skipped("Step no longer exists") unless step

          workflow = step.workflow
          return skipped("Workflow no longer exists") unless workflow
          return skipped("Workflow is #{workflow.state}, not queued/running") unless workflow.queued? || workflow.running?
          return skipped("Workflow still has running descendants") if workflow.live_descendants?
          return skipped("#{step_label(step)} is #{step.state}, not failed") unless step.failed?
          return skipped("#{step_label(step)} no longer has loop budget remaining") unless StepDispatcher.loop_iteration_budget_remaining?(step)

          StepDispatcher.fail_from(step)
          success("continued loop iteration from failed #{step_label(step)} on #{workflow_label(workflow)}")
        end
      end

      class ReconcileStepFromTerminalRun < Base
        def perform
          step = target_step
          return skipped("Step no longer exists") unless step
          return skipped("Step is #{step.state}, not active") unless step.running? || step.queued?
          return skipped("Workflow is not running") unless step.workflow&.running?
          return skipped("Step is waiting for an in-place retry") if AutoRetryAttempt.pending_in_place_step_retry_for?(step)

          step_runs = step.runs.to_a
          return skipped("Step has no Runs") if step_runs.empty?
          # The classifier's own guard, re-checked now: a plan made while the
          # Step was still running with a failed Run, applied after a retry
          # failed and reopened it, failed the reopened Step again and its
          # retry reopened it a second time -- two Runs of one Step executing
          # at once.
          if step.queued? && reopened_after_latest_terminal_run?(step, step_runs)
            return skipped("Step was reopened after its latest terminal Run")
          end

          with_transition_reason do
            @sync_result = Steps::StateSynchronizer.from_latest_terminal_run!(step, runs: step_runs)
          end
          return skipped(@sync_result.reason) unless @sync_result.synchronized?

          if step.workflow.reload.running? && (@sync_result.state == "succeeded" || advance_after_reconciled_failure?(step))
            StepDispatcher.advance_from(step.reload)
          end
          success(@sync_result.reason)
        end

        def reopened_after_latest_terminal_run?(step, step_runs)
          terminal_run = Steps::StateProjection.for(step, runs: step_runs).latest_terminal_run
          StateTransition.step_reopened_since?(step, terminal_run&.finished_at)
        end

        def advance_after_reconciled_failure?(step)
          @sync_result.state == "failed" && Step::Kind.fetch(step.kind).fail_policy == :advance
        rescue ArgumentError
          false
        end
      end

      class CancelWorkflowForClosedJob < Base
        def perform
          workflow = target_workflow
          return skipped("Workflow no longer exists") unless workflow
          return skipped("Workflow is #{workflow.state}, not active") unless workflow.queued? || workflow.running?
          return skipped("Job is not closed") unless workflow.job&.closed?
          return skipped("Workflow cannot transition to cancelled") unless workflow.may_cancel?

          # Ancestry first, top down (NY40): cancelling rolls up to the Job.
          Workflow.transaction do
            Lineage.lock!(workflow)
            workflow.reload(lock: true)
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

            success("cancelled #{workflow_label(workflow)} because #{job_label(workflow.job)} is closed")
          end
        end
      end

      class CancelSupersededCiRepair < Base
        def perform
          workflow = target_workflow
          return skipped("Workflow no longer exists") unless workflow
          return skipped("Workflow is #{workflow.state}, not queued") unless workflow.queued?
          return skipped("Workflow cannot transition to cancelled") unless workflow.may_cancel?
          return skipped("Workflow is #{workflow.trigger_kind}, not ci_failure") unless workflow.trigger_kind == "ci_failure"

          unit = workflow.work_unit
          return skipped("Workflow has no WorkUnit") unless unit
          return skipped("#{work_unit_label(unit)} is #{unit.kind}, not ci_failure") unless unit.kind == "ci_failure"
          return skipped("#{work_unit_label(unit)} is #{unit.state}, not blocked") unless unit.blocked?
          unless unit.blocked_reason == WorkUnits::Gates::CiRepairSafety::REASON
            return skipped("#{work_unit_label(unit)} is blocked on #{unit.blocked_reason}, not ci_repair_safety")
          end

          kind = ci_repair_block_kind(workflow)
          behind_base = WorkUnits::Gates::CiRepairSafety::BEHIND_BASE_BLOCK_KINDS.include?(kind)
          unless behind_base || WorkUnits::Gates::CiRepairSafety::SUPERSEDABLE_BLOCK_KINDS.include?(kind)
            return skipped("CI repair block is #{kind}, not one a superseded base makes moot")
          end

          base_sha = ci_repair_block_base_sha(workflow)
          return skipped("CI repair base SHA is missing") if base_sha.blank? && !behind_base
          return skipped(still_current_message(base_sha, behind_base)) unless moot?(workflow, kind, base_sha)

          current_base_sha = WorkUnits::Gates::CiRepairSafety.current_base_sha_for(workflow.job)
          # Ancestry first, top down (NY40): cancelling rolls up to the Job.
          Workflow.transaction do
            Lineage.lock!(workflow)
            workflow.reload(lock: true)
            return skipped("Workflow is #{workflow.state}, not queued") unless workflow.queued?
            return skipped("Workflow cannot transition to cancelled") unless workflow.may_cancel?
            return skipped(still_current_message(base_sha, behind_base)) unless moot?(workflow, kind, base_sha)

            with_transition_reason do
              WorkUnits::WorkflowCancellation.cancel!(
                workflow,
                reason: WorkUnits::Gates::CiRepairSafety::SUPERSEDED_BASE_REASON,
                artifacts: {
                  "cancelled_reason" => WorkUnits::Gates::CiRepairSafety::SUPERSEDED_BASE_REASON,
                  "cancelled_by_reconciler_at" => Time.current.iso8601,
                  "superseded_ci_repair_block_kind" => kind,
                  "superseded_ci_repair_base_sha" => base_sha,
                  "superseded_ci_repair_current_base_sha" => current_base_sha
                }
              )
            end
            hand_failure_back_to_poller!(workflow) if behind_base
          end

          return success("cancelled #{workflow_label(workflow)} because its branch is behind base and must be rebased before any CI repair") if behind_base

          success("cancelled #{workflow_label(workflow)} because CI repair base #{base_sha} was superseded by #{current_base_sha}")
        end

        private

        def moot?(workflow, kind, base_sha)
          WorkUnits::Gates::CiRepairSafety.moot_block?(workflow.job, kind, base_sha, since: workflow.created_at)
        end

        def still_current_message(base_sha, behind_base)
          behind_base ? "branch is no longer behind base" : "CI repair base #{base_sha} is still current"
        end

        # The poller answers "failing and behind base" by rebasing first, but
        # only for a head it has not handled yet. Un-handle the cancelled
        # repair's head so the next poll applies that rule instead of reading
        # the failure as already answered.
        def hand_failure_back_to_poller!(workflow)
          job = workflow.job
          head_sha = workflow.artifact("head_sha").presence
          return unless job && head_sha && job.last_ci_handled_sha == head_sha

          job.update!(last_ci_handled_sha: nil)
        end

        def ci_repair_block_kind(workflow)
          ci_repair_block_details(workflow)["kind"].presence
        end

        def ci_repair_block_base_sha(workflow)
          ci_repair_block_details(workflow)["base_sha"].presence ||
            workflow.artifact("base_sha").presence ||
            workflow.work_unit&.work_intent&.payload_artifacts.to_h["base_sha"].presence
        end

        def ci_repair_block_details(workflow)
          workflow.work_unit&.blocked_details.to_h.presence ||
            workflow.artifact("start_blocked_details").to_h
        end
      end

      class FinishWorkUnitForClosedJob < Base
        def perform
          unit = target_work_unit
          return skipped("WorkUnit no longer exists") unless unit
          return skipped("WorkUnit is #{unit.state}, not active") unless unit.active?
          return skipped("WorkUnit is not job-scoped") unless unit.scope_type == "job"

          job = Job.find_by(id: unit.scope_id)
          return skipped("job id #{unit.scope_id} no longer exists") unless job
          return skipped("#{job_label(job)} is #{job.state}, not closed") unless job.closed?

          workflow = unit.workflow
          if workflow&.active?
            return skipped("#{workflow_label(workflow)} is still active; closed-job workflow repair owns that cleanup")
          end

          with_transition_reason do
            if workflow&.terminal?
              unit.mark_terminal!(workflow.state)
              @message = "marked #{work_unit_label(unit)} #{workflow.state} because closed #{job_label(job)}'s #{workflow_label(workflow)} is #{workflow.state}"
            else
              unit.preempt!(reason: "job_closed")
              @message = "cancelled #{work_unit_label(unit)} because #{job_label(job)} is closed and no Workflow is attached"
            end
          end

          success(@message)
        end
      end

      class CancelTerminalWorkflowActiveDescendants < Base
        def perform
          workflow = target_workflow
          return skipped("Workflow no longer exists") unless workflow

          # Decide under the Job lock: Retry-from-failed-step reopens the
          # Workflow while holding it, and a reopen between the terminal
          # check and the cancel had the retry's fresh Runs cancelled.
          refusal = nil
          # The Workflow's ancestry, top down (NY40), which includes the Job.
          Workflow.transaction do
            Lineage.lock!(workflow)
            workflow.reload(lock: true)
            refusal = if !workflow.terminal?
              "Workflow is #{workflow.state}, not terminal"
            elsif !workflow.terminal_cleanup_active_descendants?
              "Workflow has no active descendants"
            end
            next if refusal

            with_transition_reason do
              workflow.cancel_stale_terminal_descendants!(reason: plan.action)
            end
          end
          return skipped(refusal) if refusal

          workflow.reload
          remaining_steps = workflow.stale_terminal_steps.pluck(:id)
          remaining_runs = workflow.runs.active.pluck(:id)
          if remaining_steps.any? || remaining_runs.any?
            failure("active descendants remain: steps=#{remaining_steps.inspect} runs=#{remaining_runs.inspect}")
          else
            success("cancelled active descendants for terminal #{workflow_label(workflow)}")
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
            failure("active locks remain for #{work_unit_label(unit)}: #{remaining.inspect}")
          else
            success("released #{active_locks.size} active locks for terminal #{work_unit_label(unit)}")
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
            failure("active child WorkUnits remain for terminal parent #{work_unit_label(parent)}: #{work_unit_id_list_label(remaining_ids)}")
          else
            success("cancelled #{active_children.size} active child WorkUnit(s) for terminal parent #{work_unit_label(parent)}")
          end
        end

        private

        def cancel_child_work_unit!(child)
          workflow = child.workflow
          if workflow&.may_cancel?
            # Ancestry first, top down (NY40): cancelling rolls up to the Job.
            Workflow.transaction do
              Lineage.lock!(workflow)
              workflow.reload(lock: true)
              if workflow.may_cancel?
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
            end
          end

          child.preempt!(reason: "terminal_parent_work_unit")
        end
      end

      class CancelActiveWorkUnitWithoutWorkflow < Base
        def perform
          unit = target_work_unit
          return skipped("WorkUnit no longer exists") unless unit
          return skipped("WorkUnit is #{unit.state}, not active") unless unit.active?
          return skipped("WorkUnit already has #{workflow_id_label(unit.workflow_id)}") if unit.workflow_id.present?

          unit.preempt!(reason: "missing_workflow")
          remaining_lock_ids = unit.work_unit_locks.active.pluck(:id)
          if remaining_lock_ids.any?
            failure("cancelled #{work_unit_label(unit)}, but active locks remain: #{remaining_lock_ids.inspect}")
          else
            success("cancelled active #{work_unit_label(unit)} without a Workflow")
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
            success("rechecked #{work_intent_label(intent)}; wait cleared=#{intent.requested?}")
          else
            skipped("#{work_intent_label(intent)} still waits on #{result.reason}")
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
          return skipped("#{work_intent_label(intent)} no longer has active WorkUnits") if active_unit_ids.empty?
          return skipped("#{work_intent_label(intent)} still waits on a failing gate") unless intent_gates_pass?(intent)

          intent.request!
          success("cleared stale wait on #{work_intent_label(intent)}; active WorkUnits: #{work_unit_id_list_label(active_unit_ids)}")
        end

        private

        def intent_gates_pass?(intent)
          intent.definition.intent_gates.all? { |gate| gate.call(intent).pass? }
        rescue WorkDefinitions::UnknownKind
          false
        end
      end

      class RelaunchStaleProviderBlockedWorkUnit < Base
        def perform
          unit = target_work_unit
          return skipped("WorkUnit no longer exists") unless unit
          return skipped("#{work_unit_label(unit)} is no longer stale-provider-blocked") unless WorkUnits::StaleProviderRelauncher.stale?(unit)

          intent = unit.work_intent
          workflow = unit.workflow
          previous_provider = workflow&.agent_provider
          desired_provider = WorkUnits::StaleProviderRelauncher.new(unit).desired_provider

          WorkUnits::StaleProviderRelauncher.release!(unit)

          if intent.definition.generic_intent_start_allowed?
            result = WorkIntents::Scheduler.start_ready!(intent)
            return success("#{work_intent_label(intent)} was already fulfilled by later Job work") if result.already_satisfied?
            return skipped("#{work_intent_label(intent)} now waits on #{result.reason}") if result.waiting?
            return skipped("#{work_intent_label(intent)} did not start: #{result.reason || "no Run was created"}") if result.not_started?
            return success("relaunched #{work_intent_label(intent)} from #{previous_provider} to #{desired_provider} as #{workflow_label(result.workflow)}") unless result.already_active?

            return skipped("#{work_intent_label(intent)} already has #{result.reason}")
          end

          if intent.definition.landing_lock?
            LandingQueueProcessorJob.perform_later
            return success("cancelled stale #{work_unit_label(unit)} for #{work_intent_label(intent)} and woke the landing queue")
          end

          success("cancelled stale #{work_unit_label(unit)} for #{work_intent_label(intent)}")
        end
      end

      class LaunchRequestedWorkIntent < Base
        def perform
          intent = target_work_intent
          return skipped("WorkIntent no longer exists") unless intent
          return skipped("WorkIntent is #{intent.state}, not requested") unless intent.requested?
          obsolete_job = cancel_obsolete_closed_job_intent!(intent)
          return success("cancelled #{work_intent_label(intent)} because #{job_label(obsolete_job)} is closed") if obsolete_job

          result = WorkIntents::Scheduler.start_ready!(
            intent,
            artifacts: latest_artifacts_for(intent),
            agent_provider: latest_agent_provider_for(intent)
          )

          if result.already_active?
            skipped("#{work_intent_label(intent)} already has #{result.reason}")
          elsif result.already_satisfied?
            success("#{work_intent_label(intent)} was already fulfilled by later Job work")
          elsif result.waiting?
            skipped("#{work_intent_label(intent)} now waits on #{result.reason}")
          elsif result.blocked?
            success("launched #{work_intent_label(intent)} as blocked #{work_unit_label(result.work_unit)}: #{result.reason}")
          elsif result.not_started?
            skipped("#{work_intent_label(intent)} did not start: #{result.reason || "no Run was created"}")
          else
            success("launched #{work_intent_label(intent)} as #{workflow_label(result.workflow)}")
          end
        end

        private

        def cancel_obsolete_closed_job_intent!(intent)
          job = job_for_intent(intent)
          return false unless job&.closed?

          active_unit_ids = intent.work_units
            .where(state: WorkIntents::TerminalUnitSync::ACTIVE_UNIT_STATES)
            .pluck(:id)
          return false if active_unit_ids.any?

          intent.cancel!
          job
        end

        def latest_artifacts_for(intent)
          latest_workflow_for(intent)&.artifacts.presence || intent.payload_artifacts.presence || {}
        end

        def latest_agent_provider_for(intent)
          current_agent_provider_for(intent).presence || latest_workflow_for(intent)&.agent_provider
        end

        def current_agent_provider_for(intent)
          job_for_intent(intent)&.workflow_agent_provider
        end

        def job_for_intent(intent)
          if intent.scope_type == "job" && intent.scope_id.present?
            Job.find_by(id: intent.scope_id)
          else
            latest_workflow_for(intent)&.job
          end
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
          success("woke landing queue for #{work_intent_label(intent)} (#{intent.kind})")
        end
      end

      class SatisfyWorkIntentFromSucceededWorkUnit < Base
        def perform
          intent = target_work_intent
          return skipped("WorkIntent no longer exists") unless intent
          return skipped("WorkIntent is #{intent.state}, not requested/waiting") unless intent.requested? || intent.waiting?

          unit_id = plan.preconditions["work_unit_id"]
          unit = WorkUnit.find_by(id: unit_id)
          return skipped("#{work_unit_id_label(unit_id)} no longer exists") unless unit
          return skipped("#{work_unit_label(unit)} belongs to #{work_intent_id_label(unit.work_intent_id)}, not #{work_intent_label(intent)}") unless unit.work_intent_id == intent.id
          return skipped("#{work_unit_label(unit)} is #{unit.state}, not succeeded") unless unit.succeeded?
          return skipped("#{work_unit_label(unit)} is not the latest finished unit of #{work_intent_label(intent)}") unless intent.settled_by?(unit)

          active_sibling_ids = intent.work_units
            .where(state: WorkIntents::TerminalUnitSync::ACTIVE_UNIT_STATES)
            .where.not(id: unit.id)
            .pluck(:id)
          return skipped("#{work_intent_label(intent)} still has active WorkUnits: #{work_unit_id_list_label(active_sibling_ids)}") if active_sibling_ids.any?

          intent.satisfy!
          success("satisfied #{work_intent_label(intent)} from succeeded #{work_unit_label(unit)}")
        end
      end

      class CancelWorkIntentFromSupersededWorkUnit < Base
        def perform
          intent = target_work_intent
          return skipped("WorkIntent no longer exists") unless intent
          return skipped("WorkIntent is #{intent.state}, not requested/waiting") unless intent.requested? || intent.waiting?

          unit_id = plan.preconditions["work_unit_id"]
          unit = WorkUnit.find_by(id: unit_id)
          return skipped("#{work_unit_id_label(unit_id)} no longer exists") unless unit
          return skipped("#{work_unit_label(unit)} belongs to #{work_intent_id_label(unit.work_intent_id)}, not #{work_intent_label(intent)}") unless unit.work_intent_id == intent.id
          return skipped("#{work_unit_label(unit)} is #{unit.state}, not cancelled") unless unit.cancelled?
          return skipped("#{work_unit_label(unit)} is not the latest finished unit of #{work_intent_label(intent)}") unless intent.settled_by?(unit)

          expected_reason = plan.preconditions["preemption_reason"].to_s
          allowed_reasons = WorkIntents::TerminalUnitSync::SUPERSEDING_CANCEL_REASONS
          return skipped("#{work_unit_label(unit)} preemption reason #{unit.preemption_reason.inspect} is not superseding") unless allowed_reasons.include?(unit.preemption_reason.to_s)
          return skipped("#{work_unit_label(unit)} preemption reason changed from #{expected_reason.inspect} to #{unit.preemption_reason.inspect}") if expected_reason.present? && unit.preemption_reason.to_s != expected_reason

          active_sibling_ids = intent.work_units
            .where(state: WorkIntents::TerminalUnitSync::ACTIVE_UNIT_STATES)
            .where.not(id: unit.id)
            .pluck(:id)
          return skipped("#{work_intent_label(intent)} still has active WorkUnits: #{work_unit_id_list_label(active_sibling_ids)}") if active_sibling_ids.any?

          intent.cancel!
          success("cancelled #{work_intent_label(intent)} from superseded #{work_unit_label(unit)}")
        end
      end

      class FailWorkIntentFromFailedWorkUnit < Base
        def perform
          intent = target_work_intent
          return skipped("WorkIntent no longer exists") unless intent
          return skipped("WorkIntent is #{intent.state}, not requested/waiting") unless intent.requested? || intent.waiting?

          unit_id = plan.preconditions["work_unit_id"]
          unit = WorkUnit.find_by(id: unit_id)
          return skipped("#{work_unit_id_label(unit_id)} no longer exists") unless unit
          return skipped("#{work_unit_label(unit)} belongs to #{work_intent_id_label(unit.work_intent_id)}, not #{work_intent_label(intent)}") unless unit.work_intent_id == intent.id
          return skipped("#{work_unit_label(unit)} is #{unit.state}, not failed") unless unit.failed?
          return skipped("#{work_unit_label(unit)} is not the latest finished unit of #{work_intent_label(intent)}") unless intent.settled_by?(unit)

          active_sibling_ids = intent.work_units
            .where(state: WorkIntents::TerminalUnitSync::ACTIVE_UNIT_STATES)
            .where.not(id: unit.id)
            .pluck(:id)
          return skipped("#{work_intent_label(intent)} still has active WorkUnits: #{work_unit_id_list_label(active_sibling_ids)}") if active_sibling_ids.any?

          intent.fail!
          success("failed #{work_intent_label(intent)} from failed #{work_unit_label(unit)}")
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
          return skipped("Keeper #{workflow_id_label(keeper_id)} is no longer active") unless keeper&.queued? || keeper&.running?
          return skipped("Keeper #{workflow_label(keeper)} belongs to a different Job") unless keeper.job_id == workflow.job_id
          return skipped("#{workflow_label(workflow)} is not older than keeper #{workflow_label(keeper)}") unless workflow.created_at < keeper.created_at || (workflow.created_at == keeper.created_at && workflow.id < keeper.id)

          # Ancestry first, top down (NY40): cancelling rolls up to the Job.
          Workflow.transaction do
            Lineage.lock_all!([ workflow, keeper ])
            workflow.reload(lock: true)
            keeper.reload(lock: true)
            return skipped("Workflow is #{workflow.state}, not active") unless workflow.queued? || workflow.running?
            return skipped("Workflow cannot transition to cancelled") unless workflow.may_cancel?
            return skipped("Keeper #{workflow_id_label(keeper_id)} is no longer active") unless keeper.queued? || keeper.running?
            return skipped("Keeper #{workflow_label(keeper)} belongs to a different Job") unless keeper.job_id == workflow.job_id
            return skipped("#{workflow_label(workflow)} is not older than keeper #{workflow_label(keeper)}") unless workflow.created_at < keeper.created_at || (workflow.created_at == keeper.created_at && workflow.id < keeper.id)

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
          end

          success("cancelled superseded #{workflow_label(workflow)} because newer #{workflow_label(keeper)} is active")
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
          return skipped("Keeper #{workflow_id_label(keeper_id)} is no longer active") unless keeper&.queued? || keeper&.running?

          # Ancestry first, top down (NY40): cancelling rolls up to the Job.
          Workflow.transaction do
            Lineage.lock_all!([ workflow, keeper ])
            workflow.reload(lock: true)
            keeper.reload(lock: true)
            return skipped("Workflow is #{workflow.state}, not active") unless workflow.queued? || workflow.running?
            return skipped("Workflow cannot transition to cancelled") unless workflow.may_cancel?
            return skipped("Keeper #{workflow_id_label(keeper_id)} is no longer active") unless keeper.queued? || keeper.running?
            # The classifier's rule (EpicWorkflowLock::ConflictDetector): a
            # member is only a conflict while both it and the keeper run.
            unless workflow.epic_wide? || (workflow.running? && keeper.running?)
              return skipped("#{workflow_label(workflow)} is waiting on the Epic, not running alongside #{workflow_label(keeper)}")
            end

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
          end

          success("cancelled #{workflow_label(workflow)} because Epic-wide #{workflow_label(keeper)} is active")
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

          LandingQueueProcessorJob.perform_later
          success("deferred orphaned landing #{job_label(job)} back to approved and woke the landing queue")
        end
      end

      class RepairLandingWorkJobState < Base
        def perform
          job = target_job
          return skipped("Job no longer exists") unless job
          return skipped("Job is already landing") if job.landing?
          return skipped("Job is #{job.state}, not repairable to landing") unless job.running? || job.approved?
          return skipped("Job is not owned by active landing work") unless active_landing_work_for_job?(job)

          workflow = target_workflow || job.workflows.where(trigger_kind: WorkDefinitions.landing_workflow_kinds, state: Workflow::TriggerKind::ACTIVE_STATES).reorder(created_at: :desc, id: :desc).first
          with_transition_reason do
            LandingWorkJobState.ensure_landing!(
              job: job,
              workflow: workflow,
              reason: plan.action
            )
          end

          return skipped("Job did not transition to landing") unless job.reload.landing?

          LandingQueueProcessorJob.perform_later
          success("repaired #{job_label(job)} to landing for active landing work")
        end
      end

      class RepairMergeTrainMemberReconciliation < Base
        def perform
          train_id = plan.preconditions["merge_train_id"]
          return skipped("MergeTrain id missing") if train_id.blank?

          train = MergeTrain.find_by(id: train_id)
          return skipped("MergeTrain ##{train_id} no longer exists") unless train
          return skipped("MergeTrain ##{train.id} is #{train.state}, not succeeded") unless train.state == "succeeded"
          return skipped("MergeTrain ##{train.id} has no integration SHA") if train.integration_sha.blank?

          repaired = repair_members!(train)

          return skipped("no merge-train members repaired") if repaired.zero?

          train.epic&.refresh_auto_state!
          LandingQueueProcessorJob.perform_later
          success("repaired #{repaired} failed member(s) for MergeTrain ##{train.id}")
        end

        private

        def repair_members!(train)
          repaired = 0
          train.members.includes(:job).where(state: "failed").find_each do |member|
            job = member.job
            next if job.closed?
            next unless landed_commit_from_this_train?(train, job)

            ActiveRecord::Base.transaction do
              Lineage.lock!(job) # Epic before Job (NY40): closing refreshes the Epic.
              job.update_column(:landed_sha, train.integration_sha)
              job.close_with_reason!("pr_merged") if job.may_close?
              member.update!(state: "merged", reason: nil)
            end
            clean_up_landed_member!(train, job)
            repaired += 1
          end
          repaired
        end

        # The happy path (Steps::MergeTrainLand) comments on and closes a
        # landed member's PR and deletes its branch. A member reconciled here
        # skipped that step, so without the same cleanup its PR stayed open
        # forever -- and an open PR keeps the stale-branch reaper away from the
        # branch too. Best-effort: the landing is already final.
        def clean_up_landed_member!(train, job)
          client = GithubClient.for(repository: train.repository, user: job.user)
          log = ->(message, kind: nil) { Rails.logger.info("[RepairMergeTrainMemberReconciliation] #{message}") }
          MergeTrainMemberLandedCleanup.call(client: client, train: train, job: job, log: log, now: now)
        rescue StandardError => e
          Rails.logger.warn("[RepairMergeTrainMemberReconciliation] cleanup for #{job.slug} failed: #{e.class}: #{e.message}")
        end

        def landed_commit_from_this_train?(train, job)
          window_end = train.finished_at || now
          LandedCommit.where(landable: job, kind: "implementation")
            .where(created_at: train.created_at..window_end)
            .exists?
        end
      end

      class ReleaseExternallyBlockedLandingSlot < Base
        def perform
          unit_id = plan.preconditions["work_unit_id"]
          return skipped("WorkUnit id missing") if unit_id.blank?

          unit = WorkUnit.find_by(id: unit_id)
          return skipped("WorkUnit ##{unit_id} no longer exists") unless unit
          return skipped("WorkUnit ##{unit.id} is #{unit.state}, not blocked") unless unit.blocked?

          unless WorkUnit::EXTERNALLY_CLEARED_BLOCKED_REASONS.include?(unit.blocked_reason.to_s)
            return skipped("WorkUnit ##{unit.id} is blocked on #{unit.blocked_reason}, which can clear on its own")
          end

          released = unit.work_unit_locks.active
                         .where("lock_key LIKE ?", "#{WorkUnit::LANDING_LOCK_KEY_PREFIX}%")
                         .pluck(:lock_key)
          return skipped("WorkUnit ##{unit.id} holds no landing slot") if released.empty?

          unit.release_landing_locks!
          deferred = defer_stranded_member_jobs!(unit)

          LandingQueueProcessorJob.perform_later
          detail = deferred.any? ? ", returned #{deferred.join(', ')} to approved" : ""
          success("released #{released.join(', ')} held by blocked WorkUnit ##{unit.id}#{detail} and woke the landing queue")
        end

        private

        # Releasing the lock is not enough on its own. A Job left in `landing`
        # is itself a landing-in-progress signal -- JobBundleDispatcher falls
        # back to `Job.landing` when no unit holds the slot -- so a Job
        # stranded there by this unit would re-block the bundler the moment the
        # next real landing finished. `defer_landing` is the "put it back in
        # the queue" transition, as opposed to `fail_landing`, which would
        # demand operator re-approval for work that never actually failed.
        def defer_stranded_member_jobs!(unit)
          unit.member_jobs.select(&:landing?).filter_map do |job|
            next unless stranded?(job, unit)
            next unless job.may_defer_landing?

            job.defer_landing!
            job.slug
          end
        end

        # Only when this unit is the whole story: another landing unit that is
        # genuinely running still owns the Job.
        #
        # A merge train owns its members through `merge_train_members`, not
        # through WorkUnitMembers: both dispatchers instantiate the train's
        # single WorkUnit with `job: members.last`, so only the tip member is
        # a work_unit_member. Asking the WorkUnit question alone therefore
        # reports every non-tip member of a live train as stranded and defers
        # it out of `landing` while the train is still grading -- which the
        # land step then rejects as "members not in :landing", losing the
        # whole assembly. Ask about train membership first.
        def stranded?(job, unit)
          return false if active_merge_train_member?(job)

          WorkUnit
            .joins(:work_unit_members)
            .where(work_unit_members: { job_id: job.id }, state: WorkUnits::Ownership::ACTIVE_STATES)
            .where(kind: WorkDefinitions.landing_work_unit_kinds)
            .where.not(id: unit.id)
            .none?
        end

        def active_merge_train_member?(job)
          MergeTrainMember
            .joins(:merge_train)
            .where(job_id: job.id)
            .merge(MergeTrain.active)
            .exists?
        end
      end

      class ReleaseUrgentBlockedLandingSlot < Base
        def perform
          unit = target_work_unit
          return skipped("WorkUnit no longer exists") unless unit

          released = nil
          blockers = nil
          unit.with_lock do
            unit.reload(lock: true)
            workflow = unit.workflow&.reload(lock: true)
            return skipped("WorkUnit ##{unit.id} is not blocked by urgent_job_active") unless unit.blocked? && unit.blocked_reason == "urgent_job_active"
            return skipped("Blocked Workflow is no longer queued landing work before its first Run") unless workflow&.queued_landing_before_first_run?

            released = unit.work_unit_locks.active
                           .where("lock_key LIKE ?", "#{WorkUnit::LANDING_LOCK_KEY_PREFIX}%")
                           .pluck(:lock_key)
            return skipped("WorkUnit ##{unit.id} holds no repository landing slot") if released.empty?

            blockers = LandingQueueProcessor.unrelated_urgent_jobs_for(workflow.job.reload)
            return skipped("No unrelated urgent blocker remains active") if blockers.empty?

            unit.release_landing_locks!
          end

          LandingQueueProcessorJob.perform_later
          success("released #{released.join(', ')} held by #{unit.slug} for blocked #{unit.workflow.slug}; " \
                  "urgent blocker(s) #{blockers.map(&:slug).join(', ')} remain active, preserved job/Epic locks, and woke the landing queue")
        end
      end

      class DeferStrandedLandingJob < Base
        def perform
          job = target_job
          return skipped("Job missing") unless job
          return skipped("#{job.slug} is #{job.state}, not landing") unless job.landing?

          units = WorkUnit
            .joins(:work_unit_members)
            .where(work_unit_members: { job_id: job.id }, state: WorkUnits::Ownership::ACTIVE_STATES)
            .where(kind: WorkDefinitions.landing_work_unit_kinds)
            .distinct
          return skipped("#{job.slug} has no active landing work") if units.empty?

          unless units.all? { |unit| WorkUnit::EXTERNALLY_CLEARED_BLOCKED_REASONS.include?(unit.blocked_reason.to_s) }
            return skipped("#{job.slug} still has landing work that can make progress")
          end

          return skipped("#{job.slug} cannot defer landing") unless job.may_defer_landing?

          job.defer_landing!
          LandingQueueProcessorJob.perform_later
          success("returned #{job.slug} to approved and woke the landing queue")
        end
      end

      class FailStaleActiveMergeTrain < Base
        def perform
          train_id = plan.preconditions["merge_train_id"]
          return skipped("MergeTrain id missing") if train_id.blank?

          train = MergeTrain.includes(members: :job).find_by(id: train_id)
          return skipped("MergeTrain ##{train_id} no longer exists") unless train
          return skipped("MergeTrain ##{train.id} is #{train.state}, not active") if train.terminal?
          return skipped("MergeTrain ##{train.id} still has an owner") if active_runtime?(train)

          reason = MergeTrain::STALE_RUNTIME_FAILURE_REASON
          ActiveRecord::Base.transaction do
            train.update!(
              state: "failed",
              failure_reason: reason,
              failure_code: LandingFailureCode::MERGE_TRAIN_REBUILD_REQUIRED,
              finished_at: now
            )
            train.members.each do |member|
              next if member.state == "merged"

              LandingFailureHandler.call(job: member.job, reason: reason) if member.job&.landing?
              member.update!(state: "failed", reason: reason)
            end
          end

          LandingQueueProcessorJob.perform_later
          success("failed stale MergeTrain ##{train.id} and woke the landing queue")
        end

        private

        def active_runtime?(train)
          WorkEngine::MergeTrainOwnership.new(train).owned?
        end
      end

      class ClearLandingStartBlockerAndWakeQueue < Base
        def perform
          job = target_job
          return skipped("Job no longer exists") unless job
          return skipped("Job is #{job.state}, not approved") unless job.approved?
          return skipped("Job no longer has a landing-start blocker") unless job.landing_failure_kind&.landing_start_blocker?

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
          return skipped("worker_died failure already created active replacement work") if active_runtime_work_for_job?(target_job)

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

      class RefreshBaseFromBlockedCheckpoint < Base
        def perform
          workflow = target_workflow
          return skipped("Workflow no longer exists") unless workflow

          result = BaseRefreshRetryEnqueuer.call(
            job: workflow.job,
            source_workflow: workflow,
            reason: "Automatic recovery of a verified checkpoint-backed blocked Workflow"
          )
          result.success? ? success("started checkpoint-backed base refresh for #{workflow_label(workflow)}") : skipped(result.error)
        end
      end

      class DiscardSupersededBranchOutput < Base
        def perform
          workflow = target_workflow
          return skipped("Workflow no longer exists") unless workflow

          result = BranchDivergenceRecovery.discard_superseded!(workflow: workflow)
          result.success? ? success("discarded superseded branch output for #{workflow_label(workflow)}") : skipped(result.error)
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

          result = RetryFailedStepEnqueuer.call(workflow: workflow, restart_grade_loop: false)
          result.success? ? success("started merge-train rebuild with #{run_label(result.run)}") : skipped(result.error)
        end
      end

      class CancelWorkIntentForClosedJob < Base
        def perform
          intent = target_work_intent
          return skipped("WorkIntent no longer exists") unless intent
          return skipped("WorkIntent is #{intent.state}, not requested/waiting") unless intent.requested? || intent.waiting?

          job = closed_job_for_intent(intent)
          return skipped("Closed Job for #{work_intent_label(intent)} no longer exists") unless job
          return skipped("#{job_label(job)} is #{job.state}, not closed") unless job.closed?

          active_unit_ids = intent.work_units
            .where(state: WorkIntents::TerminalUnitSync::ACTIVE_UNIT_STATES)
            .pluck(:id)
          return skipped("#{work_intent_label(intent)} still has active WorkUnits: #{work_unit_id_list_label(active_unit_ids)}") if active_unit_ids.any?

          member_ids = member_job_ids_for_intent(intent)
          if intent.scope_type != "job"
            return skipped("#{work_intent_label(intent)} is not attached to #{job_label(job)}") unless member_ids.include?(job.id)

            open_member_ids = Job.where(id: member_ids).where.not(state: "closed").pluck(:id)
            return skipped("#{work_intent_label(intent)} still has open member Jobs: #{open_member_ids.inspect}") if open_member_ids.any?
          end

          intent.cancel!
          if intent.scope_type == "job"
            success("cancelled #{work_intent_label(intent)} because #{job_label(job)} is closed")
          else
            success("cancelled #{work_intent_label(intent)} because member Jobs #{member_ids.inspect} are closed")
          end
        end

        private

        def closed_job_for_intent(intent)
          if intent.scope_type == "job"
            Job.find_by(id: intent.scope_id)
          else
            first_job
          end
        end

        def member_job_ids_for_intent(intent)
          WorkUnitMember
            .joins(:work_unit)
            .where(work_units: { work_intent_id: intent.id })
            .distinct
            .pluck(:job_id)
        end
      end

      class ReleaseEpicBlockedJob < Base
        def perform
          job = target_job
          return skipped("Job no longer exists") unless job
          return skipped("#{job_label(job)} is #{job.state}, not blocked_by_epic") unless job.blocked_by_epic?
          return skipped("#{job_label(job)} has no Epic") unless job.epic
          return skipped("#{job.epic.slug} is not releasing child Jobs") unless job.epic.releases_jobs_for_execution?
          return skipped("#{job_label(job)} dependencies are still blocked") unless job.dependencies_satisfied_for_execution?
          return skipped("#{job_label(job)} cannot release its Epic block") unless job.may_release_epic_block?
          return skipped("#{job_label(job)} already has active runtime work") if active_runtime_work_for_job?(job)

          with_transition_reason do
            WorkIntents::JobWakeup.call(job)
          end

          job.reload
          if job.blocked_by_epic?
            skipped("#{job_label(job)} remained blocked_by_epic after wakeup")
          else
            success("released stale Epic block for #{job_label(job)}")
          end
        end
      end

      class ReconcileJobState < Base
        def perform
          job = target_job
          return skipped("Job no longer exists") unless job

          state_plan = ReconcileJobStatesJob::Plan.for(job)
          return skipped("Job state drift is no longer present") unless state_plan

          state_plan.apply!
          success("reconciled #{job_label(job)} from #{state_plan.from_state} to #{state_plan.target_state}")
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
          return skipped("Latest Workflow is not terminal") unless latest_workflow && %w[succeeded failed cancelled blocked].include?(latest_workflow.state)
          review_publication_step_kinds = review_publication_step_kinds_for(latest_workflow)
          return skipped("Latest Workflow has no review publication policy") if review_publication_step_kinds.empty?
          return skipped("Latest Workflow did not include a review publication Step") unless latest_workflow.steps.where(kind: review_publication_step_kinds).exists?
          return skipped("Latest Workflow has a succeeded review publication Step") if latest_workflow.steps.where(kind: review_publication_step_kinds, state: "succeeded").exists?
          return skipped("Job cannot transition to failed") unless job.may_force_fail?

          with_transition_reason do
            job.force_fail!
            job.save!
          end
          success("marked #{job_label(job)} failed because it was implemented without a tracked PR")
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
          success("marked #{job_label(job)} failed because it was approved without a tracked PR")
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
          return skipped("Latest Workflow was not cancelled by an Epic-wide workflow lock") unless cancelled_workflow_reason(latest) == EpicWorkflowLock::BLOCK_REASON
          return skipped("Epic-wide workflow is still active") if active_epic_wide_workflow_for_job?(job)
          return skipped("Dependencies are still not ready for execution") unless job.dependencies_satisfied_for_execution?

          result = retry_cancelled_workflow(job, latest, retry_reason: "epic_workflow_conflict_recovered")
          return skipped(result.error) unless result.success?

          success("started #{result.workflow.trigger_kind} #{workflow_label(result.workflow)} for #{job_label(job)} after Epic-wide workflow conflict cleared")
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

          success("started #{result.workflow.trigger_kind} #{workflow_label(result.workflow)} for #{job_label(job)} after cancelled #{workflow_label(latest)}")
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
          success("closed completed #{job.kind} #{job_label(job)}")
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
