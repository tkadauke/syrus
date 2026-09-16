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

    # Pruned by its own age, independently of TestCase::RETAIN_AFTER, rather
    # than only emptying out as a side effect of its cases being deleted --
    # there's no DB foreign key between the two tables (see db/schema.rb), and
    # a run row is written in the same ingest batch as its cases, so in
    # practice both age out together. Same window as TestCase for that reason.
    RETAIN_AFTER = TestCase::RETAIN_AFTER

    scope :prunable, -> {
      where("created_at < ?", RETAIN_AFTER.ago)
    }

    validates :grader_name, presence: true
    validates :total_count, :passed_count, :failed_count, :skipped_count, :error_count,
              numericality: { only_integer: true, greater_than_or_equal_to: 0 }
    validates :duration_ms, numericality: { only_integer: true, greater_than_or_equal_to: 0 }, allow_nil: true
    validates :grader_name, length: { maximum: 128 }
  end
end
