class AutoRetryAttempt < ApplicationRecord
  RETRY_KINDS = %w[ failed_step resume_failed_step retry_workflow ].freeze

  WORKER_DIED_CLASSIFICATION = "worker_died"
  MAX_ATTEMPTS = 3
  MAX_WORKER_DIED_ATTEMPTS = 20
  BACKOFFS = [ 5.minutes, 20.minutes, 1.hour ].freeze

  belongs_to :job
  belongs_to :workflow
  belongs_to :run, optional: true

  validates :agent_provider, presence: true, inclusion: { in: -> { User.agent_providers } }
  validates :failure_classification, presence: true
  validates :retry_kind, presence: true, inclusion: { in: RETRY_KINDS }
  validates :attempt_number, presence: true, numericality: { only_integer: true, greater_than: 0 }
  validates :scheduled_at, presence: true

  scope :budget_scope_for, ->(job:, agent_provider:, failure_classification:) {
    where(
      job: job,
      agent_provider: agent_provider,
      failure_classification: failure_classification
    ).where(skipped_reason: nil)
  }

  # Not yet performed and not skipped — a retry that is still going to happen.
  scope :pending, -> { where(performed_at: nil, skipped_reason: nil) }
  scope :pending_in_schedule_order, -> { pending.order(:scheduled_at, :id) }

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

  def superseded_by_successful_workflow?
    return false unless job && workflow

    cutoff = workflow.finished_at || workflow.created_at
    return false unless cutoff

    job.workflows
       .where(state: "succeeded")
       .where("created_at > ? OR (created_at = ? AND id > ?)", cutoff, cutoff, workflow.id)
       .exists?
  end
end
