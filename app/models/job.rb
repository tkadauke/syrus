class Job < ApplicationRecord
  include AASM
  include RecordsStateTransitions

  KINDS = %w[ issue cron direct ].freeze
  CREDENTIAL_MODES = %w[ app pat ].freeze
  PREPARE_SKIP_LABEL = "syrus-skip-prepare".freeze

  PRIORITIES = %w[ high medium low ].freeze
  STACK_BASES = %w[ auto main ].freeze
  VALIDITIES = %w[ valid duplicate already_implemented ].freeze
  TRIAGING_REASONS = %w[ classifier_pending pending_epic_ref classifier_uncertain ].freeze
  APPROVAL_VIAS = %w[ operator bulk github_review auto_rule ].freeze
  # Maps priority label → SolidQueue priority integer. SolidQueue dispatches
  # lower numbers first, so high-priority jobs (0) run before medium (10) and
  # low (20). The gap of 10 between levels leaves room for future additions
  # without renumbering existing entries.
  PRIORITY_TO_SQ = { "high" => 0, "medium" => 10, "low" => 20 }.freeze
  attr_accessor :prepare_skip_reason_override, :pending_dependency_warnings

  belongs_to :user
  belongs_to :owner_user, class_name: "User", optional: true
  belongs_to :repository
  belongs_to :scheduled_task, optional: true
  belongs_to :epic, optional: true
  belongs_to :parent_job, class_name: "Job", optional: true
  belongs_to :dependencies_overridden_by_user, class_name: "User", optional: true
  belongs_to :approved_by_user, class_name: "User", optional: true
  belongs_to :owner_user, class_name: "User", optional: true
  has_many :workflows, -> { order(:created_at) }, dependent: :destroy
  # Runs hang off Steps now (Job → Workflow → Step → Run) — Job's
  # direct has_many :runs is a convenience accessor, NOT a cascade
  # parent. Cascade flows through workflows. Runs all carry job_id
  # for the existing Run.belongs_to :job association used widely
  # in views and queries.
  has_many :runs, -> { order(:created_at) }
  has_many :auto_retry_attempts, dependent: :destroy
  has_many :job_logs, through: :runs
  has_many :job_pins, dependent: :destroy
  has_many :pinning_users, through: :job_pins, source: :user
  has_many :documents, -> { order(:created_at, :id) }, as: :attachable, dependent: :destroy
  has_many :job_attachments, -> { order(:created_at, :id) }, as: :attachable, class_name: "Document", dependent: :destroy
  has_many :job_tags, dependent: :destroy
  has_many :tags, -> { order(Arel.sql("LOWER(tags.name) ASC")) }, through: :job_tags
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

  validates :kind, presence: true, inclusion: { in: KINDS }
  validates :credential_mode, presence: true, inclusion: { in: CREDENTIAL_MODES }
  validates :priority, presence: true, inclusion: { in: PRIORITIES }
  validates :stack_base, presence: true, inclusion: { in: STACK_BASES }
  validates :agent_provider, presence: true, inclusion: { in: User::AGENT_PROVIDERS }
  validates :validity, presence: true, inclusion: { in: VALIDITIES }
  validates :triaging_reason, presence: true, inclusion: { in: TRIAGING_REASONS }
  validates :approved_via, inclusion: { in: APPROVAL_VIAS }, allow_nil: true
  validates :issue_number,
            presence: true,
            numericality: { only_integer: true, greater_than: 0 },
            if: :issue?
  validates :scheduled_task_id, presence: true, if: :cron?
  validate  :issue_number_blank_for_cron, if: :cron?
  validate  :issue_number_blank_for_direct, if: :direct?
  validate  :epic_belongs_to_same_user_and_repository
  before_validation :default_agent_provider, on: :create
  before_validation :default_credential_mode, on: :create
  before_validation :default_lifecycle_metadata, on: :create
  before_validation :defer_stale_closed_epic_assignment

  enum :validity, VALIDITIES.index_with(&:itself), prefix: true, validate: true
  enum :triaging_reason, TRIAGING_REASONS.index_with(&:itself), prefix: true, validate: true
  enum :stack_base, STACK_BASES.index_with(&:itself), prefix: true, validate: true
  enum :approved_via, APPROVAL_VIAS.index_with(&:itself), prefix: true, validate: { allow_nil: true }

  scope :open_threads, -> { where.not(state: "closed") }
  scope :closed_threads, -> { where(state: "closed") }
  scope :landing_queue, -> { where(state: %w[ approved landing ]) }
  scope :issue_kind, -> { where(kind: "issue") }
  scope :cron_kind,  -> { where(kind: "cron") }
  scope :direct_kind, -> { where(kind: "direct") }
  scope :with_pr, -> { where("pr_number IS NOT NULL OR external_pr_number IS NOT NULL") }
  scope :without_pr, -> { where(pr_number: nil, external_pr_number: nil) }
  scope :with_latest_workflow_snapshot, -> {
    joins(<<~SQL.squish)
      LEFT JOIN (
        SELECT
          latest_workflows.id AS latest_workflow_id,
          latest_workflows.job_id AS latest_workflow_job_id,
          latest_workflows.state AS latest_workflow_state,
          latest_workflows.trigger_kind AS latest_workflow_trigger_kind,
          latest_workflows.created_at AS latest_workflow_created_at
        FROM (
          SELECT
            workflows.*,
            ROW_NUMBER() OVER (
              PARTITION BY workflows.job_id
              ORDER BY workflows.created_at DESC, workflows.id DESC
            ) AS rn
          FROM workflows
        ) latest_workflows
        WHERE latest_workflows.rn = 1
      ) latest_workflow_per_job
        ON latest_workflow_per_job.latest_workflow_job_id = jobs.id
    SQL
      .select(
        "jobs.*",
        "latest_workflow_per_job.latest_workflow_id AS latest_workflow_id",
        "COALESCE(latest_workflow_per_job.latest_workflow_state, 'queued') AS latest_workflow_state",
        "latest_workflow_per_job.latest_workflow_trigger_kind AS latest_workflow_trigger_kind",
        "latest_workflow_per_job.latest_workflow_created_at AS latest_workflow_created_at"
      )
  }

  def issue?
    kind == "issue"
  end

  def cron?
    kind == "cron"
  end

  def direct?
    kind == "direct"
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
    end
  end

  # Audited 2026-05-18 (`docs/job-state-audit.md`). The :open,
  # :landing_failed, and :merged states + the :land event were
  # unreachable dead code — removed. If a real need surfaces, re-add
  # with a transition that actually enters the state, not just a
  # `from:` reference.
  aasm column: :state, whiny_transitions: false do
    after_all_transitions :record_state_transition!
    state :triaging, initial: true
    state :blocked_by_epic
    state :queued
    state :running
    state :implemented
    state :failed
    state :approved
    state :landing
    state :closed

    event :advance_after_triage do
      transitions from: :triaging, to: :blocked_by_epic, guard: :blocked_by_epic_before_execution?
      transitions from: :triaging, to: :queued, guard: :ready_for_execution?, after: :create_initial_run_if_needed
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
      transitions from: [ :queued, :running ], to: :implemented
    end

    # Fired by Workflow#fail's after-callback for non-auto_merge
    # workflows. The Job is now waiting on operator decision — Retry
    # to attempt again (failed → queued) or Close.
    event :mark_failed do
      transitions from: :running, to: :failed
    end

    # Retry pathway: the operator clicked Retry on a failed Job.
    # Goes back to :queued so a new workflow can be instantiated.
    event :retry_after_failure do
      transitions from: :failed, to: :queued
    end

    event :approve, before: :assign_approval_metadata do
      transitions from: :implemented, to: :approved
    end

    event :unapprove, after: :clear_approval_metadata do
      transitions from: :approved, to: :implemented
    end

    event :start_landing do
      transitions from: :approved, to: :landing
    end

    # Single after-callback hook on the transition. The previous
    # event-level `after: :refresh_epic_auto_state` was redundant
    # with the after_save callback and just made the wiring harder
    # to read.
    event :close do
      transitions from: [ :triaging, :blocked_by_epic, :queued, :running, :implemented, :failed, :approved, :landing ], to: :closed, after: -> {
        self.finished_at = Time.current
        record_outcome_to_scheduled_task! if cron?
        refresh_epic_auto_state
      }
    end

    event :fail_landing do
      transitions from: :landing, to: :implemented, after: -> {
        self.approved_at = nil
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
        self.triaging_reason ||= "classifier_pending"
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

  after_update_commit :rebase_stack_children_after_merge, if: :saved_change_to_pr_merged_terminal?
  after_update_commit :start_dependent_jobs_after_implementation, if: :saved_change_to_implemented?
  after_update_commit :enqueue_landing_queue_processor, if: :saved_change_needs_landing_queue_processor?
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

  def ready_for_execution?
    validity == "valid" && !blocked_by_epic_before_execution?
  end

  def blocked_by_epic_before_execution?
    return false unless epic
    return false if epic.releases_jobs_for_execution?

    !epic.releases_jobs_for_execution?
  end

  def prepare_skip_reason
    return "repository_configuration" unless repository.effective_prepare_enabled
    return "issue_label" if prepare_skip_reason_override == "issue_label"
    return "issue_label" if skip_prepare?
    return "issue_label" if Workflow.where(job_id: id).any? { |workflow| workflow.artifact("prepare_skipped_reason") == "issue_label" }

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

  def mark_feedback_addressed!(addressed_at)
    return if addressed_at.blank?
    return if last_feedback_addressed_at && last_feedback_addressed_at >= addressed_at

    update!(last_feedback_addressed_at: addressed_at)
  end

  def approve!(*args, **kwargs)
    raise AASM::InvalidTransition.new(self, :approve, :default) unless may_approve?

    approve(*args, **kwargs).tap { save! }
  end

  def unapprove!(*args, **kwargs)
    raise AASM::InvalidTransition.new(self, :unapprove, :default) unless may_unapprove?

    unapprove(*args, **kwargs).tap { save! }
  end

  def record_github_review_approval!(review_url:, approved_at: Time.current)
    mark_implemented! if may_mark_implemented?
    return false unless may_approve?

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

  # The most recently created Run on this thread, regardless of state.
  def current_run
    runs.last
  end

  def latest_workflow
    workflows.last
  end

  def latest_workflow_state
    return self[:latest_workflow_state].presence || "queued" if has_attribute?(:latest_workflow_state)

    latest_workflow&.state || "queued"
  end

  def latest_workflow_trigger_kind
    return self[:latest_workflow_trigger_kind] if has_attribute?(:latest_workflow_trigger_kind)

    latest_workflow&.trigger_kind
  end

  def active_workflow_trigger_kind
    scope = workflows.loaded? ? workflows.select { |workflow| workflow.state.in?(%w[ queued running ]) } : workflows.active
    scope.max_by { |workflow| [ workflow.created_at || Time.at(0), workflow.id || 0 ] }&.trigger_kind
  end

  def latest_workflow_created_at
    value = if has_attribute?(:latest_workflow_created_at)
      self[:latest_workflow_created_at]
    else
      latest_workflow&.created_at
    end
    value.is_a?(String) ? Time.zone.parse(value) : value
  end

  def retry_with_agent_providers
    return [] unless open?
    return [] if any_active_run?
    return [] unless latest_workflow&.retry_as_new_workflow_available?

    configured = user.configured_agent_providers
    return [] unless configured.size > 1

    configured - [ current_run&.agent_provider ]
  end

  def alternate_configured_agent_providers
    user.configured_agent_providers - [ agent_provider ]
  end

  def switch_agent_provider!(provider)
    update!(agent_provider: provider)
  end

  # The very first Run — the one that created the branch and PR.
  def initial_run
    runs.find_by(trigger_kind: "initial")
  end

  def latest_succeeded_run
    runs.where(state: "succeeded").last
  end

  def head_sha
    runs.where.not(head_sha: [ nil, "" ]).order(:created_at).last&.head_sha
  end

  def total_cost_usd
    if runs.loaded?
      runs.sum { |run| run.cost_usd.to_d }
    else
      runs.sum(:cost_usd)
    end
  end

  def display_total_cost_usd
    return nil if billed_runs_count.zero?

    total_cost_usd
  end

  def billed_runs_count
    if runs.loaded?
      runs.count { |run| run.cost_usd.present? }
    else
      runs.where.not(cost_usd: nil).count
    end
  end

  def any_active_run?
    runs.active.exists?
  end

  SUCCESSFUL_CLOSURE_REASONS = %w[
    pr_merged
    external_pr_merged
    pr_approved
    no_changes
  ].freeze

  def dependencies_satisfied?
    return false if epic.present? && !epic.releases_jobs_for_execution?
    return true if dependencies_overridden_at.present?

    dependencies.includes(:depends_on_job).all? do |dependency|
      dependency.dependency_succeeded?
    end
  end

  def unsatisfied_dependencies
    dependencies.includes(depends_on_job: :repository).reject do |dependency|
      dependency.dependency_succeeded?
    end
  end

  def dependency_succeeded?
    # :merged was removed; the merge path now closes the Job with
    # closure_reason "pr_merged". SUCCESSFUL_CLOSURE_REASONS already
    # includes that, so the (closed? && reason in set) branch covers
    # both kinds of successful close.
    closed? && SUCCESSFUL_CLOSURE_REASONS.include?(closure_reason)
  end

  def effective_base_branch
    return repository.default_branch if stack_base_forces_main?

    parent = dependencies.includes(:depends_on_job).map(&:depends_on_job).compact.find do |dependency_job|
      dependency_job.open? &&
        dependency_job.pr_number.present? &&
        dependency_job.branch_name.present? &&
        !dependency_job.dependency_succeeded?
    end

    parent&.branch_name.presence || repository.default_branch
  end

  def stack_ready_for_execution?
    return true if dependencies_overridden_at.present?

    JobStackResolver.new(self).ready?
  end

  def resolve_stack_parent!
    JobStackResolver.new(self).resolve!
  end

  def stack_base_forces_main?
    stack_base_main? && !epic_internal_dependency?
  end

  def force_run_dependencies!(user:)
    update!(
      dependencies_overridden_at: Time.current,
      dependencies_overridden_by_user: user
    )
    log_dependency_override!(user)
    start_pending_workflows_if_dependencies_satisfied!
  end

  def mark_valid_and_queue!
    transaction do
      update!(
        state: closed? ? "triaging" : state,
        closure_reason: nil,
        finished_at: nil,
        validity: "valid",
        invalidation_reason: nil,
        invalidation_evidence: [],
        triaging_reason: "classifier_pending"
      )
    end
    advance_after_triage! if may_advance_after_triage?
  end

  def resolve_pending_epic_ref!(resolved_epic)
    return false unless triaging? && triaging_reason_pending_epic_ref?
    return false unless pending_epic_reference.to_h["github_issue_url"] == resolved_epic.github_issue_url

    update!(
      epic: resolved_epic,
      triaging_reason: "classifier_pending",
      pending_epic_reference: {}
    )
    advance_after_triage! if may_advance_after_triage?
    true
  end

  def closed_epic_reopenable?(closed_epic)
    return false unless closed_epic&.done?
    return false unless closed_epic.done_at

    Time.current - closed_epic.done_at <= user.epic_reopen_window.days
  end

  def start_pending_workflows_if_dependencies_satisfied!
    return false unless stack_ready_for_execution?
    return false unless ready_for_execution?

    workflows.where(state: "queued").find_each do |workflow|
      workflow.association(:job).target = self
      StepDispatcher.start_workflow(workflow)
    end
    true
  end

  def restore_epic_block_if_not_started!
    return false unless queued?
    return false if runs.where(state: %w[running succeeded failed]).exists?

    transaction do
      workflows.where(state: "queued").find_each do |workflow|
        workflow.cancel!
        workflow.save!
      end

      block_by_epic! if may_block_by_epic?
    end
  end

  def pending_auto_merge?
    workflows.where(trigger_kind: "auto_merge").any? do |workflow|
      workflow.artifact("pending_auto_merge") == "waiting_for_parent"
    end
  end

  def log_pending_dependency_warnings!
    return if pending_dependency_warnings.blank?

    run = current_run
    return unless run

    pending_dependency_warnings.each do |warning|
      JobLog.append!(run: run, chunk: warning, kind: "system")
    end
    self.pending_dependency_warnings = []
  end

  def sync_skip_prepare_from_source!
    return skip_prepare? unless issue? && issue_number.present? && (repository.installation&.active? || user.github_token.present?)

    issue = GithubClient.for(repository: repository, user: user).fetch_issue(repository.slug, issue_number)
    names = Workflows.label_names(issue.labels)
    skip = names.include?(Workflows::SKIP_PREPARE_LABEL)

    updates = {}
    updates[:skip_prepare] = skip if skip_prepare? != skip
    update!(updates) if updates.any?

    skip
  end

  # Called by RunJob after a non-rebase run fails. Increments the
  # failure counter and auto-closes the job if the configured threshold
  # is reached, preventing further polling from scheduling new runs
  # until an operator reopens it (which also resets the counter).
  def record_run_failure!
    increment!(:failure_count)
    return if closed?
    if failure_count >= AppSetting.max_job_failures
      close_with_reason!("too_many_failures")
    end
  end

  # When a cron Job reaches a terminal state, propagate the outcome
  # to its parent ScheduledTask. Only `too_many_failures` counts as
  # a failure (consumes the consecutive_failure cap that may pause
  # the schedule). The "replaced_by_scheduled_task" reason is just
  # bookkeeping for pile-replace policy and is neither a success nor
  # a failure for the parent.
  def record_outcome_to_scheduled_task!
    return unless scheduled_task
    case closure_reason
    when "too_many_failures"
      scheduled_task.record_failure!
    when "replaced_by_scheduled_task"
      # bookkeeping close; don't move the success/failure counters
    else
      scheduled_task.record_success!
    end
  end

  private

  def saved_change_to_implemented?
    saved_change_to_state? && implemented?
  end

  def start_dependent_jobs_after_implementation
    return if branch_name.blank? || pr_number.blank?

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
  # workflow lays out the implement → summarize → pr_open chain;
  # StepDispatcher.start_workflow creates the first Run. RunJob still
  # auto-enqueues via Run's after_create_commit, so background work
  # waits for the surrounding transaction to commit. Same
  # observable behavior as the v0 single-Run flow, but each
  # phase is now its own attemptable step.
  def create_initial_run
    workflow = Workflows::Initial.instantiate(job: self, agent_provider: agent_provider)
    prompt = direct? ? Prompts::DirectJob.new(prompt: issue_body.to_s).to_s : nil
    StepDispatcher.start_workflow(workflow, prompt: prompt)
  end

  # Auto-create the Job's first workflow when the Job reaches :queued
  # (via advance_after_triage or release_epic_block). Both issue and
  # direct Jobs use this contract — once filed and not blocked by an
  # epic or dependency, a direct Job starts on its own. Cron Jobs are
  # excluded; PollScheduledTasksJob seeds them with a pre-rendered
  # prompt at fire time.
  def create_initial_run_if_needed
    return if cron?
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
    message = "Epic #{closed_epic.display_number} auto-reopened for #{::App::Presentation.job_slug(self)}."
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
    text = "This new issue resembles closed #{closed_epic.display_number}; reopen and attach?"
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
      title: "Planning #{closed_epic.display_number}"
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
          "[JobDependency] job ##{id}: Depends-on: " \
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
        "[JobDependency] resolved pending dep on job ##{dependency.job_id}: " \
        "Depends-on: #{repository.owner}/#{repository.name}##{issue_number} -> job ##{id}"
      )
    rescue ActiveRecord::RecordInvalid => e
      Rails.logger.warn(
        "[JobDependency] failed to resolve pending dep on job ##{dependency.job_id}: #{e.message}"
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

  def default_agent_provider
    self.agent_provider ||= repository&.effective_agent_provider || user&.agent_provider
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

  def assign_approval_metadata(*args)
    options = args.last.is_a?(Hash) ? args.last : {}
    self.approved_at = options[:at] || Time.current
    self.approved_via = options.fetch(:via)
    self.approved_by_user = options[:by_user]
    self.approval_evidence = options[:evidence].presence || {}
  end

  def clear_approval_metadata
    self.approved_at = nil
    self.approved_via = nil
    self.approved_by_user = nil
    self.approval_evidence = {}
  end

  def epic_belongs_to_same_user_and_repository
    return unless epic

    errors.add(:epic, "must belong to the same user") if epic.user_id != user_id
    errors.add(:epic, "must belong to the same repository") if epic.repository_id != repository_id
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

  def saved_change_to_pr_merged_terminal?
    saved_change_to_state? && closed? && closure_reason == "pr_merged"
  end

  def saved_change_needs_landing_queue_processor?
    return true if saved_change_to_state? && approved?
    return true if saved_change_to_state? && closed? && closure_reason == "pr_merged"

    false
  end

  def enqueue_landing_queue_processor
    LandingQueueProcessorJob.perform_later
  end

  def rebase_stack_children_after_merge
    StackRebaseCoordinator.parent_merged(self)
  end
end
