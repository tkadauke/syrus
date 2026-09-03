module TestInsights
  class TestRun < ApplicationRecord
    self.table_name = "test_insight_runs"

    belongs_to :run
    belongs_to :repository

    scope :for_run, ->(run) { where(run_id: run.is_a?(::Run) ? run.id : run) }

    # Core no longer declares `Run has_many :test_runs`, so a query cannot
    # traverse Job -> workflows -> steps -> runs -> test_runs downward. It can
    # always traverse upward, though: this plugin owns `belongs_to :run` and
    # core owns the rest of the chain.
    scope :for_job, ->(job) {
      joins(run: { step: :workflow }).where(workflows: { job_id: job.is_a?(::Job) ? job.id : job })
    }

    def self.workflow_ids_for_job(job)
      for_job(job).distinct.pluck(Arel.sql("workflows.id"))
    end

    has_many :test_cases, class_name: "TestInsights::TestCase", dependent: :destroy

    validates :grader_name, presence: true
    validates :total_count, :passed_count, :failed_count, :skipped_count, :error_count,
              numericality: { only_integer: true, greater_than_or_equal_to: 0 }
    validates :duration_ms, numericality: { only_integer: true, greater_than_or_equal_to: 0 }, allow_nil: true
    validates :grader_name, length: { maximum: 128 }
  end
end
