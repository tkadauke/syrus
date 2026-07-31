module WorkEngine
  class RepairPlanner
    DEFAULT_RETRY_BACKOFF = AutoRetryScheduler::BACKOFFS.first

    Plan = Data.define(
      :issue_kind,
      :action,
      :auto_executable,
      :target_type,
      :target_id,
      :affected_ids,
      :execution_steps,
      :preconditions,
      :retry_after,
      :check_after,
      :reason
    ) do
      def initialize(issue_kind:, action:, auto_executable:, target_type:, target_id:,
                     affected_ids:, execution_steps:, preconditions:, reason:,
                     retry_after: nil, check_after: nil)
        super(
          issue_kind: issue_kind.to_s,
          action: action.to_s,
          auto_executable: !!auto_executable,
          target_type: target_type.to_s,
          target_id: target_id,
          affected_ids: affected_ids.deep_stringify_keys,
          execution_steps: Array(execution_steps).map(&:to_s),
          preconditions: JSON.parse(JSON.generate(preconditions.deep_stringify_keys)),
          retry_after: retry_after,
          check_after: check_after,
          reason: reason.to_s
        )
      end

      def as_json(*)
        {
          issue_kind: issue_kind,
          action: action,
          auto_executable: auto_executable,
          target_type: target_type,
          target_id: target_id,
          affected_ids: affected_ids,
          execution_steps: execution_steps,
          preconditions: preconditions,
          retry_after: retry_after&.iso8601,
          check_after: check_after&.iso8601,
          reason: reason
        }
      end
    end

    def self.call(...) = new(...).call

    def initialize(result:, now: Time.current)
      @result = result
      @now = now
    end

    def call
      result.issues.map { |issue| policy_for(issue).plan }
    end

    private

    attr_reader :result, :now

    def policy_for(issue)
      Policies::Base.for(issue.kind).new(issue: issue, result: result, now: now)
    end

    module Policies
      class Base
        def self.for(kind)
          registry.fetch(kind.to_s, Default)
        end

        def self.registry
          @registry ||= descendants.index_by(&:issue_kind)
        end

        def self.issue_kind
          name.demodulize.underscore
        end

        def initialize(issue:, result:, now:)
          @issue = issue
          @result = result
          @now = now
        end

        def plan
          operator_plan("operator_review_recovery", "No automatic repair policy exists for #{issue.kind}.")
        end

        private

        attr_reader :issue, :result, :now

        def automatic_plan(action, target, reason, execution_steps:, preconditions: {},
                           retry_after: issue.retry_after, check_after: issue.check_after)
          build_plan(
            action,
            target,
            reason,
            auto_executable: true,
            execution_steps: execution_steps,
            preconditions: preconditions,
            retry_after: retry_after,
            check_after: check_after
          )
        end

        def waiting_plan(action, reason, target: primary_record, preconditions: {},
                         retry_after: issue.retry_after, check_after: issue.check_after)
          build_plan(
            action,
            target,
            reason,
            auto_executable: false,
            execution_steps: [],
            preconditions: preconditions,
            retry_after: retry_after,
            check_after: check_after
          )
        end

        def operator_plan(action, reason, target: primary_record, preconditions: {},
                          retry_after: issue.retry_after, check_after: issue.check_after)
          build_plan(
            action,
            target,
            reason,
            auto_executable: false,
            execution_steps: [],
            preconditions: preconditions,
            retry_after: retry_after,
            check_after: check_after
          )
        end

        def build_plan(action, target, reason, auto_executable:, execution_steps:, preconditions:, retry_after:, check_after:)
          Plan.new(
            issue_kind: issue.kind,
            action: action,
            auto_executable: auto_executable,
            target_type: target&.class&.name || "none",
            target_id: target&.id,
            affected_ids: issue.affected_ids,
            execution_steps: execution_steps,
            preconditions: preconditions,
            retry_after: retry_after,
            check_after: check_after,
            reason: reason
          )
        end

        def primary_record
          primary_run || primary_workflow || primary_step || primary_job
        end

        def primary_run
          @primary_run ||= Run.includes(:step, :job, :claude_session, :run_failure_classification).find_by(id: first_id(:run_ids))
        end

        def primary_step
          @primary_step ||= Step.find_by(id: first_id(:step_ids)) || primary_run&.step
        end

        def primary_workflow
          @primary_workflow ||=
            Workflow.includes(:job, :steps).find_by(id: first_id(:workflow_ids)) ||
            primary_run&.workflow ||
            primary_step&.workflow
        end

        def primary_job
          @primary_job ||= Job.find_by(id: first_id(:job_ids)) || primary_workflow&.job || primary_run&.job
        end

        def first_id(key)
          issue.affected_ids.fetch(key, []).first
        end

        def classification
          primary_run&.run_failure_classification
        end

        def step_kind
          return nil unless primary_step

          Step::Kind.fetch(primary_step.kind)
        rescue ArgumentError
          nil
        end

        def workspace_available?
          workflow = primary_workflow
          return false unless workflow

          evidence = result.snapshot.workspaces[workflow.id] || result.snapshot.workspaces[workflow.id.to_s]
          return evidence[:exists] if evidence&.key?(:exists)
          return evidence["exists"] if evidence&.key?("exists")

          File.directory?(WorkflowWorkspace.path_for(workflow))
        end

        def retry_budget_available?
          run = primary_run
          return false unless run

          retry_classification = classification&.classification || run.agent_outcome.to_s.presence || "unknown"
          agent_provider = run.agent_provider.presence || run.workflow&.agent_provider
          return false if agent_provider.blank?

          attempt_number = AutoRetryAttempt.budget_scope_for(
            job: run.job,
            agent_provider: agent_provider,
            failure_classification: retry_classification
          ).count + 1
          attempt_number <= retry_budget_limit(retry_classification)
        end

        def retry_budget_exhausted_plan
          operator_plan(
            "operator_review_retry_budget_exhausted",
            "The retry classification has exhausted its automatic retry budget.",
            preconditions: { retry_budget_available: false, classification: classification&.classification || primary_run&.agent_outcome }
          )
        end

        def retry_budget_limit(retry_classification)
          if retry_classification == AutoRetryScheduler::WORKER_DIED_CLASSIFICATION
            AutoRetryScheduler::MAX_WORKER_DIED_ATTEMPTS
          else
            AutoRetryScheduler::MAX_ATTEMPTS
          end
        end

        def retry_whole_workflow_safe?
          workflow = primary_workflow
          job = primary_job
          return false unless workflow && job

          workflow.retry_as_new_workflow_available? &&
            job.open? &&
            !job.any_active_run? &&
            !workflow.landing_workflow?
        end

        def retry_after_for_retryable_failure
          return issue.retry_after if issue.retry_after

          run = primary_run
          reset_at = run&.user&.gh_rate_limit_reset_at
          if classification&.classification == "rate_limited" && reset_at&.future?
            reset_at
          else
            now + DEFAULT_RETRY_BACKOFF
          end
        end
      end

      class Default < Base; end

      class QueuedRunWithoutQueueClaim < Base
        def plan
          automatic_plan(
            "reenqueue_run",
            primary_run,
            "The Run is queued without a SolidQueue job, so the narrowest repair is to enqueue the same Run again.",
            execution_steps: [ "Run#reenqueue!" ],
            preconditions: { run_state: "queued", workflow_state: %w[queued running], no_active_queue_claim: true }
          )
        end
      end

      class QueuedRunStaleQueueClaim < Base
        def plan
          waiting_plan(
            "diagnose_queue_starvation",
            "The Run still has a queue claim, so duplicating it could execute the same work twice.",
            preconditions: { queue_claim_present: true, worker_heartbeat_stale: true }
          )
        end
      end

      class RunningRunWithoutLiveWorkerEvidence < Base
        def plan
          unless issue.safe_to_auto_repair
            return operator_plan(
              "capture_run_diagnostics",
              "The Run has not crossed the stale-heartbeat threshold yet."
            )
          end

          return resume_worker_died if primary_step&.agentic? && primary_run&.claude_session.present?
          return retry_step_after_worker_died if workspace_available?
          return retry_workflow_after_worker_died if retry_whole_workflow_safe?

          operator_plan(
            "operator_review_worker_died",
            "The worker appears dead, but no resumable session, same-workspace retry, or safe workflow retry is available."
          )
        end

        private

        def resume_worker_died
          return retry_budget_exhausted_plan unless retry_budget_available?

          automatic_plan(
            "mark_worker_died_and_resume_failed_step",
            primary_run,
            "The worker is stale and the agent session was captured, so resuming the same failed step is the narrowest repair.",
            execution_steps: [ "Run#fail!(agent_outcome: worker_died)", "ResumeWorkflowEnqueuer.call" ],
            preconditions: { run_state: "running", step_agentic: true, session_available: true, retry_budget_available: true }
          )
        end

        def retry_step_after_worker_died
          return retry_budget_exhausted_plan unless retry_budget_available?

          automatic_plan(
            "mark_worker_died_and_retry_failed_step",
            primary_run,
            "The worker is stale and the workflow workspace is still available, " \
              "so retrying the failed step is narrower than starting over.",
            execution_steps: [ "Run#fail!(agent_outcome: worker_died)", "RetryFailedStepEnqueuer.call" ],
            preconditions: { run_state: "running", workspace_available: true, retry_budget_available: true }
          )
        end

        def retry_workflow_after_worker_died
          return retry_budget_exhausted_plan unless retry_budget_available?

          automatic_plan(
            "mark_worker_died_and_retry_workflow",
            primary_run,
            "The worker is stale and the workflow can safely be recreated because the same-workspace retry path is unavailable.",
            execution_steps: [ "Run#fail!(agent_outcome: worker_died)", "RetryWorkflowEnqueuer.call" ],
            preconditions: { run_state: "running", retry_workflow_safe: true, retry_budget_available: true }
          )
        end
      end

      class RetryableRunFailure < Base
        def plan
          if classification&.classification == "rate_limited"
            return waiting_plan(
              "schedule_retry_after_rate_limit",
              "The failed Run is rate-limited, so retry must wait for the reset/backoff window.",
              target: primary_run,
              retry_after: retry_after_for_retryable_failure
            )
          end

          return resume_failed_step if primary_step&.agentic? && primary_run&.claude_session.present?
          return retry_failed_step if workspace_available? && safe_step_retry?
          return retry_workflow if retry_whole_workflow_safe?

          operator_plan(
            "operator_review_retryable_failure",
            "The failure is retryable, but the available step/workflow context is not safe for automatic repair."
          )
        end

        private

        def resume_failed_step
          return retry_budget_exhausted_plan unless retry_budget_available?

          automatic_plan(
            "resume_failed_step",
            primary_run,
            "The failed agentic Run has a captured session, so resuming preserves the most context.",
            execution_steps: [ "ResumeWorkflowEnqueuer.call" ],
            preconditions: { run_state: "failed", session_available: true, retry_budget_available: true }
          )
        end

        def retry_failed_step
          return retry_budget_exhausted_plan unless retry_budget_available?

          automatic_plan(
            "retry_failed_step",
            primary_workflow,
            "The failed step is deterministic and idempotent with the workspace still present.",
            execution_steps: [ "RetryFailedStepEnqueuer.call" ],
            preconditions: {
              workflow_retry_available: primary_workflow&.retry_available?,
              workspace_available: true,
              step_repair_semantics: step_kind&.repair_semantics,
              retry_budget_available: true
            }
          )
        end

        def retry_workflow
          return retry_budget_exhausted_plan unless retry_budget_available?

          automatic_plan(
            "retry_workflow",
            primary_workflow,
            "The failed workflow can be retried as a new workflow and has no active Runs.",
            execution_steps: [ "RetryWorkflowEnqueuer.call" ],
            preconditions: { retry_workflow_safe: true, retry_budget_available: true }
          )
        end

        def safe_step_retry?
          return false unless primary_workflow&.retry_available?
          return true if classification&.classification == AutoRetryScheduler::WORKER_DIED_CLASSIFICATION

          step_kind&.deterministic_idempotent_repair?
        end
      end

      class NonretryableSemanticGitFailure < Base
        def plan
          return merge_train_rebuild if primary_workflow&.trigger_kind == "merge_train" && step_kind&.rebuild_repair?

          operator_plan(
            "operator_review_nonretryable_failure",
            "The failure is semantic, git-related, or otherwise nonretryable; automatic retry risks repeating or duplicating unsafe work.",
            preconditions: { classification: classification&.classification, step_repair_semantics: step_kind&.repair_semantics }
          )
        end

        private

        def merge_train_rebuild
          automatic_plan(
            "rebuild_merge_train",
            primary_workflow,
            "Merge-train retries use the existing rebuild path rather than replaying non-idempotent landing work.",
            execution_steps: [ "RetryFailedStepEnqueuer.call" ],
            preconditions: { trigger_kind: "merge_train", rebuild_path_available: true }
          )
        end
      end

      class QueuedWorkflowWithoutFirstRun < Base
        def plan
          unless issue.safe_to_auto_repair
            return waiting_plan(
              "wait_for_start_block_to_clear",
              "The workflow is intentionally blocked before start."
            )
          end

          automatic_plan(
            "start_workflow",
            primary_workflow,
            "The workflow never created its first Run, so dispatching the first step is the narrowest repair.",
            execution_steps: [ "StepDispatcher.start_workflow" ],
            preconditions: { workflow_state: "queued", first_step_has_no_runs: true }
          )
        end
      end

      class RunningWorkflowWithoutActiveDescendants < Base
        def plan
          automatic_plan(
            "finish_workflow_from_terminal_descendants",
            primary_workflow,
            "The workflow is running with no active descendants, so its terminal state can be reconciled from completed Steps and Runs.",
            execution_steps: [ "RunCompletionReconciler.call" ],
            preconditions: { workflow_state: "running", active_descendants: false }
          )
        end
      end

      class JobWorkflowStateDrift < Base
        def plan
          operator_plan(
            "operator_review_state_transition",
            "The Job and Workflow disagree about active work; an operator should choose the state transition."
          )
        end
      end

      class UnambiguousJobStateDrift < Base
        def plan
          automatic_plan(
            "reconcile_job_state",
            primary_job,
            "The latest Workflow makes the correct Job state unambiguous, so the reconciler can apply the same transition plan as the legacy Job-state reconciler.",
            execution_steps: [ "ReconcileJobStatesJob::Plan.apply!" ],
            preconditions: {
              job_state: issue.evidence["job_state"],
              target_state: issue.evidence["target_state"],
              latest_workflow_state: issue.evidence["latest_workflow_state"]
            }
          )
        end
      end

      class CompletedMainGraderJob < Base
        def plan
          automatic_plan(
            "close_completed_main_grader_job",
            primary_job,
            "Completed main-grader Jobs are operational health checks and can be closed once their latest Workflow is terminal or the Job is implemented.",
            execution_steps: [ "Job#close_with_reason!" ],
            preconditions: {
              job_kind: "main_grader",
              closure_reason: issue.evidence["closure_reason"],
              latest_workflow_state: issue.evidence["latest_workflow_state"]
            }
          )
        end
      end

      class DependencyStackStartBlock < Base
        def plan
          waiting_plan(
            "wait_for_dependency_or_stack_readiness",
            "Dependencies or stack parents are not ready, so retrying would bypass the execution gate."
          )
        end
      end

      class MainHealthStartBlock < Base
        def plan
          waiting_plan(
            "wait_for_main_health",
            "Main branch health is blocking start, so this should wait for the health signal to recover."
          )
        end
      end

      class ResourceCongestion < Base
        def plan
          waiting_plan("wait_for_capacity", "The issue is capacity or disk pressure, not failed work; automatic retries would add load.")
        end
      end

      class RateLimit < Base
        def plan
          waiting_plan(
            "schedule_retry_after_rate_limit",
            "External health says a provider is rate-limited; retry must wait for the circuit reset."
          )
        end
      end

      class WorkspaceMissing < Base
        def plan
          operator_plan(
            "operator_review_missing_workspace",
            "The workspace needed for an in-place repair is missing; starting over must be chosen deliberately."
          )
        end
      end

      class ResumableAgentSessionPresent < Base
        def plan
          return retry_budget_exhausted_plan unless retry_budget_available?

          automatic_plan(
            "resume_failed_step",
            primary_run,
            "A failed agentic Run has a captured session, so resuming is narrower than retrying from scratch.",
            execution_steps: [ "ResumeWorkflowEnqueuer.call" ],
            preconditions: { run_state: "failed", session_available: true, retry_budget_available: true }
          )
        end
      end

      class ResumableAgentSessionMissing < Base
        def plan
          return retry_failed_step_without_session if workspace_available? && primary_workflow&.retry_available?
          return retry_workflow_without_session if retry_whole_workflow_safe?

          operator_plan("operator_review_missing_session", "The agent session is missing and no narrower retry path is currently safe.")
        end

        private

        def retry_failed_step_without_session
          return retry_budget_exhausted_plan unless retry_budget_available?

          automatic_plan(
            "retry_failed_step",
            primary_workflow,
            "The session is missing, but the failed workflow workspace is still available.",
            execution_steps: [ "RetryFailedStepEnqueuer.call" ],
            preconditions: { workflow_retry_available: true, workspace_available: true, retry_budget_available: true }
          )
        end

        def retry_workflow_without_session
          return retry_budget_exhausted_plan unless retry_budget_available?

          automatic_plan(
            "retry_workflow",
            primary_workflow,
            "The session and workspace retry path are unavailable, but a fresh workflow retry is safe.",
            execution_steps: [ "RetryWorkflowEnqueuer.call" ],
            preconditions: { retry_workflow_safe: true, retry_budget_available: true }
          )
        end
      end
    end
  end
end
