class TestCase < ApplicationRecord
  STATUSES = %w[passed failed skipped error].freeze

  belongs_to :test_run
  belongs_to :repository

  validates :name, :suite_name, presence: true
  validates :status, presence: true, inclusion: { in: STATUSES }
  validates :duration_ms, numericality: { only_integer: true, greater_than_or_equal_to: 0 }, allow_nil: true

  scope :passed,  -> { where(status: "passed") }
  scope :failed,  -> { where(status: "failed") }
  scope :skipped, -> { where(status: "skipped") }
  scope :errored, -> { where(status: "error") }

  after_commit :index_for_search, on: %i[create update destroy]

  private

  def index_for_search
    IndexTestCaseSearchJob.perform_later(id)
  end
end
