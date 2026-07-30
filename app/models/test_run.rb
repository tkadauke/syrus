class TestRun < ApplicationRecord
  belongs_to :run
  belongs_to :repository

  has_many :test_cases, dependent: :destroy

  validates :grader_name, presence: true
  validates :total_count, :passed_count, :failed_count, :skipped_count, :error_count,
            numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :duration_ms, numericality: { only_integer: true, greater_than_or_equal_to: 0 }, allow_nil: true
  validates :grader_name, length: { maximum: 128 }
end
