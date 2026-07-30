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
    TestRun.transaction do
      TestRun.where(run: @run, grader_name: @grader_name).destroy_all

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

      @parsed_run.cases.each do |c|
        TestCase.create!(
          test_run: test_run,
          repository: @repository,
          name: c.name,
          suite_name: c.suite_name,
          file_path: c.file_path,
          status: c.status,
          duration_ms: c.duration_ms,
          output: c.output,
          failure_message: c.failure_message,
          failure_backtrace: c.failure_backtrace
        )
      end

      test_run
    end
  end
end
