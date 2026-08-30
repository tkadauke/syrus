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
      @job.workflows
        .joins(steps: { runs: :test_runs })
        .reorder(created_at: :desc, id: :desc)
        .first
    end

    def test_runs_for_workflow(workflow)
      TestRun.joins(run: { step: :workflow })
        .where(workflows: { id: workflow.id })
        .then { |scope| apply_grader_filter(scope) }
        .includes(:test_cases, run: { step: :workflow })
        .order(:grader_name, :id)
        .to_a
    end

    def test_runs_for_run(run)
      run.test_runs
        .then { |scope| apply_grader_filter(scope) }
        .includes(:test_cases, run: { step: :workflow })
        .order(:grader_name, :id)
        .to_a
    end

    def apply_grader_filter(scope)
      return scope unless @grader_name

      scope.where(grader_name: @grader_name)
    end

    def payload_for(test_runs, job:, workflow:, run: nil)
      all_cases = test_runs.flat_map(&:test_cases)
      flakiness_by_pair = TestCase.batch_flakiness(job.repository, all_cases)

      {
        job_id: job.id,
        job_slug: job.slug,
        workflow_id: workflow&.id,
        run_id: run&.id,
        grader_name: @grader_name,
        test_runs: test_runs.map { |test_run| test_run_payload(test_run, flakiness_by_pair) },
        truncation: truncation_payload(test_runs)
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

    def test_run_payload(test_run, flakiness_by_pair)
      cases = ordered_cases(test_run)
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
        failed_error_case_count: failing_cases.size,
        failed_error_cases_omitted: omitted_count(failing_cases.size)
      }

      if @include_slow_cases
        payload[:slow_cases] = slow_cases.first(@case_limit).map { |test_case| test_case_payload(test_case, flakiness_by_pair, include_failure: false) }
        payload[:slow_case_count] = slow_cases.size
        payload[:slow_cases_omitted] = omitted_count(slow_cases.size)
      end

      payload[:suites] = suite_payloads(cases, flakiness_by_pair) if @include_suites
      payload
    end

    def ordered_cases(test_run)
      test_run.test_cases.sort_by { |test_case| [ test_case.suite_name, test_case.name, test_case.id ] }
    end

    def suite_payloads(cases, flakiness_by_pair)
      cases.group_by(&:suite_name).sort_by { |suite_name, _cases| suite_name.to_s }.map do |suite_name, suite_cases|
        {
          suite_name: suite_name,
          total_count: suite_cases.size,
          passed_count: suite_cases.count { |test_case| test_case.status == "passed" },
          failed_count: suite_cases.count { |test_case| test_case.status == "failed" },
          skipped_count: suite_cases.count { |test_case| test_case.status == "skipped" },
          error_count: suite_cases.count { |test_case| test_case.status == "error" },
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
          failure_message: test_case.failure_message,
          failure_backtrace: test_case.failure_backtrace,
          output: test_case.output,
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

    def truncation_payload(test_runs)
      failed_error_returned = 0
      failed_error_omitted = 0
      slow_returned = 0
      slow_omitted = 0

      test_runs.each do |test_run|
        cases = test_run.test_cases.to_a
        failed_error_count = cases.count { |test_case| test_case.status.in?(%w[failed error]) }
        slow_count = cases.count { |test_case| test_case.duration_ms.present? }

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
        slow_cases_omitted: @include_slow_cases ? slow_omitted : slow_returned + slow_omitted,
        suites_included: @include_suites
      }
    end

    def returned_count(total) = [ total, @case_limit ].min
    def omitted_count(total) = [ total - @case_limit, 0 ].max

    def truncate(text)
      return nil if text.blank?

      Mcp::Tools.truncate_text(Mcp::Tools.utf8(text), FAILURE_SNIPPET_BYTES)
    end

    def clamp_case_limit(value)
      parsed = Integer(value, exception: false)
      parsed = DEFAULT_CASE_LIMIT unless parsed&.positive?
      parsed.clamp(1, MAX_CASE_LIMIT)
    end
  end
end
