class Job < ApplicationRecord
  include AASM

  belongs_to :user
  belongs_to :repository
  has_many :runs, -> { order(:created_at) }, dependent: :destroy
  has_many :job_logs, through: :runs

  validates :issue_number, presence: true, numericality: { only_integer: true, greater_than: 0 }

  scope :open_threads, -> { where(state: "open") }
  scope :closed_threads, -> { where(state: "closed") }
  scope :with_pr, -> { where("pr_number IS NOT NULL OR external_pr_number IS NOT NULL") }
  scope :without_pr, -> { where(pr_number: nil, external_pr_number: nil) }

  aasm column: :state, whiny_transitions: false do
    state :open, initial: true
    state :closed

    event :close do
      transitions from: :open, to: :closed, after: -> { self.finished_at = Time.current }
    end

    # Undoes a close. Clears closure_reason + finished_at so the thread
    # looks alive again. Doesn't un-cancel any cancelled Runs (those
    # invocations really did stop) — the user follows up with
    # "Run again on this branch" to spawn a fresh Run if they want.
    # Polling resumes automatically once the Job is open again.
    event :reopen do
      transitions from: :closed, to: :open, after: -> {
        self.closure_reason = nil
        self.finished_at = nil
        self.failure_count = 0
      }
    end
  end

  # Skip the initial-run autostart for Jobs that are created already
  # closed — that's the "preempted" path, where Syrus discovered an
  # external PR already targeting this issue and recorded the Job for
  # the operator's awareness without scheduling any agent work.
  after_create_commit :create_initial_run, if: :open?

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

  private

  def create_initial_run
    runs.create!(trigger_kind: "initial")
  end
end
