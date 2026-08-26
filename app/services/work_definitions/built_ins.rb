module WorkDefinitions
  BuiltIns = Module.new

  module BlocksCiFailure
    def blocks_ci_failure? = true
  end

  module PreemptsCiFailure
    def preempts_ci_failure? = true
  end

  module ActiveRepairWork
    def active_repair_work? = true
  end

  module RetryWorkflowAttempt
    def retry_workflow_attempt? = true
  end

  module RecoverableCancelledWorkflow
    def recoverable_cancelled_workflow? = true
  end

  module SuppressesLayeredAutoRepair
    def suppresses_layered_auto_repair? = true
  end

  module LandingValidationPrefetchSource
    def landing_validation_prefetch_source? = true
  end

  module LandingValidationChild
    def landing_validation_child? = true
  end

  module AgentConcurrencyExempt
    def agent_concurrency_exempt? = true
  end

  module OpensReviewPullRequest
    def self.included(base)
      base.review_publication_step_kinds = %w[pr_open]
    end
  end

  module ManagesOwnJobLifecycle
    def manages_own_job_lifecycle? = true
  end

  module ResumesFailedSteps
    def retry_policy = WorkUnits::RetryPolicies::ResumeStepOrNewWorkflow.new
  end

  module CheckpointPreemptable
    def preemption_policy = WorkUnits::PreemptionPolicies::Checkpoint.new
  end

  module CancelPreemptable
    def preemption_policy = WorkUnits::PreemptionPolicies::Cancel.new
  end

  module RebuildOnPreempt
    def preemption_policy = WorkUnits::PreemptionPolicies::Rebuild.new
  end

  module RequiresApproval
    def intent_gates = super + [ WorkIntents::Gates::Approval ]
    def requires_approval? = true
  end

  module RequiresEpicReadiness
    def intent_gates = super + [ WorkIntents::Gates::EpicReadiness ]
    def requires_epic_readiness? = true
  end

  class Initial < Base
    include OpensReviewPullRequest
    include ResumesFailedSteps
    include CheckpointPreemptable
    include RecoverableCancelledWorkflow

    self.kind = "initial"
    self.workflow_trigger_kind = "initial"
    self.runtime_role = "first_class"
    self.scope = "job"
  end

  class PrComment < Base
    include ActiveRepairWork
    include ResumesFailedSteps
    include CheckpointPreemptable
    include RecoverableCancelledWorkflow

    self.kind = "pr_comment"
    self.workflow_trigger_kind = "pr_comment"
    self.runtime_role = "first_class"
    self.scope = "job"
  end

  class ChatFeedback < Base
    include ActiveRepairWork
    include ResumesFailedSteps
    include CheckpointPreemptable
    include RecoverableCancelledWorkflow

    self.kind = "chat_feedback"
    self.workflow_trigger_kind = "chat_feedback"
    self.runtime_role = "first_class"
    self.scope = "job"
  end

  class CiFailure < Base
    include ActiveRepairWork
    include ResumesFailedSteps
    include CheckpointPreemptable
    include RecoverableCancelledWorkflow

    self.kind = "ci_failure"
    self.workflow_trigger_kind = "ci_failure"
    self.runtime_role = "first_class"
    self.scope = "job"

    def unit_gates = [ WorkUnits::Gates::CiRepairSafety ] + super
  end

  class Rebase < Base
    include BlocksCiFailure
    include PreemptsCiFailure
    include ResumesFailedSteps
    include RebuildOnPreempt

    self.kind = "rebase"
    self.workflow_trigger_kind = "rebase"
    self.runtime_role = "first_class"
    self.scope = "job"

    def lock_keys_for(job:, member_jobs:, artifacts: {}, **)
      [ "maintenance:rebase:job:#{job.id}" ]
    end
  end

  class StackRebase < Base
    include BlocksCiFailure
    include PreemptsCiFailure
    include ResumesFailedSteps
    include RebuildOnPreempt

    self.kind = "stack_rebase"
    self.workflow_trigger_kind = "stack_rebase"
    self.runtime_role = "first_class"
    self.scope = "epic"

    def lock_keys_for(job:, member_jobs:, artifacts: {}, **)
      keys = member_jobs.map { |member_job| "maintenance:rebase:job:#{member_job.id}" }
      keys << "maintenance:stack_rebase:epic:#{job.epic_id}" if job.epic_id.present?
      keys.uniq
    end
  end

  class Promotion < Base
    include ManagesOwnJobLifecycle
    include ResumesFailedSteps
    include CheckpointPreemptable

    self.kind = "promotion"
    self.workflow_trigger_kind = "promotion"
    self.runtime_role = "first_class"
    self.scope = "repository"
  end

  class HotfixSync < Base
    include ManagesOwnJobLifecycle
    include ResumesFailedSteps
    include CheckpointPreemptable

    self.kind = "hotfix_sync"
    self.workflow_trigger_kind = "hotfix_sync"
    self.runtime_role = "first_class"
    self.scope = "repository"
  end

  class AutoMerge < Base
    include BlocksCiFailure
    include LandingValidationPrefetchSource
    include RequiresApproval
    include ResumesFailedSteps
    include RebuildOnPreempt

    self.kind = "auto_merge"
    self.workflow_trigger_kind = "auto_merge"
    self.runtime_role = "first_class"
    self.scope = "job"
  end

  class LandingValidation < Base
    include BlocksCiFailure
    include LandingValidationChild
    include RequiresApproval
    include ManagesOwnJobLifecycle
    include CancelPreemptable

    self.kind = "landing_validation"
    self.workflow_trigger_kind = "landing_validation"
    self.runtime_role = "child"
    self.scope = "job"
    self.parent_kind = "auto_merge"
  end

  class ExternalPrMerge < Base
    include BlocksCiFailure
    include RequiresApproval
    include ResumesFailedSteps
    include RebuildOnPreempt

    self.kind = "external_pr_merge"
    self.workflow_trigger_kind = "external_pr_merge"
    self.runtime_role = "first_class"
    self.scope = "job"
  end

  class MergeTrain < Base
    include BlocksCiFailure
    include LandingValidationPrefetchSource
    include RequiresApproval
    include RequiresEpicReadiness
    include RebuildOnPreempt

    self.kind = "merge_train"
    self.workflow_trigger_kind = "merge_train"
    self.runtime_role = "first_class"
    self.scope = "epic"

    def retry_policy = WorkUnits::RetryPolicies::MergeTrain.new

    def members_for(job:, artifacts: {}, **)
      train_id = artifacts.to_h["merge_train_id"]
      return super if train_id.blank?

      train = ::MergeTrain.includes(:members).find_by(id: train_id)
      return super unless train

      train.members.includes(:job).order(:position).map(&:job)
    end
  end

  class JobBundle < Base
    include BlocksCiFailure
    include LandingValidationPrefetchSource
    include RequiresApproval
    include RebuildOnPreempt

    self.kind = "job_bundle"
    self.workflow_trigger_kind = "merge_train"
    self.runtime_role = "first_class"
    self.scope = "repository"
    self.display_label = "Job bundle"

    def retry_policy = WorkUnits::RetryPolicies::MergeTrain.new

    def members_for(job:, artifacts: {}, **)
      train_id = artifacts.to_h["merge_train_id"]
      return super if train_id.blank?

      train = ::MergeTrain.includes(:members).find_by(id: train_id)
      return super unless train&.epic_id.nil?

      train.members.includes(:job).order(:position).map(&:job)
    end
  end

  class MergeTrainValidation < Base
    include BlocksCiFailure
    include LandingValidationChild
    include RequiresApproval
    include RequiresEpicReadiness
    include ManagesOwnJobLifecycle
    include CancelPreemptable

    self.kind = "merge_train_validation"
    self.workflow_trigger_kind = "merge_train_validation"
    self.runtime_role = "child"
    self.scope = "epic"
    self.parent_kind = "merge_train"

    def members_for(job:, artifacts: {}, **)
      ids = Array(artifacts.to_h["prefetch_merge_train_member_job_ids"]).map(&:to_i).select(&:positive?)
      return super if ids.blank?

      jobs_by_id = Job.where(id: ids).index_by(&:id)
      ids.filter_map { |id| jobs_by_id[id] }
    end
  end

  class JobBundleValidation < Base
    include BlocksCiFailure
    include LandingValidationChild
    include RequiresApproval
    include ManagesOwnJobLifecycle
    include CancelPreemptable

    self.kind = "job_bundle_validation"
    self.workflow_trigger_kind = "merge_train_validation"
    self.runtime_role = "child"
    self.scope = "repository"
    self.parent_kind = "job_bundle"
    self.display_label = "Job bundle validation"

    def members_for(job:, artifacts: {}, **)
      ids = Array(artifacts.to_h["prefetch_merge_train_member_job_ids"]).map(&:to_i).select(&:positive?)
      return super if ids.blank?

      jobs_by_id = Job.where(id: ids).index_by(&:id)
      ids.filter_map { |id| jobs_by_id[id] }
    end
  end

  class Retry < Base
    include ActiveRepairWork
    include RetryWorkflowAttempt
    include OpensReviewPullRequest
    include ResumesFailedSteps
    include CheckpointPreemptable
    include RecoverableCancelledWorkflow

    self.kind = "retry"
    self.workflow_trigger_kind = "retry"
    self.runtime_role = "first_class"
    self.scope = "job"
  end

  class CheckpointResume < Base
    include ActiveRepairWork
    include RetryWorkflowAttempt
    include OpensReviewPullRequest
    include ResumesFailedSteps
    include CheckpointPreemptable
    include RecoverableCancelledWorkflow

    self.kind = "checkpoint_resume"
    self.workflow_trigger_kind = "retry"
    self.runtime_role = "first_class"
    self.scope = "job"

    def workflow_template = Workflows::CheckpointResume
  end

  class ManualVisualReview < Base
    include ResumesFailedSteps
    include CancelPreemptable

    self.kind = "manual_visual_review"
    self.workflow_trigger_kind = "manual_visual_review"
    self.runtime_role = "first_class"
    self.scope = "job"
  end

  class Replay < Base
    include RecoverableCancelledWorkflow

    self.kind = "replay"
    self.workflow_trigger_kind = "replay"
    self.runtime_role = "legacy"
    self.scope = "job"
  end

  class Manual < Base
    include ActiveRepairWork
    include ResumesFailedSteps
    include CheckpointPreemptable
    include RecoverableCancelledWorkflow

    self.kind = "manual"
    self.workflow_trigger_kind = "manual"
    self.runtime_role = "first_class"
    self.scope = "job"
  end

  class Resume < Base
    include ResumesFailedSteps
    include CheckpointPreemptable
    include RecoverableCancelledWorkflow

    self.kind = "resume"
    self.workflow_trigger_kind = "resume"
    self.runtime_role = "first_class"
    self.scope = "job"
  end

  class CodingHandoff < Base
    include OpensReviewPullRequest
    include ResumesFailedSteps
    include CheckpointPreemptable
    include RecoverableCancelledWorkflow

    self.kind = "coding_handoff"
    self.workflow_trigger_kind = "coding_handoff"
    self.runtime_role = "first_class"
    self.scope = "job"
  end

  class LocalModeHandoff < Base
    include OpensReviewPullRequest
    include ResumesFailedSteps
    include CheckpointPreemptable
    include RecoverableCancelledWorkflow

    self.kind = "local_mode_handoff"
    self.workflow_trigger_kind = "local_mode_handoff"
    self.runtime_role = "first_class"
    self.scope = "job"
  end

  class MainGrader < Base
    include AgentConcurrencyExempt

    self.kind = "main_grader"
    self.workflow_trigger_kind = "main_grader"
    self.runtime_role = "infrastructure"
    self.scope = "repository"
  end

  class MainBranchRepair < Base
    include AgentConcurrencyExempt
    include OpensReviewPullRequest
    include ManagesOwnJobLifecycle
    include ResumesFailedSteps
    include CheckpointPreemptable

    self.kind = "main_branch_repair"
    self.workflow_trigger_kind = "main_branch_repair"
    self.runtime_role = "first_class"
    self.scope = "repository"
  end

  class ManualAgenticRun < Base
    include ActiveRepairWork
    include ResumesFailedSteps
    include CheckpointPreemptable

    self.kind = "manual_agentic_run"
    self.workflow_trigger_kind = "manual_agentic_run"
    self.runtime_role = "first_class"
    self.scope = "job"
  end

  class AgentInsight < Base
    self.kind = "agent_insight"
    self.workflow_trigger_kind = "agent_insight"
    self.runtime_role = "infrastructure"
    self.scope = "repository"
  end

  class ExternalPrIngest < Base
    include ResumesFailedSteps
    include CheckpointPreemptable
    include SuppressesLayeredAutoRepair

    self.kind = "external_pr_ingest"
    self.workflow_trigger_kind = "external_pr_ingest"
    self.runtime_role = "first_class"
    self.scope = "job"
  end

  class ExternalPrFeedback < Base
    include ResumesFailedSteps
    include CheckpointPreemptable
    include RecoverableCancelledWorkflow

    self.kind = "external_pr_feedback"
    self.workflow_trigger_kind = "external_pr_feedback"
    self.runtime_role = "first_class"
    self.scope = "job"
  end

  class Skill < Base
    include OpensReviewPullRequest
    include ResumesFailedSteps
    include CheckpointPreemptable

    self.kind = "skill"
    self.workflow_trigger_kind = "skill"
    self.runtime_role = "first_class"
    self.scope = "job"
  end

  class Deploy < Base
    include ResumesFailedSteps
    include CheckpointPreemptable
    include RecoverableCancelledWorkflow

    self.kind = "deploy"
    self.workflow_trigger_kind = "deploy"
    self.runtime_role = "first_class"
    self.scope = "job"
  end
end
