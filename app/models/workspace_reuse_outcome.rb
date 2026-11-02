class WorkspaceReuseOutcome < ApplicationRecord
  KINDS = %w[prepare grader_fanout].freeze

  belongs_to :repository
  belongs_to :workflow
  belongs_to :step
  belongs_to :run

  validates :kind, inclusion: { in: KINDS }
  validates :outcome, :backend, :occurred_at, presence: true

  scope :prunable, ->(cutoff) { where(occurred_at: ...cutoff) }
end
