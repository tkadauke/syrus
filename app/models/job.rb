class Job < ApplicationRecord
  include AASM
  include RecordsStateTransitions
  include JobCodingMode
  include JobNeedsAttention
  include JobWorkflowAccessors
  include JobCost
  include JobStackBase
  include JobDependencies
  include JobExecutionAccessors
  include JobLifecycle
  include EnqueuesSearchIndex

  KINDS = %w[ issue cron direct main_grader agent_insight external_pr ].freeze
  MAIN_GRADER_CLOSURE_REASON = "main_grader".freeze
  SCHEDULED_TASK_OUTCOMES = {
    "too_many_failures"          => :record_failure!,
    "too_many_failed_workflows"  => :record_failure!,
    "too_many_workflows"         => :record_failure!,
    "replaced_by_scheduled_task" => nil              # bookkeeping only; no counter update
  }.freeze
  SYSTEM_KIND_MAIN_BRANCH_REPAIR = "main_branch_repair".freeze
  SYSTEM_KINDS = [ SYSTEM_KIND_MAIN_BRANCH_REPAIR ].freeze
  MAIN_BRANCH_REPAIR_TITLE = "Fix broken main branch".freeze
  MAX_CONSECUTIVE_FAILED_WORKFLOWS = 10
  MAX_TOTAL_WORKFLOWS = 50
  CREDENTIAL_MODES = %w[ app pat ].freeze
  PREPARE_SKIP_LABEL = "syrus-skip-prepare".freeze
  TERMINAL_STATES = %w[ closed no_change_needed ].freeze

  PRIORITIES = %w[ urgent high medium low ].freeze
  PROVIDER_SETTINGS = Job::ProviderSetting::Base.values.freeze
  STACK_BASES = %w[ auto main ].freeze
  VALIDITIES = %w[ valid duplicate already_implemented ].freeze
  TRIAGING_REASONS = %w[ classifier_pending pending_epic_ref classifier_uncertain ].freeze
  APPROVAL_VIAS = %w[ operator bulk github_review auto_rule ].freeze
  # Maps priority label → SolidQueue priority integer. SolidQueue dispatches
  # lower numbers first, so urgent (-10) runs before high (0), medium (10),
  # and low (20). The gap of 10 between levels leaves room for future additions
  # without renumbering existing entries.
  PRIORITY_TO_SQ = { "urgent" => -10, "high" => 0, "medium" => 10, "low" => 20 }.freeze
  attr_accessor :prepare_skip_reason_override, :pending_dependency_warnings, :notify_job_implemented_on_transition

  belongs_to :user
  belongs_to :owner_user, class_name: "User", optional: true
  belongs_to :repository
  belongs_to :input_source, optional: true
  belongs_to :scheduled_task, optional: true
  belongs_to :epic, optional: true
  belongs_to :parent_job, class_name: "Job", optional: true
  belongs_to :dependencies_overridden_by_user, class_name: "User", optional: true
  belongs_to :approved_by_user, class_name: "User", optional: true
  belongs_to :claimed_by_user, class_name: "User", optional: true
  belongs_to :manual_paused_by_user, class_name: "User", optional: true
  belongs_to :target_repository, class_name: "Repository", optional: true
  belongs_to :pr_repository, class_name: "Repository", optional: true
  belongs_to :linked_chat, class_name: "ChatSession", optional: true
  has_many :job_approvals, dependent: :destroy
  has_many :pr_review_comments, dependent: :destroy
  has_many :approving_users, through: :job_approvals, source: :user
  has_many :chat_proposals, dependent: :nullify
  has_many :workflows, -> { order(:created_at) }, dependent: :destroy
  # Runs hang off Steps now (Job → Workflow → Step → Run) — Job's
  # direct has_many :runs is a convenience accessor, NOT a cascade
  # parent. Cascade flows through workflows. Runs all carry job_id
  # for the existing Run.belongs_to :job association used widely
  # in views and queries.
  has_many :runs, -> { order(:created_at) }
  has_many :run_resource_summaries, dependent: :destroy
  has_many :auto_retry_attempts, dependent: :destroy
  has_many :job_logs, through: :runs
  has_many :mcp_tool_usages, dependent: :nullify
  has_many :job_pins, dependent: :destroy
  has_many :pinning_users, through: :job_pins, source: :user
  has_many :notifications, dependent: :nullify
  has_many :documents, -> { order(:created_at, :id) }, as: :attachable, dependent: :destroy
  has_many :job_attachments, -> { order(:created_at, :id) }, as: :attachable, class_name: "Document", dependent: :destroy
  has_many :job_tags, dependent: :destroy
  has_many :tags, -> { order(Arel.sql("LOWER(tags.name) ASC")) }, through: :job_tags
  has_many :deployment_stage_statuses,
           class_name: "JobDeploymentStageStatus",
           dependent: :destroy,
           inverse_of: :job
  has_many :dependencies,
           class_name: "JobDependency",
           dependent: :destroy,
           inverse_of: :job
  has_many :depends_on_jobs, through: :dependencies, source: :depends_on_job
  has_many :dependent_links,
           class_name: "JobDependency",
           foreign_key: :depends_on_job_id,
           dependent: :destroy,
           inverse_of: :depends_on_job
  has_many :dependents, through: :dependent_links, source: :job
  has_many :stack_children, class_name: "Job", foreign_key: :parent_job_id, dependent: :nullify, inverse_of: :parent_job
  has_many :preview_environments, dependent: :destroy

  validates :kind, presence: true, inclusion: { in: KINDS }
  validates :credential_mode, presence: true, inclusion: { in: CREDENTIAL_MODES }
  validates :priority, presence: true, inclusion: { in: PRIORITIES }
  validates :job_provider_setting, presence: true, inclusion: { in: PROVIDER_SETTINGS }
  validates :stack_base, presence: true, inclusion: { in: STACK_BASES }
  validates :agent_provider, presence: true, inclusion: { in: -> { User.agent_providers } }
  validates :validity, presence: true, inclusion: { in: VALIDITIES }
  validates :triaging_reason, presence: true, inclusion: { in: TRIAGING_REASONS }
  validates :approved_via, inclusion: { in: APPROVAL_VIAS }, allow_nil: true
  validates :system_kind, inclusion: { in: SYSTEM_KINDS }, allow_nil: true
  validates :issue_number,
            presence: true,
            numericality: { only_integer: true, greater_than: 0 },
            if: -> { issue? && (input_source.nil? || input_source.is_a?(InputSources::Github)) }
  validates :scheduled_task_id, presence: true, if: :cron?
  validate  :issue_number_blank_for_cron, if: :cron?
  validate  :issue_number_blank_for_direct, if: :direct?
  validate  :issue_number_blank_for_main_grader, if: :main_grader?
  validate  :issue_number_blank_for_agent_insight, if: :agent_insight?
  validate  :agent_insights_feature_enabled, if: :agent_insight?
  validate  :issue_number_blank_for_external_pr, if: :external_pr?
  validate  :external_pr_starts_implemented, if: :external_pr?, on: :create
  validates :external_pr_number, presence: true, if: :external_pr?
  validates :external_pr_number, uniqueness: { scope: :repository_id }, if: :external_pr?
  validate  :epic_belongs_to_same_user_and_repository
  before_validation :default_owner_user, on: :create
  before_validation :default_agent_provider, on: :create
  before_validation :default_credential_mode, on: :create
  before_validation :default_lifecycle_metadata, on: :create
  before_validation :set_target_repository_from_epic, on: :create
  before_validation :apply_simple_epic_automation_defaults, on: :create
  before_validation :defer_stale_closed_epic_assignment
  before_validation :sync_epic_title
  after_create :ensure_simple_epic_auto_approval
  before_create :generate_slug

  enum :validity, VALIDITIES.index_with(&:itself), prefix: true, validate: true
  enum :job_provider_setting, PROVIDER_SETTINGS.index_with(&:itself), prefix: true, validate: true
  enum :triaging_reason, TRIAGING_REASONS.index_with(&:itself), prefix: true, validate: true
  enum :stack_base, STACK_BASES.index_with(&:itself), prefix: true, validate: true
  enum :approved_via, APPROVAL_VIAS.index_with(&:itself), prefix: true, validate: { allow_nil: true }

  scope :open_threads, -> { where.not(state: TERMINAL_STATES) }
  scope :closed_threads, -> { where(state: "closed") }
  scope :not_manually_paused, -> { where(manual_paused: false) }
  # Effective ownership: owner_user_id when set, else the creating user.
  # Mirrors the `owner_user_id.presence || user_id` convention so a job
  # with a NULL owner still counts as its creator's for owner-scoped
  # views. Defensive against any residual NULL owners; new jobs default
  # owner_user_id at creation (see default_owner_user).
  scope :effectively_owned_by, ->(user) {
    where("jobs.owner_user_id = :id OR (jobs.owner_user_id IS NULL AND jobs.user_id = :id)", id: user.id)
  }
  scope :landing_queue, -> { where(state: %w[ approved landing ]) }
  scope :issue_kind, -> { where(kind: "issue") }
  scope :cron_kind,  -> { where(kind: "cron") }
  scope :direct_kind, -> { where(kind: "direct") }
  scope :external_pr_kind, -> { where(kind: "external_pr") }
  scope :with_pr, -> { where("pr_number IS NOT NULL OR external_pr_number IS NOT NULL") }
  scope :without_pr, -> { where(pr_number: nil, external_pr_number: nil) }
  scope :with_needs_attention, -> { where(needs_attention: true) }
  scope :in_grace_period, -> { where.not(grace_period_expires_at: nil).where("grace_period_expires_at > ?", Time.current) }
  scope :with_latest_workflow_snapshot, -> {
    latest_workflow_id = Job.latest_workflow_snapshot_sql("id")
    latest_workflow_state = Job.latest_workflow_snapshot_sql("state")
    latest_workflow_trigger_kind = Job.latest_workflow_snapshot_sql("trigger_kind")
    latest_workflow_created_at = Job.latest_workflow_snapshot_sql("created_at")
    latest_run_id = Job.latest_run_snapshot_sql("id")

    select(
      "jobs.*",
      "#{latest_workflow_id} AS latest_workflow_id",
      "COALESCE(#{latest_workflow_state}, 'queued') AS latest_workflow_state",
      "#{latest_workflow_trigger_kind} AS latest_workflow_trigger_kind",
      "#{latest_workflow_created_at} AS latest_workflow_created_at",
      "#{latest_run_id} AS latest_run_id"
    )
  }

  def previewable?
    implemented? || approved? || landing?
  end
  scope :without_active_workflows, -> {
    where(<<~SQL.squish)
      NOT EXISTS (
        SELECT 1 FROM workflows
        WHERE workflows.job_id = jobs.id
          AND workflows.state IN ('queued', 'running')
      )
    SQL
  }

  def issue?
    kind == "issue"
  end

  def self.latest_workflow_snapshot_sql(column)
    raise ArgumentError, "unknown workflow snapshot column" unless %w[id state trigger_kind created_at].include?(column.to_s)

    <<~SQL.squish
      (
        SELECT workflows.#{column}
        FROM workflows
        WHERE workflows.job_id = jobs.id
        ORDER BY (workflows.finished_at IS NULL) DESC, workflows.finished_at DESC, workflows.id DESC
        LIMIT 1
      )
    SQL
  end

  def self.latest_run_snapshot_sql(column)
    raise ArgumentError, "unknown run snapshot column" unless %w[id].include?(column.to_s)

    <<~SQL.squish
      (
        SELECT runs.#{column}
        FROM runs
        WHERE runs.job_id = jobs.id
        ORDER BY runs.id DESC
        LIMIT 1
      )
    SQL
  end

  def self.initial_state_for_creator(user)
    user&.product_owner? ? "needs_triage" : "triaging"
  end

  def cron?
    kind == "cron"
  end

  def direct?
    kind == "direct"
  end

  def main_grader?
    kind == "main_grader"
  end

  def agent_insight?
    kind == "agent_insight"
  end

  def external_pr?
    kind == "external_pr"
  end

  # The most recently created external_pr_ingest Workflow for this Job,
  # if any. Used to gate automatic rebase/landing dispatch and to drive
  # the "Retry PR Ingestion" action's visibility.
  def latest_external_pr_ingest_workflow
    workflows.where(trigger_kind: "external_pr_ingest").reorder(created_at: :desc, id: :desc).first
  end

  # True when this external PR Job's most recent ingest attempt failed
  # and has not since been explicitly retried (a fresh external_pr_ingest
  # Workflow dispatched via the "Retry PR Ingestion" action). Non-retryable
  # ingestion failure is an operator-action state — automatic rebase and
  # landing repair must not treat it as an input to fix.
  def external_pr_ingest_blocked?
    return false unless external_pr?

    latest_external_pr_ingest_workflow&.failed? || false
  end

  def main_branch_repair?
    system_kind == SYSTEM_KIND_MAIN_BRANCH_REPAIR ||
      (system_kind.blank? && direct? && issue_title == MAIN_BRANCH_REPAIR_TITLE)
  end

  def infrastructure?
    Workflow::INFRASTRUCTURE_TRIGGER_KINDS.include?(latest_workflow_trigger_kind)
  end

  def claimed?
    claimed_by_user_id.present?
  end

  def slug
    App::Presentation.job_slug(self)
  end

  def title
    issue_title.presence || slug
  end

  # Returns an "issue-shaped" object (responds to #title, #body) for
  # use by prompt classes that historically only knew about GitHub
  # issues. For issue Jobs this is delegated to GithubClient by the
  # caller; for cron Jobs we synthesize one from the parent
  # ScheduledTask so PrFeedback / CiFailure / PrSummarizer prompts
  # don't need to special-case kind.
  def synthetic_issue
    if cron? && scheduled_task
      Struct.new(:title, :body).new(
        "Scheduled task: #{scheduled_task.name}",
        scheduled_task.prompt.to_s
      )
    elsif direct?
      Struct.new(:title, :body).new(issue_title.to_s, issue_body.to_s)
    elsif external_pr?
      Struct.new(:title, :body).new(
        issue_title.presence || "External PR ##{external_pr_number}",
        issue_body.presence || "External PR ##{external_pr_number} submitted by #{external_pr_author}"
      )
    end
  end

  # Audited 2026-05-18 (`docs/job-state-audit.md`). The :open,
  # :landing_failed, and :merged states + the :land event were
  # unreachable dead code — removed. If a real need surfaces, re-add
  # with a transition that actually enters the state, not just a
  # `from:` reference.
  aasm column: :state, whiny_transitions: false do
    after_all_transitions :record_state_transition!
    state :needs_triage
    state :triaging, initial: true
    state :blocked_by_epic
    state :queued
    state :running
    state :implemented
    # Coding/Local Mode state: the job's implement step is owned by a chat session.
    # Automation is blocked while this state is active; linked_chat_id identifies
    # the owning session. Exit via release_from_coding/exit_local_mode (→ implemented) or close.
    state :coding
    state :failed
    # Legacy semi-terminal state for older no-change outcomes. New automatic
    # no-change outcomes close the Job with closure_reason=no_changes.
    state :no_change_needed
    state :approved
    state :landing
    state :closed

    event :advance_after_triage do
      transitions from: :triaging, to: :blocked_by_epic, guard: :blocked_by_epic_before_execution?
      transitions from: :triaging, to: :queued, guard: :ready_for_execution?, after: :create_initial_run_if_needed
    end

    event :release_for_triage do
      transitions from: :needs_triage, to: :triaging
    end

    event :mark_classifier_uncertain do
      transitions from: :triaging, to: :triaging, after: -> {
        self.triaging_reason = "classifier_uncertain"
      }
    end

    event :block_by_epic do
      transitions from: [ :triaging, :queued ], to: :blocked_by_epic, guard: :blocked_by_epic_before_execution?
    end

    event :release_epic_block do
      transitions from: :blocked_by_epic, to: :queued, guard: :ready_for_execution?, after: :create_initial_run_if_needed
    end

    # Fired by Workflow#start's after-callback when a workflow
    # (initial / retry / pr_comment / ci_failure / rebase, but NOT
    # auto_merge — landing has its own state) begins executing.
    # `:queued → :running` for the first attempt on a Job;
    # `:implemented → :running` when a follow-up workflow starts on
    # a Job whose PR already exists.
    event :start_running do
      transitions from: [ :queued, :implemented ], to: :running
    end

    # Steps::PrOpen transitions :running → :implemented when the
    # initial workflow's pr_open step succeeds and the PR is open.
    # For follow-up workflows (pr_comment, ci_failure, retry that
    # didn't open a new PR), Workflow#succeed's after-callback
    # transitions :running → :implemented since the PR already exists.
    event :mark_implemented do
      transitions from: [ :queued, :running ], to: :closed, guard: :main_grader?, after: :mark_main_grader_closed
      transitions from: [ :queued, :running ], to: :implemented, after: :notify_job_implemented
    end

    # Fired by Workflow#fail's after-callback for non-auto_merge
    # workflows. The Job is now waiting on operator decision — Retry
    # to attempt again (failed → queued) or Close.
    event :mark_failed do
      transitions from: :running, to: :failed
    end

    # When a rebase or stack-rebase workflow is cancelled before any run
    # starts and the job is stuck in :triaging (e.g. after a close+reopen
    # cycle from runaway workflow limits), restore it to :implemented.
    # The job has an open PR (that's why a rebase was dispatched), so
    # :implemented is the correct state. Without this rollback, the
    # merge-state poller keeps dispatching cancelled rebases indefinitely
    # because the job never advances out of :triaging.
    event :restore_after_cancelled_rebase do
      transitions from: :triaging, to: :implemented
    end

    # Operator recovery path for Jobs whose workflow state no longer
    # propagated back to the Job. Leaves the Job open and retryable.
    event :force_fail do
      transitions from: [
        :needs_triage,
        :triaging,
        :blocked_by_epic,
        :queued,
        :running,
        :implemented,
        :coding,
        :no_change_needed,
        :approved,
        :landing
      ], to: :failed
    end

    # Legacy repair transition for old no-change rows. Normal no-change
    # propagation now closes the Job with closure_reason=no_changes.
    event :mark_no_change_needed do
      transitions from: :running, to: :no_change_needed
    end

    # Retry pathway: the operator clicked Retry on a failed Job.
    # Goes back to :queued so a new workflow can be instantiated.
    event :retry_after_failure do
      transitions from: :failed, to: :queued
      transitions from: :running, to: :queued
    end

    # Retry pathway after an operator reopens a cancelled Job. Reopen
    # intentionally returns the Job to :triaging, but retrying should enqueue
    # exactly one fresh retry Workflow, not re-run the first-attempt triage
    # callback that may create another initial Workflow.
    event :queue_reopened_retry do
      transitions from: :triaging, to: :queued, guard: :ready_for_execution?
    end

    # Operator takes over a Job from the Local Mode chat. Acquires the coding
    # session on this Job, linking it to the chat so the agent can commit and
    # trigger graders via complete_implement_step.
    event :enter_local_mode do
      transitions from: :implemented, to: :coding
    end

    # Completes or cancels a local-mode coding session, returning the Job to
    # :implemented so it can be approved/re-edited normally.
    event :exit_local_mode do
      transitions from: :coding, to: :implemented
    end

    event :approve, before: :assign_approval_metadata do
      transitions from: :implemented, to: :approved
    end

    event :restore_approved_after_landing_start_blocker, after: :clear_runaway_protection do
      transitions from: :failed, to: :approved
    end

    event :unapprove, after: :clear_approval_metadata do
      transitions from: :approved, to: :implemented
    end

    # Coding Mode lifecycle events. `claim_for_coding` enters the :coding state
    # when a chat session's Coding Mode takes ownership of the implement step.
    # `release_from_coding` exits back to :implemented (taken-over job cancel /
    # eventual handoff). Closing a coding job uses the normal `close` event.
    event :claim_for_coding do
      transitions from: [ :queued, :implemented ], to: :coding
    end

    event :release_from_coding do
      transitions from: :coding, to: :implemented
    end

    # Reverts a running coding_handoff workflow's job back to :coding
    # when graders fail. The workflow skips propagate_fail_to_job! so
    # the job remains :running until this event fires in after_fail.
    event :revert_to_coding_mode do
      transitions from: :running, to: :coding
    end

    event :start_landing do
      transitions from: :approved, to: :landing
    end

    # Single after-callback hook on the transition. The previous
    # event-level `after: :refresh_epic_auto_state` was redundant
    # with the after_save callback and just made the wiring harder
    # to read.
    event :close do
      transitions from: [ :needs_triage, :triaging, :blocked_by_epic, :queued, :running, :implemented, :failed, :no_change_needed, :approved, :landing, :coding ], to: :closed, after: -> {
        self.finished_at = Time.current
        self.commits_behind_base = nil
        record_outcome_to_scheduled_task! if cron?
        notify_pr_merged
        refresh_epic_auto_state
      }
    end

    event :fail_landing do
      transitions from: :landing, to: :implemented, after: -> {
        clear_approval_metadata
      }
    end

    # Deferring landing is "we want to merge but not right now" — e.g.
    # mergeable_state needs a rebase first, or a transient GitHub
    # error. The approval persists (operator's intent is unchanged);
    # the Job stays in :approved so LandingQueueProcessor can re-pick
    # it up automatically once the blocker clears (rebase finishes,
    # GitHub recovers). Contrast with fail_landing, which is the
    # "give up; require operator re-approval" path.
    event :defer_landing do
      transitions from: :landing, to: :approved
    end

    # Undoes a close. Clears closure_reason + finished_at so the thread
    # looks alive again. Doesn't un-cancel any cancelled Runs (those
    # invocations really did stop) — the user follows up with
    # "Retry" to spawn a fresh Run if they want.
    # Polling resumes automatically once the Job is open again.
    event :reopen do
      transitions from: :closed, to: :triaging, after: -> {
        self.closure_reason = nil
        self.finished_at = nil
        self.failure_count = 0
        self.reopened_at = Time.current
        self.triaging_reason ||= "classifier_pending"
        self.runaway_protection = nil
        self.runaway_protection_at = nil
      }
    end
  end

  # Issue Jobs autostart their initial Run on create (the standard
  # issue-driven flow). Cron Jobs do NOT — PollScheduledTasksJob
  # creates the initial Run explicitly with a pre-rendered prompt
  # (variables expanded, preamble wrapped) so that {{date}} and
  # friends reflect the fire time, not whatever moment RunJob happens
  # to start executing.
  #
  # Skip both for Jobs that are created already closed — the
  # "preempted" path where Syrus discovered an external PR already
  # targeting this issue and recorded the Job for the operator's
  # awareness without scheduling any agent work.
  after_create :seed_parsed_dependencies
  after_create :resolve_pending_dependencies_targeting_self
  after_create_commit :enqueue_search_index_after_create
  after_create_commit :broadcast_app_job_created
  # `after_save :refresh_epic_auto_state` used to fire on every save.
  # Keep it scoped to changes that actually affect the epic rollup:
  # state transitions, validity, epic membership, and closure metadata.
  # The :close event also calls it explicitly via the transition
  # `after:` lambda.
  after_save :refresh_epic_auto_state,
             if: -> { epic_id.present? && (saved_change_to_state? || saved_change_to_validity? || saved_change_to_epic_id? || saved_change_to_closure_reason?) }
  after_commit :reopen_recent_closed_epic, if: :saved_change_to_epic_id?
  after_commit :suggest_stale_closed_epic_assignment, if: :stale_closed_epic_assignment?

  after_update_commit :rebase_stack_children_after_successful_parent_close, if: :saved_change_to_stack_parent_resolved_terminal?
  after_update_commit :start_dependent_jobs_after_implementation, if: :saved_change_to_implemented?
  after_update_commit :promote_queued_chat_pending_actions, if: :saved_change_to_implemented?
  after_update_commit :auto_approve_main_branch_repair_after_implementation, if: :saved_change_to_implemented_main_branch_repair?
  after_update_commit :cancel_queued_chat_pending_actions, if: :saved_change_to_closed?
  after_update_commit :purge_coverage_hit_maps_on_close, if: :saved_change_to_closed?
  after_update_commit :enqueue_close_external_pr, if: :saved_change_to_closed_external_pr_to_close?
  after_update_commit :trigger_insight_if_max_threshold_reached, if: :saved_change_to_closed_coding_job?
  after_update_commit :ensure_main_branch_repair_after_close, if: :saved_change_to_closed_main_branch_repair?
  after_update_commit :enqueue_urgent_job_closed, if: :saved_change_to_closed_urgent_job?
  after_update_commit :start_dependent_jobs_after_successful_close, if: :saved_change_to_successful_closed_dependency?
  after_update_commit :start_dependent_jobs_after_approval, if: :saved_change_to_approved?
  after_update_commit :cancel_queued_retry_workflows_after_approval, if: :saved_change_to_approved?
  after_update_commit :enqueue_landing_queue_processor, if: :saved_change_needs_landing_queue_processor?
  after_update_commit :enqueue_search_index_after_update
  after_update_commit :broadcast_app_job_updated

  def solid_queue_priority
    PRIORITY_TO_SQ.fetch(priority.to_s, PRIORITY_TO_SQ["medium"])
  end

  # "The thread is alive" — any non-terminal state. Distinct from
  # the (removed) AASM :open state predicate; the name is preserved
  # to match the GitHub-issue vocabulary the rest of the codebase
  # uses (`open_threads` scope, GitHub API's "state=open" filter).
  def open?
    !closed?
  end

  def pause_manually!(by_user:)
    update!(
      manual_paused: true,
      manual_paused_at: Time.current,
      manual_paused_by_user: by_user
    )
  end

  def unpause_manually!
    update!(
      manual_paused: false,
      manual_paused_at: nil,
      manual_paused_by_user: nil
    )
  end

  def ready_for_execution?
    validity == "valid" && !triaging_reason_pending_epic_ref? && !blocked_by_epic_before_execution?
  end

  def effective_target_repository
    target_repository || repository
  end

  def workflow_agent_provider
    Job::ProviderSetting::Base.for(job_provider_setting).resolve(self)
  end

  def switch_job_provider_setting!(setting)
    previous_provider = workflow_agent_provider
    update!(job_provider_setting: setting)
    next_provider = workflow_agent_provider
    App::ProviderAvailability.broadcast_changed(user: user, provider: previous_provider) if previous_provider.present? && previous_provider != next_provider
    App::ProviderAvailability.broadcast_changed(user: user, provider: next_provider)
  end

  def effective_pr_repository
    pr_repository || repository
  end

  # True when the job is working in a fork and targeting a different upstream
  # repository. In this mode, pr_open creates a fork review PR (feature branch
  # → fork default branch) as a staging artifact rather than opening the
  # upstream PR directly. The upstream PR is created by ForkReviewApprover
  # after the fork review PR is approved or merged.
  def in_fork_review_mode?
    target_repository_id.present? && target_repository_id != repository_id
  end

  def blocked_by_epic_before_execution?
    return false unless epic
    return false if epic.releases_jobs_for_execution?

    true
  end

  def prepare_skip_reason
    return "repository_configuration" unless repository.effective_prepare_enabled
    return "issue_label" if prepare_skip_reason_override == "issue_label"
    return "issue_label" if skip_prepare?
    return "issue_label" if Workflow.where(job_id: id).where(
      "artifacts LIKE ? OR artifacts LIKE ?",
      '%"prepare_skipped_reason":"issue_label"%',
      '%"prepare_skipped_reason": "issue_label"%'
    ).exists?

    nil
  end

  def close_with_reason!(reason)
    update!(closure_reason: reason)
    close!
  end
  def approve_for_landing!
    return true if approved? || landing? || closed?

    approve!(via: "github_review")
  end

  def auto_merge_enabled?
    auto_merge_enabled || repository.auto_merge_enabled?
  end

  def mark_feedback_addressed!(addressed_at)
    return if addressed_at.blank?
    return if last_feedback_addressed_at && last_feedback_addressed_at >= addressed_at

    update!(last_feedback_addressed_at: addressed_at)
  end

  # Returns true when the repository's review_policy is satisfied by
  # the existing job_approvals. Used by the approve action and the
  # landing queue to gate the job's transition to :approved.
  def approval_satisfied?
    ReviewPolicies.for(repository.review_policy).new(self).satisfied?
  end

  # Returns true when +user+ is eligible to add a JobApproval vote.
  # The creator (user_id) is blocked unless they are also the owner.
  def can_add_job_approval?(user)
    return false unless implemented?

    effective_owner_id = owner_user_id.presence || user_id
    user.id == effective_owner_id || user.id != user_id
  end

  def approve!(*args, **kwargs)
    raise AASM::InvalidTransition.new(self, :approve, :default) unless may_approve?

    approve(*args, **kwargs).tap { save! }
  end

  def unapprove!(*args, **kwargs)
    raise AASM::InvalidTransition.new(self, :unapprove, :default) unless may_unapprove?

    unapprove(*args, **kwargs).tap { save! }
  end

  def record_github_review_approval!(review_url:, approved_at: Time.current, reviewer_user: nil)
    mark_implemented! if may_mark_implemented?
    return false unless may_approve?

    approver = reviewer_user || user
    approval = job_approvals.find_or_initialize_by(user: approver)
    approval.approved_at ||= approved_at
    approval.save!

    return false unless approval_satisfied?

    approve!(
      via: "github_review",
      evidence: { "github_review_url" => review_url }.compact,
      at: approved_at
    )
  end

  # Cancels every active Run on this Job and closes the thread. Used by
  # both the Cancel button (reason: "cancelled") and Restart (reason:
  # "replaced"). Idempotent on already-closed Jobs.
  def cancel_active_runs_and_close!(reason)
    return if closed?
    runs.active.find_each do |run|
      run.cancel! if run.may_cancel?
      run.save!
    end
    close_with_reason!(reason)
  end

  def mark_externally_implemented!(number)
    transaction do
      runs.active.find_each do |run|
        run.cancel! if run.may_cancel?
        run.save!
      end

      self.external_pr_number = number
      self.state = "implemented"
      self.closure_reason = nil
      self.finished_at = nil
      self.landing_failure_reason = nil
      clear_approval_metadata
      save!
    end
  end

  # The most recently created Run on this thread, regardless of state.
  def current_run
    runs.last
  end
  SUCCESSFUL_CLOSURE_REASONS = %w[
    pr_merged
    external_pr_merged
    pr_approved
    no_changes
  ].freeze
  # --- needs_attention flag --------------------------------------------------
  # Called by RunJob after a non-rebase run fails. Increments the
  # failure counter and auto-closes the job if the configured threshold
  # is reached, preventing further polling from scheduling new runs
  # until an operator reopens it (which also resets the counter).
  def record_run_failure!
    increment!(:failure_count)
    return if closed?
    if failure_count >= AppSetting.max_job_failures
      close_with_reason!("too_many_failures")
      if AppSetting.simple? && epic
        epic.notify_child_failed
      else
        NotificationService.create_for(
          user: user,
          kind: "job_failed",
          job: self,
          pr_url: notification_pr_url,
          body: "#{slug} failed after repeated retries: #{title.truncate(80)}"
        )
      end
    end
  end

  def enforce_workflow_runaway_limits!(created_workflow: nil, failed_workflow: nil)
    return if closed?
    return if runaway_protection.present?

    total = workflows_since_latest_reopen.count
    return close_for_workflow_runaway!("too_many_workflows", created_workflow || failed_workflow, total: total) if total >= MAX_TOTAL_WORKFLOWS
    return unless failed_workflow

    failed_streak = consecutive_failed_workflows_count
    return if failed_streak < MAX_CONSECUTIVE_FAILED_WORKFLOWS

    close_for_workflow_runaway!("too_many_failed_workflows", failed_workflow, total: total, failed_streak: failed_streak)
  end

  def consecutive_failed_workflows_count
    workflows_since_latest_reopen.reorder(created_at: :desc, id: :desc)
             .limit(MAX_CONSECUTIVE_FAILED_WORKFLOWS)
             .select(:id, :state, :failure_reason, :artifacts, :trigger_kind)
             .take_while { |workflow| workflow.failed? && !landing_start_blocker_workflow?(workflow) }
             .count
  end

  def landing_start_blocker_workflow?(workflow)
    return false unless workflow&.landing_workflow?

    LandingQueueReentry.landing_start_blocker?(
      workflow.failure_reason.presence ||
        workflow.artifact("failure_reason") ||
        workflow.artifact("start_blocked_reason")
    )
  end

  def workflows_since_latest_reopen
    return workflows unless reopened_at?

    workflows.where(Workflow.arel_table[:created_at].gteq(reopened_at))
  end

  def runaway_protected?
    runaway_protection.present?
  end

  def close_for_workflow_runaway!(reason, workflow, total:, failed_streak: nil)
    if workflow&.state.in?(%w[queued running]) && workflow.may_cancel?
      workflow.cancel!
      workflow.save!
    end

    # Transition to :failed without closing, so the branch is preserved and
    # ReapStaleBranchesJob does not delete it. Reload to pick up any state
    # changes made by propagate_cancel_to_job! in the workflow's cancel callback.
    reload unless new_record?
    unless failed?
      force_fail! if may_force_fail?
      save!
    end

    failed_streak ||= consecutive_failed_workflows_count
    update!(
      runaway_protection:    reason,
      runaway_protection_at: Time.current
    )

    # For cron jobs record the failure toward the task's consecutive-failure cap
    # (previously handled by the close event's record_outcome_to_scheduled_task!).
    scheduled_task.record_failure! if cron? && scheduled_task

    NotificationService.create_for(
      user: user,
      kind: "job_failed",
      job: self,
      pr_url: notification_pr_url,
      body: "#{slug} stopped after runaway workflow activity: #{title.truncate(80)}"
    )
    run = workflow&.runs&.order(:id)&.last || current_run
    return unless run

    JobLog.append!(
      run: run,
      kind: "system",
      chunk: "job stopped: #{reason} (#{total} total workflows, #{failed_streak} consecutive failed workflows)"
    )
  end

  # When a cron Job reaches a terminal state, propagate the outcome
  # to its parent ScheduledTask. Only `too_many_failures` counts as
  # a failure (consumes the consecutive_failure cap that may pause
  # the schedule). The "replaced_by_scheduled_task" reason is just
  # bookkeeping for pile-replace policy and is neither a success nor
  # a failure for the parent.
  def record_outcome_to_scheduled_task!
    return unless scheduled_task
    outcome = SCHEDULED_TASK_OUTCOMES.fetch(closure_reason, :record_success!)
    scheduled_task.public_send(outcome) if outcome
  end

  private

  def generate_slug
    base = issue_title.to_s.parameterize.presence
    return unless base

    base = base.first(50)
    n = 1
    candidate = base
    loop do
      break unless Job.where(slug: candidate).exists?
      candidate = "#{base.first(46)}-#{n}"
      n += 1
    end
    self[:slug] = candidate
  end

  def saved_change_to_implemented?
    saved_change_to_state? && implemented?
  end

  def saved_change_to_closed?
    saved_change_to_state? && closed?
  end

  def saved_change_to_closed_main_branch_repair?
    saved_change_to_closed? && main_branch_repair?
  end

  def saved_change_to_closed_urgent_job?
    saved_change_to_closed? && priority == "urgent"
  end

  def saved_change_to_closed_coding_job?
    saved_change_to_closed? && !agent_insight?
  end

  def saved_change_to_closed_external_pr_to_close?
    saved_change_to_closed? && external_pr? && external_pr_number.present? &&
      !closure_reason.in?(%w[external_pr_merged external_pr_closed])
  end

  def saved_change_to_implemented_main_branch_repair?
    saved_change_to_implemented? && main_branch_repair?
  end

  def saved_change_to_approved?
    saved_change_to_state? && approved?
  end

  def ensure_main_branch_repair_after_close
    if closure_reason.in?(%w[pr_merged external_pr_merged])
      MainHealthChangedService.repair_landed!(repository, job: self)
    else
      MainHealthChangedService.ensure_repair_job!(repository)
    end
  end

  def enqueue_urgent_job_closed
    UrgentJobClosedJob.perform_later(repository_id)
  end

  def enqueue_close_external_pr
    CloseExternalPrJob.perform_later(id)
  end

  def trigger_insight_if_max_threshold_reached
    return unless Feature.agent_insights_enabled?

    config = repository.insight_schedule_config
    return unless config&.enabled?

    last_insight_at = InsightScheduler.last_insight_created_at(repository)
    count = InsightScheduler.coding_jobs_since(repository, last_insight_at)
    return if count < config.max_jobs_since_last_run

    InsightScheduler.enqueue_if_idle!(repository)
  end

  def cancel_queued_retry_workflows_after_approval
    workflows.where(trigger_kind: "retry", state: "queued").find_each do |workflow|
      workflow.artifacts = (workflow.artifacts || {}).merge(
        "retry_cancelled_reason" => "job_approved",
        "retry_cancelled_at" => Time.current.iso8601
      )
      workflow.cancel! if workflow.may_cancel?
      workflow.save!
    end
  end

  def promote_queued_chat_pending_actions
    ChatPendingAction.promote_queued_for_job!(self)
  end

  def auto_approve_main_branch_repair_after_implementation
    MainBranchRepairAutoApprover.call(self)
  end

  def notify_job_implemented
    return unless notify_job_implemented_on_transition

    NotificationService.create_for(
      user: user,
      kind: "job_implemented",
      job: self,
      pr_url: notification_pr_url,
      body: "Syrus opened PR ##{pr_number} for #{slug}: #{title.truncate(80)}"
    )
  end

  def mark_main_grader_closed
    self.closure_reason = MAIN_GRADER_CLOSURE_REASON
    self.finished_at ||= Time.current
  end

  def purge_coverage_hit_maps_on_close
    workflows.find_each do |workflow|
      workflow.purge_coverage_hit_map! if workflow.coverage_hit_map.attached?
    rescue StandardError => e
      Rails.logger.warn("Job#purge_coverage_hit_maps_on_close: workflow #{workflow.id} failed: #{e.message}")
    end
  end

  def notify_pr_merged
    return unless closure_reason.in?(%w[ pr_merged external_pr_merged ])

    NotificationService.create_for(
      user: user,
      kind: "pr_merged",
      job: self,
      pr_url: notification_pr_url,
      body: "#{slug} merged: #{title.truncate(80)}"
    )
  end

  def notification_pr_url
    App::Presentation.job_pr_url(self) || App::Presentation.external_pr_url(self)
  end

  def cancel_queued_chat_pending_actions
    ChatPendingAction.cancel_queued_for_job!(self)
  end

  def start_dependent_jobs_after_implementation
    return if branch_name.blank? || pr_number.blank?

    start_dependent_jobs_if_ready
  end

  def start_dependent_jobs_after_approval
    start_dependent_jobs_if_ready
  end

  def start_dependent_jobs_after_successful_close
    start_dependent_jobs_if_ready
  end

  def start_dependent_jobs_if_ready
    dependents.open_threads.find_each do |dependent|
      dependent.start_pending_workflows_if_dependencies_satisfied!
    end
  end

  def epic_internal_dependency?
    return false if epic_id.blank?

    dependencies.includes(:depends_on_job).any? do |dependency|
      dependency.depends_on_job&.epic_id == epic_id
    end
  end

  def broadcast_app_job_created
    broadcast_app_job_event("created")
  end

  def broadcast_app_job_updated
    broadcast_app_job_event("updated")
  end

  def broadcast_app_job_event(action)
    return unless user

    event = {
      type: "job.updated",
      resource: "job",
      id: id,
      changed: [ "job.#{action}", *previous_changes.keys.map(&:to_s) ].uniq,
      occurred_at: Time.current.iso8601(3)
    }

    AppUserChannel.broadcast_to(user, event.as_json)
  end

  # Issue Jobs auto-instantiate Workflows::Initial on create. The
  # workflow lays out the implement → summarize → test_plan → pr_open chain;
  # StepDispatcher.start_workflow creates the first Run. RunJob still
  # auto-enqueues via Run's after_create_commit, so background work
  # waits for the surrounding transaction to commit. Same
  # observable behavior as the v0 single-Run flow, but each
  # phase is now its own attemptable step.
  def create_initial_run
    template = main_branch_repair? ? Workflows::MainBranchRepair : Workflows::Initial
    workflow = template.instantiate(job: self)
    prompt = if direct?
      Prompts::DirectJob.new(
        prompt: issue_body.to_s,
        epic: epic,
        job: self,
        user: user,
        repository_ids: [ repository_id ]
      ).to_s
    end
    StepDispatcher.start_workflow(workflow, prompt: prompt)
  end

  def enqueue_search_index_after_create
    enqueue_search_index
  end

  def enqueue_search_index_after_update
    enqueue_search_index
  end

  def enqueue_search_index
    enqueue_search_index_job(IndexJobSearchJob, id)
  end

  # Auto-create the Job's first workflow when the Job reaches :queued
  # (via advance_after_triage or release_epic_block). Both issue and
  # direct Jobs use this contract — once filed and not blocked by an
  # epic or dependency, a direct Job starts on its own. Cron Jobs are
  # excluded; PollScheduledTasksJob seeds them with a pre-rendered
  # prompt at fire time.
  def create_initial_run_if_needed
    return if cron?
    return if main_grader?
    return if workflows.where.not(state: "cancelled").exists?

    create_initial_run
  end

  def defer_stale_closed_epic_assignment
    return unless new_record? || will_save_change_to_epic_id?

    closed_epic = epic || (Epic.find_by(id: epic_id) if epic_id.present?)
    return unless closed_epic&.done?
    return if closed_epic_reopenable?(closed_epic)

    @stale_closed_epic_assignment_id = closed_epic.id
    self.epic = nil
  end

  def stale_closed_epic_assignment?
    @stale_closed_epic_assignment_id.present?
  end

  def reopen_recent_closed_epic
    return unless epic&.done?
    return unless closed_epic_reopenable?(epic)

    epic.in_progress!
    log_epic_auto_reopen(epic)
  end

  def log_epic_auto_reopen(closed_epic)
    message = "Epic #{closed_epic.slug} auto-reopened for #{slug}."
    Rails.logger.info("[EpicAssignment] #{message}")

    planning_chat_for(closed_epic)&.messages&.create!(
      role: "system",
      content: { "text" => message }
    )
  end

  def suggest_stale_closed_epic_assignment
    closed_epic = user.epics.find_by(id: @stale_closed_epic_assignment_id)
    @stale_closed_epic_assignment_id = nil
    return unless closed_epic

    chat = planning_chat_for_pending_action(closed_epic)
    text = "This new issue resembles closed #{closed_epic.slug}; reopen and attach?"
    chat.messages.create!(role: "system", content: { "text" => text })
    chat.pending_actions.create!(
      action: "reopen_epic_and_attach_job",
      repository: repository,
      user: user,
      requested_by: "agent",
      payload: {
        "confidence" => "low",
        "epic_id" => closed_epic.id,
        "job_id" => id
      }
    )
  end

  def planning_chat_for(closed_epic)
    user.chat_sessions
      .joins(:chat_attachments, messages: :bookmarks)
      .where(chat_attachments: { attachable_type: "Epic", attachable_id: closed_epic.id })
      .where(chat_bookmarks: { kind: "epic_origin" })
      .order("chat_bookmarks.created_at ASC", "chat_sessions.created_at ASC", "chat_sessions.id ASC")
      .first ||
      user.chat_sessions
        .joins(:chat_attachments)
        .where(chat_attachments: { attachable_type: "Epic", attachable_id: closed_epic.id })
        .order(created_at: :asc, id: :asc)
        .first
  end

  def create_planning_chat_for(closed_epic)
    user.chat_sessions.create!(
      repository: repository,
      title: "Planning #{closed_epic.slug}"
    ).tap do |chat|
      chat.chat_attachments.find_or_create_by!(attachable: closed_epic)
    end
  end

  def planning_chat_for_pending_action(closed_epic)
    chat = planning_chat_for(closed_epic)
    if chat && chat.repository_id.nil?
      chat.chat_attachments.find_or_create_by!(attachable: repository)
      chat.association(:attached_repositories).reset
    end

    return chat if chat&.repository_id == repository_id

    create_planning_chat_for(closed_epic)
  end

  def seed_parsed_dependencies
    return unless issue?

    text = issue_body.to_s
    return if text.blank?

    JobDependencyParser.parse(text: text, default_repository: repository).each do |reference|
      referenced_repository = user.repositories.find_by(owner: reference.owner, name: reference.repo)
      depends_on_job = referenced_repository&.jobs&.where(issue_number: reference.number)&.order(:created_at)&.last

      if depends_on_job
        dependencies.find_or_create_by!(depends_on_job: depends_on_job) do |dependency|
          dependency.source = "parsed"
        end
      else
        # Target Job doesn't exist yet. Persist a pending row; when the
        # referenced issue is later ingested as a Job, the after_create
        # hook on that Job (resolve_pending_dependencies_targeting_self)
        # promotes this row to a resolved dependency.
        dependencies.find_or_create_by!(
          unresolved_owner: reference.owner,
          unresolved_repo: reference.repo,
          unresolved_number: reference.number
        ) do |dependency|
          dependency.source = "parsed"
        end
        Rails.logger.info(
          "[JobDependency] #{slug}: Depends-on: " \
          "#{reference.owner}/#{reference.repo}##{reference.number} — " \
          "no Syrus Job exists yet; recorded as pending"
        )
      end
    end
  end

  # After this Job is created, look for any existing pending dependencies
  # whose unresolved reference points at this Job's (owner, repo,
  # issue_number) triple and promote them to resolved rows. This is the
  # "deferred resolution" half of the fix for bulk-ingest order problems:
  # a Job filed earlier with `Depends-on: #this_issue` gets its
  # placeholder row converted to a real dependency now that the target
  # Job exists.
  def resolve_pending_dependencies_targeting_self
    return unless issue? && issue_number.present?

    candidates = JobDependency.pending.where(
      unresolved_owner: repository.owner,
      unresolved_repo: repository.name,
      unresolved_number: issue_number
    )

    candidates.find_each do |dependency|
      # Only resolve for dependents owned by the same user as this Job
      # (matches the user.repositories scope used when seeding).
      next unless dependency.job.user_id == user_id

      dependency.resolve!(depends_on_job: self)
      Rails.logger.info(
        "[JobDependency] resolved pending dep on #{::App::Presentation.job_slug(dependency.job_id)}: " \
        "Depends-on: #{repository.owner}/#{repository.name}##{issue_number} -> #{slug}"
      )
    rescue ActiveRecord::RecordInvalid => e
      Rails.logger.warn(
        "[JobDependency] failed to resolve pending dep on #{::App::Presentation.job_slug(dependency.job_id)}: #{e.message}"
      )
    end
  end

  def log_dependency_override!(user)
    run = current_run
    return unless run

    JobLog.append!(
      run: run,
      chunk: "dependencies: #{user.email_address} overrode unsatisfied dependencies",
      kind: "system"
    )
  end

  def default_owner_user
    # owner_user_id is the durable assignee that owner-scoped dashboard
    # views (notably the inbox) filter on. Non-Epic jobs (issue/cron/direct)
    # had no code populating it, so they were created with a NULL owner and
    # silently dropped out of those views. Default it from the creating user.
    #
    # Epic children inherit owner from the parent epic when the epic is
    # already claimed, so jobs added later (standalone proposals, reconciliation
    # jobs) appear under the right owner scope without waiting for a claim
    # cascade. When the epic is unclaimed (owner_user_id nil), the job stays
    # unowned — it will be cascaded when the epic is eventually claimed via
    # Epic#assign_owner!.
    if epic_id.present?
      self.owner_user_id ||= epic&.owner_user_id
      return
    end

    self.owner_user_id ||= user_id
  end

  def default_agent_provider
    effective_user = owner_user || user
    self.agent_provider ||= repository&.effective_agent_provider(user: effective_user) || effective_user&.agent_provider
  end

  def default_credential_mode
    self.credential_mode = repository&.credential_mode || "pat"
  end

  def default_lifecycle_metadata
    self.validity ||= "valid"
    self.triaging_reason ||= "classifier_pending"
    self.invalidation_evidence ||= []
    self.approval_evidence ||= {}
    self.pending_epic_reference ||= {}
  end

  def apply_simple_epic_automation_defaults
    return unless AppSetting.simple?
    return unless epic || epic_id.present?

    self.auto_merge_enabled = true
  end

  def ensure_simple_epic_auto_approval
    return unless AppSetting.simple?
    return unless epic
    return if epic.auto_approve_mode == "if_graders_pass"

    epic.update!(auto_approve_mode: "if_graders_pass")
  end

  def assign_approval_metadata(*args)
    options = args.last.is_a?(Hash) ? args.last : {}
    self.approved_at = options[:at] || Time.current
    self.approved_via = options.fetch(:via)
    self.approved_by_user = options[:by_user]
    self.approval_evidence = options[:evidence].presence || {}
    self.landing_failure_reason = nil
  end

  def clear_approval_metadata
    self.approved_at = nil
    self.approved_via = nil
    self.approved_by_user = nil
    self.approval_evidence = {}
    job_approvals.destroy_all
  end

  def clear_runaway_protection
    self.runaway_protection = nil
    self.runaway_protection_at = nil
  end

  def epic_belongs_to_same_user_and_repository
    return unless epic

    errors.add(:epic, "must belong to the same user") if epic.user_id != user_id
    # Allow: direct repo match, OR fork-to-upstream (job's repo is a fork whose
    # upstream is the epic's repo).
    same_repo = epic.repository_id == repository_id
    fork_to_upstream = repository && repository.upstream_repository_id == epic.repository_id
    errors.add(:epic, "must belong to the same repository or its upstream") unless same_repo || fork_to_upstream
  end

  def set_target_repository_from_epic
    return unless epic
    return unless repository

    if repository.upstream_repository_id == epic.repository_id
      self.target_repository_id = epic.repository_id
    end
  end

  def sync_epic_title
    if epic
      self.epic_title = epic.title
    elsif epic_id.present?
      self.epic_title = Epic.where(id: epic_id).pick(:title)
    else
      self.epic_title = nil
    end
  end

  def refresh_epic_auto_state
    epic&.refresh_auto_state!
  end

  def issue_number_blank_for_cron
    errors.add(:issue_number, "must be blank for cron Jobs") if issue_number.present?
  end

  def issue_number_blank_for_direct
    errors.add(:issue_number, "must be blank for direct Jobs") if issue_number.present?
  end

  def issue_number_blank_for_main_grader
    errors.add(:issue_number, "must be blank for main_grader Jobs") if issue_number.present?
  end

  def issue_number_blank_for_agent_insight
    errors.add(:issue_number, "must be blank for agent_insight Jobs") if issue_number.present?
  end

  def issue_number_blank_for_external_pr
    errors.add(:issue_number, "must be blank for external_pr Jobs") if issue_number.present?
  end

  def external_pr_starts_implemented
    errors.add(:state, "must be implemented for external_pr Jobs") unless implemented?
  end

  def agent_insights_feature_enabled
    errors.add(:kind, "agent_insights feature is disabled") unless Feature.agent_insights_enabled?
  end

  def saved_change_to_stack_parent_resolved_terminal?
    saved_change_to_state? && closed? && closure_reason.in?(%w[ pr_merged no_changes ])
  end

  def saved_change_to_successful_closed_dependency?
    saved_change_to_state? && closed? && SUCCESSFUL_CLOSURE_REASONS.include?(closure_reason)
  end

  def saved_change_needs_landing_queue_processor?
    return true if saved_change_to_state? && approved?
    return true if saved_change_to_state? && closed? && closure_reason.in?(%w[ pr_merged no_changes ])

    false
  end

  def enqueue_landing_queue_processor
    LandingQueueProcessorJob.perform_later
  end

  def rebase_stack_children_after_successful_parent_close
    StackRebaseCoordinator.parent_merged(self)
  end
end
