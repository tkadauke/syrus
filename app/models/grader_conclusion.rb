class GraderConclusion < ApplicationRecord
  AGGREGATE_NAME = "__aggregate__".freeze
  STATUSES = %w[ passed failed timed_out cancelled inconclusive skipped ].freeze

  belongs_to :repository
  belongs_to :job, optional: true
  belongs_to :workflow, optional: true
  belongs_to :step, optional: true
  belongs_to :run, optional: true

  validates :commit_sha, :grader_fingerprint, :grader_name, :status, :checked_at, presence: true
  validates :status, inclusion: { in: STATUSES }

  after_initialize :default_metadata, if: :new_record?

  scope :aggregate, -> { where(grader_name: AGGREGATE_NAME) }
  scope :passed, -> { where(status: "passed") }
  scope :failed, -> { where(status: "failed") }
  scope :latest_first, -> { order(checked_at: :desc, created_at: :desc) }

  private

  def default_metadata
    self.metadata ||= {}
  end
end
