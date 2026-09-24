# Persists a JunitXmlParser::ParsedRun as TestRun + TestCase records.
# Idempotent: an existing TestRun for the same run+grader_name is replaced.
module TestInsights
  class Ingester
    def initialize(run:, grader_name:, parsed_run:)
      @run         = run
      @grader_name = grader_name
      @parsed_run  = parsed_run
      @repository  = run.job.repository
    end

    def ingest!
      test_run = nil
      touched_test_identity_ids = []
      heartbeat!

      TestRun.transaction do
        heartbeat!
        previous_test_runs = TestRun.where(run: @run, grader_name: @grader_name)
        touched_test_identity_ids.concat(TestCase.where(test_run_id: previous_test_runs.select(:id)).where.not(test_identity_id: nil).distinct.pluck(:test_identity_id))

        previous_test_run_ids = previous_test_runs.pluck(:id)
        TestCase.where(test_run_id: previous_test_run_ids).delete_all if previous_test_run_ids.present?
        previous_test_runs.delete_all

        heartbeat!
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
        heartbeat!

        test_run
      end

      touched_test_identity_ids.uniq!
      heartbeat!
      mark_wip_repair_failures(test_run)
      heartbeat!
      refresh_test_identities(touched_test_identity_ids)
      heartbeat!
      refresh_runtime_summaries(touched_test_identity_ids)
      heartbeat!
      refresh_search_index(touched_test_identity_ids)
      heartbeat!
      test_run
    end

    private

    # Retroactively excludes earlier failing cases in this run's grader retry
    # loop from the scored pool now that this iteration passed them. See
    # TestInsights::WipRepairFailureClassifier for why this replaced a
    # correlated read-time query.
    def mark_wip_repair_failures(test_run)
      WipRepairFailureClassifier.mark_superseded!(test_run: test_run, step: @run.step)
    rescue StandardError => e
      log_enrichment_failure("wip repair failure classification", e)
    end

    def refresh_test_identities(test_identity_ids)
      TestIdentity.refresh_many!(test_identity_ids)
    rescue StandardError => e
      log_enrichment_failure("test identity refresh", e)
    end

    def refresh_runtime_summaries(test_identity_ids)
      return if test_identity_ids.empty?

      RefreshTestRuntimeSummariesJob.perform_later(test_identity_ids, @grader_name)
    rescue StandardError => e
      log_enrichment_failure("runtime summary refresh enqueue", e)
    end

    # Enqueued rather than written here: ingestion runs inside a grader step on
    # the `runs` queue, which on a split deployment is a compute node with no
    # access to the search database.
    def refresh_search_index(test_identity_ids)
      return if test_identity_ids.empty?

      IndexTestIdentitiesJob.perform_later(test_identity_ids)
    rescue StandardError => e
      log_enrichment_failure("search indexing", e)
    end

    def log_enrichment_failure(stage, error)
      Rails.logger.warn(
        "[TestInsights::Ingester] #{stage} failed for Run #{@run.id} grader #{@grader_name}: #{error.class}: #{error.message}"
      )
    end

    def insert_test_cases(test_run)
      now = Time.current
      touched_identity_ids = []

      @parsed_run.cases.each_slice(500) do |slice|
        identities = TestIdentity.ensure_for_cases!(repository: @repository, cases: slice)
        rows = slice.map do |c|
          # Fingerprint on the untruncated suite_name/name so identity keys
          # stay stable regardless of column-width truncation below.
          fingerprint = TestIdentity.fingerprint_for(suite_name: c.suite_name, name: c.name)
          test_identity = identities.fetch(fingerprint)
          touched_identity_ids << test_identity.id

          {
            test_run_id: test_run.id,
            repository_id: @repository.id,
            test_identity_id: test_identity.id,
            name: TestCase.truncate_string_column(c.name),
            suite_name: TestCase.truncate_string_column(c.suite_name),
            file_path: TestCase.truncate_string_column(c.file_path),
            status: c.status,
            duration_ms: c.duration_ms,
            output: c.output,
            failure_message: c.failure_message,
            failure_backtrace: c.failure_backtrace,
            created_at: now,
            updated_at: now
          }
        end

        insert_rows(rows, test_run: test_run)
        heartbeat!
      end

      touched_identity_ids
    end

    # Truncation above should make every row fit its column, but insert_all!
    # batches 500 rows in one statement -- any other unforeseen per-row error
    # (encoding, an unexpectedly nil required column, etc.) would otherwise
    # roll back and silently drop every sibling row in the slice. Fall back to
    # inserting row-by-row so a single bad row is isolated and reported
    # instead of discarding the whole batch.
    def insert_rows(rows, test_run:)
      return if rows.blank?

      TestCase.insert_all!(rows)
    rescue ActiveRecord::ActiveRecordError => e
      report_ingestion_failure(
        "batch insert of #{rows.size} test case(s) failed, retrying row-by-row",
        error: e,
        test_run: test_run
      )
      insert_rows_individually(rows, test_run: test_run)
    end

    def insert_rows_individually(rows, test_run:)
      rows.each do |row|
        TestCase.insert_all!([ row ])
      rescue ActiveRecord::ActiveRecordError => e
        report_ingestion_failure(
          "dropped test case #{row[:suite_name]} #{row[:name]}".strip,
          error: e,
          test_run: test_run
        )
      end
    end

    def report_ingestion_failure(message, error:, test_run:)
      full_message = "[TestInsights::Ingester] #{message} for Run #{@run.id} grader #{@grader_name}: #{error.class}: #{error.message}"
      Rails.logger.error(full_message)
      OperationalLogging.ingest(
        level: "error",
        source: "test_insights_ingester",
        message: full_message,
        context: {
          run_id: @run.id,
          repository_id: @repository.id,
          grader_name: @grader_name,
          test_run_id: test_run&.id
        }
      )
    rescue StandardError
      nil
    end

    def heartbeat!
      RunHeartbeat.touch(@run, force: true)
    rescue StandardError => e
      Rails.logger.warn(
        "[TestInsights::Ingester] heartbeat failed for Run #{@run.id} grader #{@grader_name}: #{e.class}: #{e.message}"
      )
    end
  end
end
