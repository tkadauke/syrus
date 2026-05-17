module Filters
  class UnknownFilterField < ArgumentError
    def initialize(field)
      super("unknown filter field: #{field.inspect}")
    end
  end

  # Chip genericity inventory for the Phase 3 namespace move:
  #
  # state                         job
  # kind                          job
  # priority                      job
  # agent_provider                job
  # closure_reason                job
  # triaging_reason               job
  # validity                      job
  # latest_workflow_state         job
  # latest_workflow_trigger_kind  job
  # latest_run_state              job
  # pr_present                    job
  # pr_mergeable                  job
  # repository_id                 generic
  # epic_id                       column-named-after-job
  # parent_job_id                 column-named-after-job
  # title                         column-named-after-job
  # description                   column-named-after-job
  # branch_name                   column-named-after-job
  # pr_title                      column-named-after-job
  # issue_number                  column-named-after-job
  # pr_number                     column-named-after-job
  # age                           job
  # created_at                    generic
  # updated_at                    generic
  # finished_at                   column-named-after-job
  # last_seen_comment_at          column-named-after-job
  # pinned_by_me                  job
  # has_unread_feedback           job
  # has_active_run                job
  # has_blocked_deps              job
  # has_parent_job                job
  # has_child_jobs                job
  # tags                          job
  # attention                     job
  #
  # Central index of every chip type the system knows about. Adding a
  # new filter is a one-line entry here plus a class under
  # Filters::Chips. Bucket / operator vocabulary lives on the chip
  # class itself (`bucket`, `operators` DSL).
  class Registry
    CHIPS = {
      # Thread / metadata
      "state"                         => "Filters::Chips::State",
      "kind"                          => "Filters::Chips::Kind",
      "priority"                      => "Filters::Chips::Priority",
      "agent_provider"                => "Filters::Chips::AgentProvider",
      "closure_reason"                => "Filters::Chips::ClosureReason",
      "triaging_reason"               => "Filters::Chips::TriagingReason",
      "validity"                      => "Filters::Chips::Validity",

      # Latest-X derivations
      "latest_workflow_state"         => "Filters::Chips::LatestWorkflowState",
      "latest_workflow_trigger_kind"  => "Filters::Chips::LatestWorkflowTriggerKind",
      "latest_run_state"              => "Filters::Chips::LatestRunState",

      # PR-related
      "pr_present"                    => "Filters::Chips::PrPresent",
      "pr_mergeable"                  => "Filters::Chips::PrMergeable",

      # FKs
      "repository_id"                 => "Filters::Chips::RepositoryId",
      "epic_id"                       => "Filters::Chips::EpicId",
      "parent_job_id"                 => "Filters::Chips::ParentJobId",

      # Strings (free-text)
      "title"                         => "Filters::Chips::Title",
      "description"                   => "Filters::Chips::Description",
      "branch_name"                   => "Filters::Chips::BranchName",
      "pr_title"                      => "Filters::Chips::PrTitle",

      # Numbers
      "issue_number"                  => "Filters::Chips::IssueNumber",
      "pr_number"                     => "Filters::Chips::PrNumber",

      # Dates
      "age"                           => "Filters::Chips::Age",
      "created_at"                    => "Filters::Chips::CreatedAt",
      "updated_at"                    => "Filters::Chips::UpdatedAt",
      "finished_at"                   => "Filters::Chips::FinishedAt",
      "last_seen_comment_at"          => "Filters::Chips::LastSeenCommentAt",

      # Booleans (predicates)
      "pinned_by_me"                  => "Filters::Chips::PinnedByMe",
      "has_unread_feedback"           => "Filters::Chips::HasUnreadFeedback",
      "has_active_run"                => "Filters::Chips::HasActiveRun",
      "has_blocked_deps"              => "Filters::Chips::HasBlockedDeps",
      "has_parent_job"                => "Filters::Chips::HasParentJob",
      "has_child_jobs"                => "Filters::Chips::HasChildJobs",

      # Collection
      "tags"                          => "Filters::Chips::Tags",

      # Preset macro (composite)
      "attention"                     => "Filters::Chips::Attention"
    }.freeze

    def self.find(field)
      class_name = CHIPS[field.to_s] or raise UnknownFilterField.new(field)
      class_name.constantize
    end

    def self.fields
      CHIPS.keys
    end

    def self.exists?(field)
      CHIPS.key?(field.to_s)
    end
  end
end
