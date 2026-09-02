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
    touched_test_identity_ids = []

    TestRun.transaction do
      previous_test_runs = TestRun.where(run: @run, grader_name: @grader_name)
      touched_test_identity_ids.concat(TestCase.where(test_run_id: previous_test_runs.select(:id)).where.not(test_identity_id: nil).distinct.pluck(:test_identity_id))

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

      touched_test_identity_ids.concat(insert_test_cases(test_run))

      test_run
    end

    touched_test_identity_ids.uniq!
    refresh_test_identities(touched_test_identity_ids)
    refresh_runtime_summaries(touched_test_identity_ids)
    refresh_search_index(touched_test_identity_ids)
    test_run
  end

  private

  def refresh_test_identities(test_identity_ids)
    TestIdentity.refresh_many!(test_identity_ids)
  rescue StandardError => e
    log_enrichment_failure("test identity refresh", e)
  end

  def refresh_runtime_summaries(test_identity_ids)
    TestIdentityRuntimeSummary.refresh_many!(test_identity_ids, grader_names: [ @grader_name ])
  rescue StandardError => e
    log_enrichment_failure("runtime summary refresh", e)
  end

  def refresh_search_index(test_identity_ids)
    TestIdentitySearchIndex.upsert_many(TestIdentity.includes(:repository).where(id: test_identity_ids))
  rescue StandardError => e
    log_enrichment_failure("search indexing", e)
  end

  def log_enrichment_failure(stage, error)
    Rails.logger.warn(
      "[TestRunIngester] #{stage} failed for Run #{@run.id} grader #{@grader_name}: #{error.class}: #{error.message}"
    )
  end

  def insert_test_cases(test_run)
    now = Time.current
    touched_identity_ids = []

    @parsed_run.cases.each_slice(500) do |slice|
      identities = TestIdentity.ensure_for_cases!(repository: @repository, cases: slice)
      rows = slice.map do |c|
        fingerprint = TestIdentity.fingerprint_for(suite_name: c.suite_name, name: c.name)
        test_identity = identities.fetch(fingerprint)
        touched_identity_ids << test_identity.id

        {
          test_run_id: test_run.id,
          repository_id: @repository.id,
          test_identity_id: test_identity.id,
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

    touched_identity_ids
  end
end
