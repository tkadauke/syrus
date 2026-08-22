module WorkDefinitions
  BuiltIns = Module.new

  class Initial < Base
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
    self.kind = "rebase"
    self.workflow_trigger_kind = "rebase"
    self.runtime_role = "first_class"
    self.scope = "job"
  end

  class StackRebase < Base
    self.kind = "stack_rebase"
    self.workflow_trigger_kind = "stack_rebase"
    self.runtime_role = "first_class"
    self.scope = "epic"
  end

  class AutoMerge < Base
    self.kind = "auto_merge"
    self.workflow_trigger_kind = "auto_merge"
    self.runtime_role = "first_class"
    self.scope = "job"
  end

  class LandingValidation < Base
    self.kind = "landing_validation"
    self.workflow_trigger_kind = "landing_validation"
    self.runtime_role = "child"
    self.scope = "job"
    self.parent_kind = "auto_merge"
  end

  class ExternalPrMerge < Base
    self.kind = "external_pr_merge"
    self.workflow_trigger_kind = "external_pr_merge"
    self.runtime_role = "first_class"
    self.scope = "job"
  end

  class MergeTrain < Base
    self.kind = "merge_train"
    self.workflow_trigger_kind = "merge_train"
    self.runtime_role = "first_class"
    self.scope = "epic"
  end

  class MergeTrainValidation < Base
    self.kind = "merge_train_validation"
    self.workflow_trigger_kind = "merge_train_validation"
    self.runtime_role = "child"
    self.scope = "epic"
    self.parent_kind = "merge_train"
  end

  class Retry < Base
    self.kind = "retry"
    self.workflow_trigger_kind = "retry"
    self.runtime_role = "first_class"
    self.scope = "job"
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
    self.kind = "coding_handoff"
    self.workflow_trigger_kind = "coding_handoff"
    self.runtime_role = "first_class"
    self.scope = "job"
  end

  class LocalModeHandoff < Base
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
    self.kind = "skill"
    self.workflow_trigger_kind = "skill"
    self.runtime_role = "first_class"
    self.scope = "job"
  end
end
