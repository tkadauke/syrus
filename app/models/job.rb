class Job < ApplicationRecord
  include AASM

  KINDS = %w[ issue cron ].freeze

  belongs_to :user
  belongs_to :repository
  belongs_to :scheduled_task, optional: true
  has_many :runs, -> { order(:created_at) }, dependent: :destroy
  has_many :job_logs, through: :runs

  validates :kind, presence: true, inclusion: { in: KINDS }
  validates :issue_number,
            presence: true,
            numericality: { only_integer: true, greater_than: 0 },
            if: :issue?
  validates :scheduled_task_id, presence: true, if: :cron?
  validate  :issue_number_blank_for_cron, if: :cron?

  scope :open_threads, -> { where(state: "open") }
  scope :closed_threads, -> { where(state: "closed") }
  scope :issue_kind, -> { where(kind: "issue") }
  scope :cron_kind,  -> { where(kind: "cron") }
  scope :with_pr, -> { where("pr_number IS NOT NULL OR external_pr_number IS NOT NULL") }
  scope :without_pr, -> { where(pr_number: nil, external_pr_number: nil) }

  def issue?
    kind == "issue"
  end

  def cron?
    kind == "cron"
  end

  # Returns an "issue-shaped" object (responds to #title, #body) for
  # use by prompt classes that historically only knew about GitHub
  # issues. For issue Jobs this is delegated to GithubClient by the
  # caller; for cron Jobs we synthesize one from the parent
  # ScheduledTask so PrFeedback / CiFailure / PrSummarizer prompts
  # don't need to special-case kind.
  def synthetic_issue
    return nil unless cron? && scheduled_task
    Struct.new(:title, :body).new(
      "Scheduled task: #{scheduled_task.name}",
      scheduled_task.prompt.to_s
    )
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
  after_create_commit :create_initial_run, if: -> { open? && issue? }

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

  def close_with_reason!(reason)
    update!(closure_reason: reason)
    close!
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

  # The very first Run — the one that created the branch and PR.
  def initial_run
    runs.find_by(trigger_kind: "initial")
  end

  def latest_succeeded_run
    runs.where(state: "succeeded").last
  end

  def any_active_run?
    runs.active.exists?
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

  def create_initial_run
    runs.create!(trigger_kind: "initial")
  end

  def issue_number_blank_for_cron
    errors.add(:issue_number, "must be blank for cron Jobs") if issue_number.present?
  end
end
