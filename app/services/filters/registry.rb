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
  # owner_user_id                 job
  # pinned_by_me                  job
  # has_unread_feedback           job
  # has_landing_failure           job
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
      "state"                         => "Filters::Chips::Jobs::State",
      "kind"                          => "Filters::Chips::Jobs::Kind",
      "priority"                      => "Filters::Chips::Jobs::Priority",
      "agent_provider"                => "Filters::Chips::Jobs::AgentProvider",
      "closure_reason"                => "Filters::Chips::Jobs::ClosureReason",
      "triaging_reason"               => "Filters::Chips::Jobs::TriagingReason",
      "validity"                      => "Filters::Chips::Jobs::Validity",

      # Latest-X derivations
      "latest_workflow_state"         => "Filters::Chips::Jobs::LatestWorkflowState",
      "latest_workflow_trigger_kind"  => "Filters::Chips::Jobs::LatestWorkflowTriggerKind",
      "latest_run_state"              => "Filters::Chips::Jobs::LatestRunState",

      # PR-related
      "pr_present"                    => "Filters::Chips::Jobs::PrPresent",
      "pr_mergeable"                  => "Filters::Chips::Jobs::PrMergeable",

      # FKs
      "repository_id"                 => "Filters::Chips::RepositoryId",
      "epic_id"                       => "Filters::Chips::Jobs::EpicId",
      "parent_job_id"                 => "Filters::Chips::Jobs::ParentJobId",

      # Strings (free-text)
      "title"                         => "Filters::Chips::Jobs::Title",
      "description"                   => "Filters::Chips::Jobs::Description",
      "branch_name"                   => "Filters::Chips::Jobs::BranchName",
      "pr_title"                      => "Filters::Chips::Jobs::PrTitle",

      # Numbers
      "issue_number"                  => "Filters::Chips::Jobs::IssueNumber",
      "pr_number"                     => "Filters::Chips::Jobs::PrNumber",

      # Dates
      "age"                           => "Filters::Chips::Jobs::Age",
      "created_at"                    => "Filters::Chips::CreatedAt",
      "updated_at"                    => "Filters::Chips::UpdatedAt",
      "finished_at"                   => "Filters::Chips::Jobs::FinishedAt",
      "last_seen_comment_at"          => "Filters::Chips::Jobs::LastSeenCommentAt",

      # Owner
      "owner_user_id"                 => "Filters::Chips::Jobs::OwnerUserId",

      # Booleans (predicates)
      "pinned_by_me"                  => "Filters::Chips::Jobs::PinnedByMe",
      "has_unread_feedback"           => "Filters::Chips::Jobs::HasUnreadFeedback",
      "has_landing_failure"           => "Filters::Chips::Jobs::HasLandingFailure",
      "has_active_run"                => "Filters::Chips::Jobs::HasActiveRun",
      "has_blocked_deps"              => "Filters::Chips::Jobs::HasBlockedDeps",
      "has_parent_job"                => "Filters::Chips::Jobs::HasParentJob",
      "has_child_jobs"                => "Filters::Chips::Jobs::HasChildJobs",

      # Collection
      "tags"                          => "Filters::Chips::Jobs::Tags",

      # Preset macro (composite)
      "attention"                     => "Filters::Chips::Jobs::Attention"
    }.freeze

    def self.for(subject = :job)
      Filters.subject(subject).chips
    end

    def self.find(field, subject: :job)
      find_for(subject, field)
    end

    def self.find_for(subject, field)
      Filters.subject(subject).chip_class(field)
    end

    def self.fields(subject: :job)
      Filters.subject(subject).fields
    end

    def self.fields_for(subject)
      fields(subject: subject)
    end

    def self.exists?(field, subject: :job)
      Filters.subject(subject).exists?(field)
    end

    def self.exists_for?(field, subject: :job)
      exists?(field, subject: subject)
    end
  end

  SUBJECTS = {
    job: Subject.new(
      name: :job,
      model: Job,
      chips: Registry::CHIPS
    ),
    epic: Subject.new(
      name: :epic,
      model: Epic,
      chips: {
        "repository_id"           => "Filters::Chips::RepositoryId",
        "created_at"              => "Filters::Chips::CreatedAt",
        "updated_at"              => "Filters::Chips::UpdatedAt",
        "state"                   => "Filters::Chips::Epics::State",
        "title"                   => "Filters::Chips::Epics::Title",
        "description"             => "Filters::Chips::Epics::Description",
        "done_at"                 => "Filters::Chips::Epics::DoneAt",
        "number"                  => "Filters::Chips::Epics::Number",
        "auto_approve_mode"       => "Filters::Chips::Epics::AutoApproveMode",
        "has_child_jobs"          => "Filters::Chips::Epics::HasChildJobs",
        "has_open_children"       => "Filters::Chips::Epics::HasOpenChildren",
        "has_blocked_children"    => "Filters::Chips::Epics::HasBlockedChildren",
        "child_job_count"         => "Filters::Chips::Epics::ChildJobCount",
        "child_progress_percent"  => "Filters::Chips::Epics::ChildProgressPercent",
        "has_epic_dependency"     => "Filters::Chips::Epics::HasEpicDependency",
        "owner_user_id"           => "Filters::Chips::Epics::OwnerUserId",
        "attention"               => "Filters::Chips::Epics::Attention"
      }
    ),
    workflow: Subject.new(
      name: :workflow,
      model: Workflow,
      chips: {
        "state"            => "Filters::Chips::Workflows::State",
        "trigger_kind"     => "Filters::Chips::Workflows::TriggerKind",
        "job_id"           => "Filters::Chips::Workflows::JobId",
        "agent_provider"   => "Filters::Chips::Workflows::AgentProvider",
        "started_at"       => "Filters::Chips::Workflows::StartedAt",
        "finished_at"      => "Filters::Chips::Workflows::FinishedAt",
        "created_at"       => "Filters::Chips::CreatedAt",
        "updated_at"       => "Filters::Chips::UpdatedAt",
        "failure_reason"   => "Filters::Chips::Workflows::FailureReason",
        "has_failed_steps" => "Filters::Chips::Workflows::HasFailedSteps",
        "is_stuck"         => "Filters::Chips::Workflows::IsStuck",
        "run_count"        => "Filters::Chips::Workflows::RunCount",
        "attention"        => "Filters::Chips::Workflows::Attention"
      }
    ),
    admin_user: Subject.new(
      name: :admin_user,
      model: User,
      chips: {
        "email"            => "Filters::Chips::AdminUsers::Email",
        "admin"            => "Filters::Chips::AdminUsers::Admin",
        "has_github_token" => "Filters::Chips::AdminUsers::HasGithubToken",
        "has_claude_token" => "Filters::Chips::AdminUsers::HasClaudeToken",
        "has_codex_token"  => "Filters::Chips::AdminUsers::HasCodexToken",
        "gh_rate"          => "Filters::Chips::AdminUsers::GhRate"
      }
    ),
    admin_queue: Subject.new(
      name: :admin_queue,
      model: SolidQueue::Job,
      chips: {
        "queue_name"   => "Filters::Chips::AdminQueue::QueueName",
        "job_class"    => "Filters::Chips::AdminQueue::JobClass",
        "failed_since" => "Filters::Chips::AdminQueue::FailedSince"
      }
    ),
    spawned_process: Subject.new(
      name: :spawned_process,
      model: SpawnedProcess,
      chips: {
        "state"       => "Filters::Chips::SpawnedProcesses::State",
        "kind"        => "Filters::Chips::SpawnedProcesses::Kind",
        "hostname"    => "Filters::Chips::SpawnedProcesses::Hostname",
        "run_id"      => "Filters::Chips::SpawnedProcesses::RunId",
        "workflow_id" => "Filters::Chips::SpawnedProcesses::WorkflowId",
        "stale"       => "Filters::Chips::SpawnedProcesses::Stale",
        "started_at"  => "Filters::Chips::SpawnedProcesses::StartedAt"
      }
    ),
    memory: Subject.new(
      name: :memory,
      model: ChatMemory,
      chips: {
        "content"       => "Filters::Chips::Memories::Content",
        "scope"         => "Filters::Chips::Memories::Scope",
        "kind"          => "Filters::Chips::Memories::Kind",
        "repository_id" => "Filters::Chips::Memories::RepositoryId",
        "published"     => "Filters::Chips::Memories::Published",
        "created_at"    => "Filters::Chips::CreatedAt",
        "updated_at"    => "Filters::Chips::UpdatedAt"
      }
    )
  }.freeze

  def self.subject(name)
    SUBJECTS.fetch(name.to_sym) { raise ArgumentError, "unknown subject: #{name}" }
  end

  def self.subject_for(name)
    subject(name)
  end
end
