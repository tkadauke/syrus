class CommandSpan < ApplicationRecord
  OUTCOMES = %w[ succeeded failed timed_out stopped operator_killed incomplete ].freeze

  belongs_to :job
  belongs_to :workflow
  belongs_to :step
  belongs_to :run
  belongs_to :spawned_process, optional: true

  validates :sequence, numericality: { only_integer: true, greater_than_or_equal_to: 1 }
  validates :name, :command_excerpt, :started_at, presence: true
  validates :outcome, inclusion: { in: OUTCOMES, allow_nil: true }
  validates :sequence, uniqueness: { scope: :run_id }
  before_validation :default_metadata

  scope :ordered, -> { order(:sequence, :id) }

  def duration_s
    return unless duration_ms

    (duration_ms.to_f / 1000).round(3)
  end

  private

  def default_metadata
    self.metadata ||= {}
    self.resource_attribution ||= {}
  end
end
