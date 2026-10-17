module TestInsights
  class RunResults
    include Rails.application.routes.url_helpers

    DEFAULT_CASE_LIMIT = 20
    MAX_CASE_LIMIT = 100
    FAILURE_SNIPPET_BYTES = 2.kilobytes

    class << self
      def for_job(...) = new(...).for_job
      def for_run(...) = new(...).for_run
    end

    def initialize(job: nil, run: nil, grader_name: nil, include_slow_cases: false, include_suites: false, case_limit: nil)
      @job = job
      @run = run
      @grader_name = grader_name.to_s.strip.presence
      @include_slow_cases = include_slow_cases == true
      @include_suites = include_suites == true
      @case_limit = clamp_case_limit(case_limit)
    end

    def for_job
      workflow = latest_workflow_with_tests
      return empty_job_payload unless workflow

      test_runs = test_runs_for_workflow(workflow)
      payload_for(test_runs, job: @job, workflow: workflow)
    end

    def for_run
      test_runs = test_runs_for_run(@run)
      payload_for(test_runs, job: @run.job, workflow: @run.workflow, run: @run)
    end

    private

    def latest_workflow_with_tests
      workflow_ids = TestRun.workflow_ids_for_job(@job)
      return nil if workflow_ids.empty?

      @job.workflows.where(id: workflow_ids).reorder(created_at: :desc, id: :desc).first
    end

    def test_runs_for_workflow(workflow)
      TestRun.joins(run: { step: :workflow })
        .where(workflows: { id: workflow.id })
        .then { |scope| apply_grader_filter(scope) }
        .includes(run: { step: :workflow })
        .order(:grader_name, :id)
        .to_a
    end

    def test_runs_for_run(run)
      TestRun.for_run(run)
        .then { |scope| apply_grader_filter(scope) }
        .includes(run: { step: :workflow })
        .order(:grader_name, :id)
        .to_a
    end

    def apply_grader_filter(scope)
      return scope unless @grader_name

      scope.where(grader_name: @grader_name)
    end

    def payload_for(test_runs, job:, workflow:, run: nil)
      cases_by_run = selected_cases_by_run(test_runs)
      slow_counts_by_run = slow_counts_by_run(test_runs)
      suite_counts = suite_counts_for(cases_by_run)
      all_cases = cases_by_run.values.flatten
      flakiness_by_pair = TestCase.batch_flakiness(job.repository, all_cases)

      {
        job_id: job.id,
        job_slug: job.slug,
        workflow_id: workflow&.id,
        run_id: run&.id,
        grader_name: @grader_name,
        test_runs: test_runs.map do |test_run|
          safe_test_run_payload(
            test_run,
            cases_by_run.fetch(test_run.id, []),
            flakiness_by_pair,
            slow_counts_by_run,
            suite_counts
          )
        end,
        truncation: truncation_payload(test_runs, slow_counts_by_run)
      }
    end

    def empty_job_payload
      {
        job_id: @job.id,
        job_slug: @job.slug,
        workflow_id: nil,
        run_id: nil,
        grader_name: @grader_name,
        test_runs: [],
        truncation: {
          case_limit: @case_limit,
          failure_snippet_bytes: FAILURE_SNIPPET_BYTES,
          failed_error_cases_returned: 0,
          failed_error_cases_omitted: 0,
          slow_cases_returned: 0,
          slow_cases_omitted: 0,
          suites_included: @include_suites
        }
      }
    end

    def test_run_payload(test_run, cases, flakiness_by_pair, slow_counts_by_run, suite_counts)
      failing_cases = cases.select { |test_case| test_case.status.in?(%w[failed error]) }
      slow_cases = cases.reject { |test_case| test_case.duration_ms.nil? }
                        .sort_by { |test_case| [ -test_case.duration_ms, test_case.suite_name, test_case.name, test_case.id ] }

      payload = {
        id: test_run.id,
        type: "TestRun",
        grader_name: test_run.grader_name,
        total_count: test_run.total_count,
        passed_count: test_run.passed_count,
        failed_count: test_run.failed_count,
        skipped_count: test_run.skipped_count,
        error_count: test_run.error_count,
        duration_ms: test_run.duration_ms,
        run_id: test_run.run_id,
        workflow_id: test_run.run.workflow_id,
        job_id: test_run.run.job_id,
        failed_error_cases: failing_cases.first(@case_limit).map { |test_case| test_case_payload(test_case, flakiness_by_pair, include_failure: true) },
        failed_error_case_count: test_run.failed_count.to_i + test_run.error_count.to_i,
        failed_error_cases_omitted: omitted_count(test_run.failed_count.to_i + test_run.error_count.to_i)
      }

      if @include_slow_cases
        slow_case_count = slow_counts_by_run.fetch(test_run.id, 0)
        payload[:slow_cases] = slow_cases.first(@case_limit).map { |test_case| test_case_payload(test_case, flakiness_by_pair, include_failure: false) }
        payload[:slow_case_count] = slow_case_count
        payload[:slow_cases_omitted] = omitted_count(slow_case_count)
      end

      payload[:suites] = suite_payloads(test_run, cases, flakiness_by_pair, suite_counts) if @include_suites
      payload
    end

    # A single malformed TestRun must not 500 the whole job/run payload --
    # mirrors Admin::JobStateSerializer's per-record degrade shape.
    def safe_test_run_payload(test_run, cases, flakiness_by_pair, slow_counts_by_run, suite_counts)
      test_run_payload(test_run, cases, flakiness_by_pair, slow_counts_by_run, suite_counts)
    rescue StandardError => e
      Rails.logger.warn("[test_insights/run_results] failed to serialize TestRun##{test_run.id}: #{e.class}: #{e.message}")
      { id: test_run.id, type: "TestRun", grader_name: test_run.grader_name, error_serializing: "#{e.class}: #{e.message}" }
    end

    def selected_cases_by_run(test_runs)
      test_run_ids = test_runs.map(&:id)
      return {} if test_run_ids.empty?

      selected_ids = if @include_suites
        limited_case_ids(
          TestCase.where(test_run_id: test_run_ids),
          "CASE WHEN status IN ('failed', 'error') THEN 0 ELSE 1 END, suite_name, name, id"
        )
      else
        limited_case_ids(TestCase.where(test_run_id: test_run_ids).failure_like, "suite_name, name, id")
      end
      if @include_slow_cases
        selected_ids.concat(
          limited_case_ids(TestCase.where(test_run_id: test_run_ids).where.not(duration_ms: nil), "duration_ms DESC, suite_name, name, id")
        )
      end

      TestCase.where(id: selected_ids.uniq).to_a.group_by(&:test_run_id)
    end

    def limited_case_ids(scope, order_sql)
      ranked = scope.select(
        :id,
        :test_run_id,
        "ROW_NUMBER() OVER (PARTITION BY test_run_id ORDER BY #{order_sql}) AS syrus_run_case_rank"
      )
      TestCase.from(ranked, :test_insight_cases)
        .where("syrus_run_case_rank <= ?", @case_limit)
        .pluck(:id)
    end

    def slow_counts_by_run(test_runs)
      TestCase.where(test_run_id: test_runs.map(&:id)).where.not(duration_ms: nil).group(:test_run_id).count
    end

    def suite_counts_for(cases_by_run)
      return {} unless @include_suites

      table = TestCase.arel_table
      predicate = cases_by_run.filter_map do |test_run_id, cases|
        suite_names = cases.map(&:suite_name).uniq
        table[:test_run_id].eq(test_run_id).and(table[:suite_name].in(suite_names)) if suite_names.any?
      end.reduce { |combined, condition| combined.or(condition) }
      return {} unless predicate

      TestCase.where(predicate).group(:test_run_id, :suite_name, :status).count
    end

    def suite_payloads(test_run, cases, flakiness_by_pair, suite_counts)
      suite_cases = cases.sort_by do |test_case|
        [ test_case.status.in?(%w[failed error]) ? 0 : 1, test_case.suite_name.to_s, test_case.name.to_s, test_case.id ]
      end.first(@case_limit)
      cases_by_suite = suite_cases.group_by(&:suite_name)
      cases_by_suite.sort_by { |suite_name, _cases| suite_name.to_s }.map do |suite_name, suite_cases|
        status_count = ->(status) { suite_counts.fetch([ test_run.id, suite_name, status ], 0) }
        {
          suite_name: suite_name,
          total_count: TestCase::STATUSES.sum { |status| status_count.call(status) },
          passed_count: status_count.call("passed"),
          failed_count: status_count.call("failed"),
          skipped_count: status_count.call("skipped"),
          error_count: status_count.call("error"),
          test_cases: suite_cases.map { |test_case| test_case_payload(test_case, flakiness_by_pair, include_failure: true, legacy_failure_fields: true) }
        }
      end
    end

    def test_case_payload(test_case, flakiness_by_pair, include_failure:, legacy_failure_fields: false)
      fdata = flakiness_by_pair[[ test_case.suite_name, test_case.name ]]
      payload = {
        id: test_case.id,
        type: "TestCase",
        name: test_case.name,
        suite_name: test_case.suite_name,
        file_path: test_case.file_path,
        status: test_case.status,
        duration_ms: test_case.duration_ms,
        test_identity_id: test_case.test_identity_id,
        flakiness: flakiness_payload(fdata)
      }

      if legacy_failure_fields
        payload.merge!(
          failure_message: truncate_legacy(test_case.failure_message),
          failure_backtrace: truncate_legacy(test_case.failure_backtrace),
          output: truncate_legacy(test_case.output),
          flakiness_score: fdata&.dig(:score),
          flakiness_failed_count: fdata&.dig(:failed_count),
          flakiness_total_count: fdata&.dig(:total_count),
          flakiness_run_statuses: fdata&.dig(:run_statuses)
        )
      elsif include_failure && test_case.status.in?(%w[failed error])
        payload[:failure] = failure_payload(test_case)
      end

      payload
    end

    def flakiness_payload(fdata)
      {
        score: fdata&.dig(:score),
        failed_count: fdata&.dig(:failed_count),
        total_count: fdata&.dig(:total_count),
        flaky: fdata&.dig(:flaky),
        run_statuses: fdata&.dig(:run_statuses)
      }
    end

    def failure_payload(test_case)
      {
        message: truncate(test_case.failure_message),
        backtrace: truncate(test_case.failure_backtrace),
        output: truncate(test_case.output)
      }.compact
    end

    def truncation_payload(test_runs, slow_counts_by_run)
      failed_error_returned = 0
      failed_error_omitted = 0
      slow_returned = 0
      slow_omitted = 0

      test_runs.each do |test_run|
        failed_error_count = test_run.failed_count.to_i + test_run.error_count.to_i
        slow_count = slow_counts_by_run.fetch(test_run.id, 0)

        failed_error_returned += returned_count(failed_error_count)
        failed_error_omitted += omitted_count(failed_error_count)
        slow_returned += returned_count(slow_count)
        slow_omitted += omitted_count(slow_count)
      end

      {
        case_limit: @case_limit,
        failure_snippet_bytes: FAILURE_SNIPPET_BYTES,
        failed_error_cases_returned: failed_error_returned,
        failed_error_cases_omitted: failed_error_omitted,
        slow_cases_returned: @include_slow_cases ? slow_returned : 0,
        slow_cases_omitted: @include_slow_cases ? slow_omitted : slow_counts_by_run.values.sum,
        suite_cases_returned: @include_suites ? test_runs.sum { |test_run| returned_count(test_run.total_count.to_i) } : 0,
        suite_cases_omitted: @include_suites ? test_runs.sum { |test_run| omitted_count(test_run.total_count.to_i) } : 0,
        suites_included: @include_suites
      }
    end

    def returned_count(total) = [ total, @case_limit ].min
    def omitted_count(total) = [ total - @case_limit, 0 ].max

    def truncate(text)
      return nil if text.blank?

      Mcp::Tools.truncate_text(Mcp::Tools.utf8(text), FAILURE_SNIPPET_BYTES)
    end

    def truncate_legacy(text)
      truncate(text)&.fetch(:text)
    end

    def clamp_case_limit(value)
      parsed = Integer(value, exception: false)
      parsed = DEFAULT_CASE_LIMIT unless parsed&.positive?
      parsed.clamp(1, MAX_CASE_LIMIT)
    end
  end
end
