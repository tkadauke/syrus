class Job < ApplicationRecord
  include AASM

  KINDS = %w[ issue cron adhoc ].freeze
  CREDENTIAL_MODES = %w[ app pat ].freeze
  PREPARE_SKIP_LABEL = "syrus-skip-prepare".freeze
  OPERATOR_CHAT_OPT_OUT_LABEL = "syrus-no-chat".freeze

  PRIORITIES = %w[ high medium low ].freeze
  # Maps priority label → SolidQueue priority integer. SolidQueue dispatches
  # lower numbers first, so high-priority jobs (0) run before medium (10) and
  # low (20). The gap of 10 between levels leaves room for future additions
  # without renumbering existing entries.
  PRIORITY_TO_SQ = { "high" => 0, "medium" => 10, "low" => 20 }.freeze
  attr_accessor :prepare_skip_reason_override, :pending_dependency_warnings

  belongs_to :user
  belongs_to :repository
  belongs_to :scheduled_task, optional: true
  belongs_to :dependencies_overridden_by_user, class_name: "User", optional: true
  has_many :workflows, -> { order(:created_at) }, dependent: :destroy
  # Runs hang off Steps now (Job → Workflow → Step → Run) — Job's
  # direct has_many :runs is a convenience accessor, NOT a cascade
  # parent. Cascade flows through workflows. Runs all carry job_id
  # for the existing Run.belongs_to :job association used widely
  # in views and queries.
  has_many :runs, -> { order(:created_at) }
  has_many :job_logs, through: :runs
  has_many :job_attachments, dependent: :destroy
  has_many :operator_questions, dependent: :destroy
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

  validates :kind, presence: true, inclusion: { in: KINDS }
  validates :credential_mode, presence: true, inclusion: { in: CREDENTIAL_MODES }
  validates :priority, presence: true, inclusion: { in: PRIORITIES }
  validates :agent_provider, presence: true, inclusion: { in: User::AGENT_PROVIDERS }
  validates :issue_number,
            presence: true,
            numericality: { only_integer: true, greater_than: 0 },
            if: :issue?
  validates :scheduled_task_id, presence: true, if: :cron?
  validate  :issue_number_blank_for_cron, if: :cron?
  validate  :issue_number_blank_for_adhoc, if: :adhoc?
  before_validation :default_agent_provider, on: :create
  before_validation :default_credential_mode, on: :create

  scope :open_threads, -> { where(state: "open") }
  scope :closed_threads, -> { where(state: "closed") }
  scope :issue_kind, -> { where(kind: "issue") }
  scope :cron_kind,  -> { where(kind: "cron") }
  scope :adhoc_kind, -> { where(kind: "adhoc") }
  scope :with_pr, -> { where("pr_number IS NOT NULL OR external_pr_number IS NOT NULL") }
  scope :without_pr, -> { where(pr_number: nil, external_pr_number: nil) }

  def issue?
    kind == "issue"
  end

  def cron?
    kind == "cron"
  end

  def adhoc?
    kind == "adhoc"
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
    elsif adhoc?
      Struct.new(:title, :body).new(issue_title.to_s, issue_body.to_s)
    end
  end

  aasm column: :state, whiny_transitions: false do
    state :open, initial: true
    state :closed

    event :close do
      transitions from: :open, to: :closed, after: -> {
        self.finished_at = Time.current
        record_outcome_to_scheduled_task! if cron?
      }
    end

    # Undoes a close. Clears closure_reason + finished_at so the thread
    # looks alive again. Doesn't un-cancel any cancelled Runs (those
    # invocations really did stop) — the user follows up with
    # "Retry" to spawn a fresh Run if they want.
    # Polling resumes automatically once the Job is open again.
    event :reopen do
      transitions from: :closed, to: :open, after: -> {
        self.closure_reason = nil
        self.finished_at = nil
        self.failure_count = 0
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
  after_create :create_initial_run, if: -> { open? && issue? }

  # Trigger a Turbo morph-refresh on the Job's show page on any change.
  # Combined with turbo_refreshes_with method: :morph in the layout,
  # this re-renders the page server-side and patches in only the changed
  # bits (state pill, closure_reason, branch_name, pr_number, etc.)
  # without disturbing user scroll or the live transcript (marked
  # data-turbo-permanent on the show page).
  broadcasts_refreshes
  # And a parallel broadcast on the user's "jobs" stream so the
  # dashboard (which lists every Job for the current user) morphs on
  # any change too — new Jobs appear, state pills move, run counts
  # tick up — all without a manual reload.
  broadcasts_refreshes_to ->(job) { [ job.user, "jobs" ] }
  # Same idea for the per-Repository show page — the jobs table
  # there should pick up newly-polled Jobs (and state changes on
  # existing ones) without a manual refresh.
  broadcasts_refreshes_to ->(job) { [ job.repository, "jobs" ] }

  def solid_queue_priority
    PRIORITY_TO_SQ.fetch(priority.to_s, PRIORITY_TO_SQ["medium"])
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

  def mark_feedback_addressed!(addressed_at)
    return if addressed_at.blank?
    return if last_feedback_addressed_at && last_feedback_addressed_at >= addressed_at

    update!(last_feedback_addressed_at: addressed_at)
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

  def total_cost_usd
    if runs.loaded?
      runs.sum { |run| run.cost_usd.to_d }
    else
      runs.sum(:cost_usd)
    end
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
    return true if dependencies_overridden_at.present?

    dependencies.includes(:depends_on_job).all? do |dependency|
      # Pending (unresolved) deps are always treated as unsatisfied —
      # we don't know yet whether the referenced issue's Job will
      # succeed, so we have to assume it won't.
      next false if dependency.pending?
      dependency.depends_on_job.dependency_succeeded?
    end
  end

  def unsatisfied_dependencies
    dependencies.includes(depends_on_job: :repository).reject do |dependency|
      dependency.resolved? && dependency.depends_on_job.dependency_succeeded?
    end
  end

  def dependency_succeeded?
    closed? && SUCCESSFUL_CLOSURE_REASONS.include?(closure_reason)
  end

  def force_run_dependencies!(user:)
    update!(
      dependencies_overridden_at: Time.current,
      dependencies_overridden_by_user: user
    )
    log_dependency_override!(user)
    start_pending_workflows_if_dependencies_satisfied!
  end

  def start_pending_workflows_if_dependencies_satisfied!
    return false unless dependencies_satisfied?

    workflows.where(state: "queued").find_each do |workflow|
      StepDispatcher.start_workflow(workflow)
    end
    true
  end

  def log_pending_dependency_warnings!
    return if pending_dependency_warnings.blank?

    run = current_run
    return unless run

    next_sequence = (run.job_logs.maximum(:sequence) || -1) + 1
    pending_dependency_warnings.each do |warning|
      run.job_logs.create!(chunk: warning, sequence: next_sequence, kind: "system")
      next_sequence += 1
    end
    self.pending_dependency_warnings = []
  end

  def sync_skip_prepare_from_source!
    return skip_prepare? unless issue? && issue_number.present? && (repository.installation&.active? || user.github_token.present?)

    issue = GithubClient.for(repository: repository, user: user).fetch_issue(repository.slug, issue_number)
    names = Workflows.label_names(issue.labels)
    skip = names.include?(Workflows::SKIP_PREPARE_LABEL)
    no_chat = names.include?(OPERATOR_CHAT_OPT_OUT_LABEL)

    updates = {}
    updates[:skip_prepare] = skip if skip_prepare? != skip
    updates[:operator_chat_disabled] = no_chat if operator_chat_disabled? != no_chat
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

  # Issue Jobs auto-instantiate Workflows::Initial on create. The
  # workflow lays out the implement → summarize → pr_open chain;
  # StepDispatcher.start_workflow creates the first Run. RunJob still
  # auto-enqueues via Run's after_create_commit, so background work
  # waits for the surrounding transaction to commit. Same
  # observable behavior as the v0 single-Run flow, but each
  # phase is now its own attemptable step.
  def create_initial_run
    workflow = Workflows::Initial.instantiate(job: self)
    StepDispatcher.start_workflow(workflow)
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

    run.job_logs.create!(
      chunk: "dependencies: #{user.email_address} overrode unsatisfied dependencies",
      sequence: (run.job_logs.maximum(:sequence) || -1) + 1,
      kind: "system"
    )
  end

  def default_agent_provider
    self.agent_provider ||= repository&.effective_agent_provider || user&.agent_provider
  end

  def default_credential_mode
    self.credential_mode = repository&.credential_mode || "pat"
  end

  def issue_number_blank_for_cron
    errors.add(:issue_number, "must be blank for cron Jobs") if issue_number.present?
  end

  def issue_number_blank_for_adhoc
    errors.add(:issue_number, "must be blank for ad hoc Jobs") if issue_number.present?
  end
end
