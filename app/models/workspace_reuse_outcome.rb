class WorkspaceReuseOutcome < ApplicationRecord
  include HasConfigurableRetention

  KINDS = %w[prepare grader_fanout].freeze

  configurable_retention setting_key: :workspace_reuse_outcome_retention_days

  belongs_to :repository
  belongs_to :workflow
  belongs_to :step
  belongs_to :run

  validates :kind, inclusion: { in: KINDS }
  validates :outcome, :backend, :occurred_at, presence: true

  scope :prunable, -> {
    cutoff = retention_cutoff
    cutoff ? where(occurred_at: ...cutoff) : none
  }
end
