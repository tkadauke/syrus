class AutoRetryAttempt < ApplicationRecord
  RETRY_KINDS = %w[ failed_step resume_failed_step retry_workflow ].freeze

  belongs_to :job
  belongs_to :workflow
  belongs_to :run, optional: true

  validates :agent_provider, presence: true, inclusion: { in: User::AGENT_PROVIDERS }
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
end
