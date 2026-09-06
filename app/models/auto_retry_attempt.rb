class AutoRetryAttempt < ApplicationRecord
  RETRY_KINDS = %w[ failed_step resume_failed_step retry_workflow ].freeze

  WORKER_DIED_CLASSIFICATION = "worker_died"
  MAX_ATTEMPTS = 3
  MAX_WORKER_DIED_ATTEMPTS = 20
  BACKOFFS = [ 5.minutes, 20.minutes, 1.hour ].freeze
  # Reasons a skipped attempt should NOT consume the retry budget: each names a
  # condition outside the Job's control that is expected to clear, so charging
  # the Job for it would spend its retries on the weather.
  #
  # Every entry must therefore describe something *transient*. A permanent
  # reason listed here is unbounded recursion: the attempt is skipped, the
  # budget does not advance, the planner sees budget available and plans
  # another. "failure classification changed" used to be here, and
  # `AutoRetryJob#skip_if_failure_no_longer_retryable` wrote a message with that
  # prefix whenever the fresh classification was non-retryable -- whether or not
  # anything had changed. Runs 121870/121914 produced ~460,000 attempts at two
  # per second before anyone noticed. That skip now writes
  # NOT_RETRYABLE_SKIP_PREFIX, which is deliberately absent from this list.
  BUDGET_EXEMPT_SKIPPED_REASON_PREFIXES = [
    "That agent is not available",
    "Claude appears degraded",
    "Codex appears degraded",
    "job is terminal",
    "source workflow was already superseded",
    "failure classification changed",
    "default provider changed"
  ].freeze

  # A failure that is simply not retryable. Counts against the budget, so a
  # planner that keeps proposing retries runs out instead of spinning.
  NOT_RETRYABLE_SKIP_PREFIX = "failure is not retryable".freeze

  belongs_to :job
  belongs_to :workflow
  belongs_to :run, optional: true

  before_validation :assign_retry_workflow_uniqueness_key

  validates :agent_provider, presence: true, inclusion: { in: -> { User.agent_providers } }
  validates :failure_classification, presence: true
  validates :retry_kind, presence: true, inclusion: { in: RETRY_KINDS }
  validates :attempt_number, presence: true, numericality: { only_integer: true, greater_than: 0 }
  validates :scheduled_at, presence: true

  scope :budget_scope_for, ->(job:, agent_provider:, failure_classification:) {
    scope = where(
      job: job,
      agent_provider: agent_provider,
      failure_classification: failure_classification
    )
    exempt_clauses = BUDGET_EXEMPT_SKIPPED_REASON_PREFIXES.map { "skipped_reason NOT LIKE ?" }.join(" AND ")
    exempt_values = BUDGET_EXEMPT_SKIPPED_REASON_PREFIXES.map { |prefix| "#{sanitize_sql_like(prefix)}%" }

    scope.where(skipped_reason: nil).or(scope.where(exempt_clauses, *exempt_values))
  }

  # Not yet performed and not skipped — a retry that is still going to happen.
  scope :pending, -> { where(performed_at: nil, skipped_reason: nil) }
  scope :pending_in_schedule_order, -> { pending.order(:scheduled_at, :id) }
  scope :retry_workflow, -> { where(retry_kind: "retry_workflow") }
  scope :unskipped, -> { where(skipped_reason: nil) }

  def self.retry_workflow_scheduled_for?(workflow)
    where(workflow: workflow).retry_workflow.unskipped.exists?
  end

  def self.prune_stale_pending!(limit: 1_000)
    count = 0

    pending_in_schedule_order
      .includes(:job, :workflow)
      .limit(limit)
      .each do |attempt|
        reason = attempt.stale_pending_reason
        next unless reason

        attempt.skip_stale_pending!(reason)
        count += 1
      end

    count
  end

  def stale_pending_reason
    return "job is terminal" if job&.state.in?(Job::TERMINAL_STATES)
    return "source workflow was already superseded by a successful workflow" if superseded_by_successful_workflow?

    nil
  end

  def skip_stale_pending!(reason)
    update!(skipped_reason: reason)
    WorkUnits::AutoRetryBackoff.clear!(self)
  end

  private

  def assign_retry_workflow_uniqueness_key
    self.retry_workflow_uniqueness_key = retry_kind == "retry_workflow" && skipped_reason.blank? ? "retry_workflow" : nil
  end

  def superseded_by_successful_workflow?
    Workflows::ValidationSupersession.superseded_by_successful_workflow?(workflow)
  end
end
