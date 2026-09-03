module TestInsights
  # Supplies per-run test evidence to core's main-branch failure classifier.
  #
  # The classifier distinguishes a grader failure inherited from a broken base
  # branch from one this PR introduced, and does that far more precisely when
  # it can diff failing test identities than when it can only compare pass/fail.
  # It already had a coarser fallback for repositories with no test data, so
  # core degrades to that when this plugin is absent rather than depending on it.
  class TestEvidence
    include Syrus::Plugin::TestEvidence

    FAILURE_STATUSES = %w[failed error].freeze

    def self.test_case_count(run:, grader_name:)
      return 0 if run.nil?

      TestCase.joins(:test_run)
              .where(test_insight_runs: { run_id: run.id, grader_name: grader_name })
              .count
    end

    def self.failed_test_identities(run:, grader_name:)
      return [] if run.nil?

      TestCase.joins(:test_run)
              .where(test_insight_runs: { run_id: run.id, grader_name: grader_name }, status: FAILURE_STATUSES)
              .pluck(:suite_name, :name)
              .map { |suite_name, name| [ suite_name, name ].join(0.chr) }
              .uniq
              .sort
    end
  end
end
