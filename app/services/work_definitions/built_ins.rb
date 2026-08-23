module WorkDefinitions
  BuiltIns = Module.new

  module BlocksCiFailure
    def blocks_ci_failure? = true
  end

  module OpensReviewPullRequest
    def self.included(base)
      base.review_publication_step_kinds = %w[pr_open]
    end
  end

  class Initial < Base
    include OpensReviewPullRequest

    self.kind = "initial"
    self.workflow_trigger_kind = "initial"
    self.runtime_role = "first_class"
    self.scope = "job"
  end

  class PrComment < Base
    self.kind = "pr_comment"
    self.workflow_trigger_kind = "pr_comment"
    self.runtime_role = "first_class"
    self.scope = "job"
  end

  class ChatFeedback < Base
    self.kind = "chat_feedback"
    self.workflow_trigger_kind = "chat_feedback"
    self.runtime_role = "first_class"
    self.scope = "job"
  end

  class CiFailure < Base
    self.kind = "ci_failure"
    self.workflow_trigger_kind = "ci_failure"
    self.runtime_role = "first_class"
    self.scope = "job"
  end

  class Rebase < Base
    include BlocksCiFailure

    self.kind = "rebase"
    self.workflow_trigger_kind = "rebase"
    self.runtime_role = "first_class"
    self.scope = "job"
  end

  class StackRebase < Base
    include BlocksCiFailure

    self.kind = "stack_rebase"
    self.workflow_trigger_kind = "stack_rebase"
    self.runtime_role = "first_class"
    self.scope = "epic"
  end

  class AutoMerge < Base
    include BlocksCiFailure

    self.kind = "auto_merge"
    self.workflow_trigger_kind = "auto_merge"
    self.runtime_role = "first_class"
    self.scope = "job"
  end

  class LandingValidation < Base
    include BlocksCiFailure

    self.kind = "landing_validation"
    self.workflow_trigger_kind = "landing_validation"
    self.runtime_role = "child"
    self.scope = "job"
    self.parent_kind = "auto_merge"
  end

  class ExternalPrMerge < Base
    include BlocksCiFailure

    self.kind = "external_pr_merge"
    self.workflow_trigger_kind = "external_pr_merge"
    self.runtime_role = "first_class"
    self.scope = "job"
  end

  class MergeTrain < Base
    include BlocksCiFailure

    self.kind = "merge_train"
    self.workflow_trigger_kind = "merge_train"
    self.runtime_role = "first_class"
    self.scope = "epic"

    def members_for(job:, artifacts: {}, **)
      train_id = artifacts.to_h["merge_train_id"]
      return super if train_id.blank?

      train = ::MergeTrain.includes(:members).find_by(id: train_id)
      return super unless train

      train.members.includes(:job).order(:position).map(&:job)
    end
  end

  class MergeTrainValidation < Base
    include BlocksCiFailure

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

  class Retry < Base
    include OpensReviewPullRequest

    self.kind = "retry"
    self.workflow_trigger_kind = "retry"
    self.runtime_role = "first_class"
    self.scope = "job"
  end

  class CheckpointResume < Base
    include OpensReviewPullRequest

    self.kind = "checkpoint_resume"
    self.workflow_trigger_kind = "retry"
    self.runtime_role = "first_class"
    self.scope = "job"

    def workflow_template = Workflows::CheckpointResume
  end

  class ManualVisualReview < Base
    self.kind = "manual_visual_review"
    self.workflow_trigger_kind = "manual_visual_review"
    self.runtime_role = "first_class"
    self.scope = "job"
  end

  class Replay < Base
    self.kind = "replay"
    self.workflow_trigger_kind = "replay"
    self.runtime_role = "legacy"
    self.scope = "job"
  end

  class Manual < Base
    self.kind = "manual"
    self.workflow_trigger_kind = "manual"
    self.runtime_role = "first_class"
    self.scope = "job"
  end

  class Resume < Base
    self.kind = "resume"
    self.workflow_trigger_kind = "resume"
    self.runtime_role = "first_class"
    self.scope = "job"
  end

  class CodingHandoff < Base
    include OpensReviewPullRequest

    self.kind = "coding_handoff"
    self.workflow_trigger_kind = "coding_handoff"
    self.runtime_role = "first_class"
    self.scope = "job"
  end

  class LocalModeHandoff < Base
    include OpensReviewPullRequest

    self.kind = "local_mode_handoff"
    self.workflow_trigger_kind = "local_mode_handoff"
    self.runtime_role = "first_class"
    self.scope = "job"
  end

  class MainGrader < Base
    self.kind = "main_grader"
    self.workflow_trigger_kind = "main_grader"
    self.runtime_role = "infrastructure"
    self.scope = "repository"
  end

  class MainBranchRepair < Base
    include OpensReviewPullRequest

    self.kind = "main_branch_repair"
    self.workflow_trigger_kind = "main_branch_repair"
    self.runtime_role = "first_class"
    self.scope = "repository"
  end

  class ManualAgenticRun < Base
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
    self.kind = "external_pr_ingest"
    self.workflow_trigger_kind = "external_pr_ingest"
    self.runtime_role = "first_class"
    self.scope = "job"
  end

  class ExternalPrFeedback < Base
    self.kind = "external_pr_feedback"
    self.workflow_trigger_kind = "external_pr_feedback"
    self.runtime_role = "first_class"
    self.scope = "job"
  end

  class Skill < Base
    include OpensReviewPullRequest

    self.kind = "skill"
    self.workflow_trigger_kind = "skill"
    self.runtime_role = "first_class"
    self.scope = "job"
  end
end
