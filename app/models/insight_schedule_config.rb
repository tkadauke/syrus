class InsightScheduleConfig < ApplicationRecord
  belongs_to :repository

  validates :min_jobs_since_last_run, numericality: { only_integer: true, greater_than_or_equal_to: 1 }
  validates :max_jobs_since_last_run, numericality: { only_integer: true, greater_than_or_equal_to: 1 }
  validate :min_less_than_max

  private

  def min_less_than_max
    return unless min_jobs_since_last_run && max_jobs_since_last_run
    return if min_jobs_since_last_run < max_jobs_since_last_run

    errors.add(:min_jobs_since_last_run, "must be less than max_jobs_since_last_run")
  end
end
