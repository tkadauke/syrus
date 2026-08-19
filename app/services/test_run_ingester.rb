# Persists a JunitXmlParser::ParsedRun as TestRun + TestCase records.
# Idempotent: an existing TestRun for the same run+grader_name is replaced.
class TestRunIngester
  def initialize(run:, grader_name:, parsed_run:)
    @run         = run
    @grader_name = grader_name
    @parsed_run  = parsed_run
    @repository  = run.job.repository
  end

  def ingest!
    test_run = nil
    stale_test_case_ids = []

    TestRun.transaction do
      previous_test_runs = TestRun.where(run: @run, grader_name: @grader_name)
      stale_test_case_ids = TestCase.where(test_run_id: previous_test_runs.select(:id)).pluck(:id)

      previous_test_run_ids = previous_test_runs.pluck(:id)
      TestCase.where(test_run_id: previous_test_run_ids).delete_all if previous_test_run_ids.present?
      previous_test_runs.delete_all

      test_run = TestRun.create!(
        run: @run,
        repository: @repository,
        grader_name: @grader_name,
        total_count: @parsed_run.total_count,
        passed_count: @parsed_run.passed_count,
        failed_count: @parsed_run.failed_count,
        skipped_count: @parsed_run.skipped_count,
        error_count: @parsed_run.error_count,
        duration_ms: @parsed_run.duration_ms
      )

      insert_test_cases(test_run)

      test_run
    end

    TestCaseSearchIndex.delete_many(stale_test_case_ids)
    IndexTestRunSearchJob.perform_later(test_run.id) if test_run
    test_run
  end

  private

  def insert_test_cases(test_run)
    now = Time.current
    @parsed_run.cases.each_slice(500) do |slice|
      rows = slice.map do |c|
        {
          test_run_id: test_run.id,
          repository_id: @repository.id,
          name: c.name,
          suite_name: c.suite_name,
          file_path: c.file_path,
          status: c.status,
          duration_ms: c.duration_ms,
          output: c.output,
          failure_message: c.failure_message,
          failure_backtrace: c.failure_backtrace,
          created_at: now,
          updated_at: now
        }
      end

      TestCase.insert_all!(rows) if rows.present?
    end
  end
end
