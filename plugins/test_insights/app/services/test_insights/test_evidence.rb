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

    def self.failed_test_cases(run:, grader_name:)
      return [] if run.nil?

      TestCase.joins(:test_run)
              .where(test_insight_runs: { run_id: run.id, grader_name: grader_name }, status: FAILURE_STATUSES)
              .select(:suite_name, :name, :file_path)
              .map do |test_case|
                {
                  "suite_name" => test_case.suite_name,
                  "name" => test_case.name,
                  "file_path" => test_case.file_path,
                  "identity" => [ test_case.suite_name, test_case.name ].join(0.chr)
                }
              end
              .uniq
              .sort_by { |test_case| test_case.fetch("identity") }
    end

    # Backs Adjudicators::KnownFlakyFailure. Delegates entirely to
    # TestCase.flakiness_score, which already excludes a workflow's own
    # in-loop retry_until repair failures (`.scored`) -- this must not
    # reimplement that filtering.
    def self.flakiness_score(repository:, suite_name:, name:)
      return nil if repository.nil? || suite_name.blank? || name.blank?

      TestCase.flakiness_score(repository: repository, suite_name: suite_name, name: name)
    end

    # Backs Adjudicators::IsolatedReproDismissal. Writes into
    # test_insight_isolated_repro_attempts, an entirely separate table from
    # test_insight_cases -- deliberately: TestCase.flakiness_score's `scored`
    # pool must never be diluted by a deliberate single-example repro
    # attempt, which is a different kind of evidence than a grader execution.
    # A plain writer: IsolatedReproRecorder (core) has already validated the
    # SHA and the failing-test match before calling this.
    def self.record_isolated_repro!(repository:, grader_name:, suite_name:, name:, sha:, reproduced:, command:, output:,
                                     exit_status: nil, job: nil, workflow: nil, run: nil)
      IsolatedReproAttempt.create!(
        repository: repository,
        job_id: job&.id,
        workflow_id: workflow&.id,
        run_id: run&.id,
        grader_name: grader_name.to_s,
        suite_name: TestCase.truncate_string_column(suite_name),
        name: TestCase.truncate_string_column(name),
        sha: sha.to_s,
        reproduced: !!reproduced,
        command: IsolatedReproAttempt.truncate_command(command),
        output: IsolatedReproAttempt.truncate_output(output),
        exit_status: exit_status
      )
      nil
    end

    # Returns nil when no isolated repro record exists for this exact
    # (suite_name, name, sha) -- "cannot tell," not "reproduced." When
    # multiple records exist (e.g. an agent re-ran the repro), the most
    # recent one wins.
    def self.isolated_repro_evidence(repository:, suite_name:, name:, sha:)
      return nil if repository.nil? || suite_name.blank? || name.blank? || sha.blank?

      record = IsolatedReproAttempt.for_lookup(repository: repository, suite_name: suite_name, name: name, sha: sha)
                                    .order(created_at: :desc, id: :desc)
                                    .first
      return nil unless record

      {
        reproduced: record.reproduced,
        recorded_at: record.created_at,
        command: record.command,
        grader_name: record.grader_name
      }
    end
  end
end
