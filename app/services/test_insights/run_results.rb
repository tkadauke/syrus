module TestInsights
  class RunResults
    include Rails.application.routes.url_helpers

    DEFAULT_CASE_LIMIT = 20
    DEFAULT_SLOW_CASE_LIMIT = 10
    SUITE_CASE_LIMIT = 25
    MAX_CASE_LIMIT = 100
    FAILURE_SNIPPET_BYTES = 2.kilobytes

    class << self
      def for_job(...) = new(...).for_job
      def for_run(...) = new(...).for_run
    end

    def initialize(user:, job_id: nil, run_id: nil, repository_id: nil, grader_name: nil, include_slow_cases: false, include_suites: false, case_limit: nil)
      @user = user
      @job_id = job_id
      @run_id = run_id
      @repository_id = repository_id
      @grader_name = grader_name.to_s.strip.presence
      @include_slow_cases = include_slow_cases == true
      @include_suites = include_suites == true
      @case_limit = clamp_case_limit(case_limit)
    end

    def for_job
      job = accessible_jobs.find(@job_id)
      workflow = latest_workflow_with_test_results(job)

      return empty_job_payload(job) unless workflow

      test_runs = test_runs_for_workflow(workflow)
      result_payload(job: job, workflow: workflow, test_runs: test_runs)
    end

    def for_run
      run = accessible_runs.includes(:job, step: :workflow).find(@run_id)
      test_runs = test_runs_for_run(run)

      result_payload(job: run.job, workflow: run.workflow, run: run, test_runs: test_runs)
    end

    private

    def accessible_jobs
      scope = @user.admin? ? Job.all : Job.accessible_to(@user)
      scope = scope.where(repository_id: @repository_id) if @repository_id
      scope
    end

    def accessible_runs
      Run.where(job_id: accessible_jobs.select(:id))
    end

    def latest_workflow_with_test_results(job)
      job.workflows
        .joins(steps: :runs)
        .joins("INNER JOIN test_runs ON test_runs.run_id = runs.id")
        .reorder(created_at: :desc)
        .first
    end

    def test_runs_for_workflow(workflow)
      scope = TestRun.joins(run: { step: :workflow })
        .where(workflows: { id: workflow.id })
        .includes(test_cases: :test_identity, run: { step: :workflow })
        .order(:grader_name, :id)
      scope = scope.where(grader_name: @grader_name) if @grader_name
      scope.to_a
    end

    def test_runs_for_run(run)
      scope = TestRun.where(run: run)
        .includes(test_cases: :test_identity, run: { step: :workflow })
        .order(:grader_name, :id)
      scope = scope.where(grader_name: @grader_name) if @grader_name
      scope.to_a
    end

    def empty_job_payload(job)
      {
        job: job_payload(job),
        workflow: nil,
        run: nil,
        grader_name: @grader_name,
        test_runs: [],
        totals: totals_for([]),
        truncation: truncation_payload(test_runs: 0, selected_cases: 0, omitted_cases: 0)
      }
    end

    def result_payload(job:, workflow:, test_runs:, run: nil)
      selected_cases = selected_cases_for(test_runs)
      flakiness_by_pair = TestCase.batch_flakiness(job.repository, selected_cases)
      test_run_payloads = test_runs.map { |test_run| test_run_payload(test_run, flakiness_by_pair) }

      {
        job: job_payload(job),
        workflow: workflow_payload(workflow),
        run: run && run_payload(run),
        grader_name: @grader_name,
        test_runs: test_run_payloads,
        totals: totals_for(test_runs),
        truncation: truncation_payload(
          test_runs: test_runs.size,
          selected_cases: selected_cases.size,
          omitted_cases: test_runs.sum { |test_run| [ failed_error_cases_for_test_run(test_run).size - selected_case_count(test_run), 0 ].max }
        )
      }
    end

    def test_run_payload(test_run, flakiness_by_pair)
      cases = selected_cases_for_test_run(test_run)
      payload = {
        id: test_run.id,
        type: "TestRun",
        grader_name: test_run.grader_name,
        run_id: test_run.run_id,
        workflow_id: test_run.run.workflow_id,
        job_id: test_run.run.job_id,
        total_count: test_run.total_count,
        passed_count: test_run.passed_count,
        failed_count: test_run.failed_count,
        skipped_count: test_run.skipped_count,
        error_count: test_run.error_count,
        duration_ms: test_run.duration_ms,
        failed_error_cases: cases.map { |test_case| test_case_payload(test_case, flakiness_by_pair) }
      }

      payload[:slow_cases] = slow_cases_payload(test_run, flakiness_by_pair) if @include_slow_cases
      payload[:suites] = suites_payload(test_run, flakiness_by_pair) if @include_suites
      payload
    end

    def selected_cases_for(test_runs)
      (test_runs.flat_map { |test_run| selected_cases_for_test_run(test_run) } +
        (@include_slow_cases ? test_runs.flat_map { |test_run| slow_cases_for_test_run(test_run) } : []) +
        (@include_suites ? test_runs.flat_map(&:test_cases) : [])).uniq
    end

    def selected_cases_for_test_run(test_run)
      failed_error_cases_for_test_run(test_run).first(@case_limit)
    end

    def failed_error_cases_for_test_run(test_run)
      test_run.test_cases
        .select { |test_case| test_case.status.in?(%w[failed error]) }
        .sort_by { |test_case| [ test_case.status == "error" ? 0 : 1, test_case.suite_name, test_case.name, test_case.id ] }
    end

    def selected_case_count(test_run)
      selected_cases_for_test_run(test_run).size
    end

    def slow_cases_for_test_run(test_run)
      test_run.test_cases
        .select { |test_case| test_case.duration_ms.present? }
        .sort_by { |test_case| [ -test_case.duration_ms.to_i, test_case.suite_name, test_case.name, test_case.id ] }
        .first(DEFAULT_SLOW_CASE_LIMIT)
    end

    def slow_cases_payload(test_run, flakiness_by_pair)
      slow_cases_for_test_run(test_run).map { |test_case| test_case_payload(test_case, flakiness_by_pair, include_failure: false) }
    end

    def suites_payload(test_run, flakiness_by_pair)
      test_run.test_cases.group_by(&:suite_name).map do |suite_name, cases|
        selected = cases.first(SUITE_CASE_LIMIT)
        {
          suite_name: suite_name,
          total_count: cases.size,
          passed_count: cases.count { |test_case| test_case.status == "passed" },
          failed_count: cases.count { |test_case| test_case.status == "failed" },
          skipped_count: cases.count { |test_case| test_case.status == "skipped" },
          error_count: cases.count { |test_case| test_case.status == "error" },
          test_cases: selected.map { |test_case| test_case_payload(test_case, flakiness_by_pair, include_failure: test_case.status.in?(%w[failed error])) },
          truncated: selected.size < cases.size,
          omitted_count: [ cases.size - selected.size, 0 ].max
        }
      end
    end

    def test_case_payload(test_case, flakiness_by_pair, include_failure: true)
      flakiness = flakiness_by_pair[[ test_case.suite_name, test_case.name ]]
      payload = {
        id: test_case.id,
        type: "TestCase",
        test_identity_id: test_case.test_identity_id,
        suite_name: test_case.suite_name,
        name: test_case.name,
        file_path: test_case.file_path,
        status: test_case.status,
        duration_ms: test_case.duration_ms,
        flakiness: flakiness_payload(flakiness)
      }
      payload[:failure] = failure_payload(test_case) if include_failure && test_case.status.in?(%w[failed error])
      payload
    end

    def flakiness_payload(flakiness)
      {
        score: flakiness&.dig(:score),
        flaky: flakiness&.dig(:flaky),
        failed_count: flakiness&.dig(:failed_count),
        total_count: flakiness&.dig(:total_count),
        run_statuses: flakiness&.dig(:run_statuses)
      }
    end

    def failure_payload(test_case)
      {
        message: truncate(test_case.failure_message),
        backtrace: truncate(test_case.failure_backtrace),
        output: truncate(test_case.output)
      }.compact
    end

    def totals_for(test_runs)
      {
        total_count: test_runs.sum(&:total_count),
        passed_count: test_runs.sum(&:passed_count),
        failed_count: test_runs.sum(&:failed_count),
        skipped_count: test_runs.sum(&:skipped_count),
        error_count: test_runs.sum(&:error_count),
        duration_ms: test_runs.filter_map(&:duration_ms).sum
      }
    end

    def job_payload(job)
      {
        id: job.id,
        type: "Job",
        slug: job.slug,
        title: job.issue_title,
        repository_id: job.repository_id,
        repository_slug: job.repository&.slug,
        path: job_path(job)
      }
    end

    def workflow_payload(workflow)
      return nil unless workflow

      {
        id: workflow.id,
        type: "Workflow",
        slug: workflow.slug,
        trigger_kind: workflow.trigger_kind,
        state: workflow.state
      }
    end

    def run_payload(run)
      {
        id: run.id,
        type: "Run",
        slug: run.slug,
        state: run.state,
        step_kind: run.step&.kind,
        workflow_id: run.workflow_id,
        job_id: run.job_id,
        path: "#{job_path(run.job, tab: "workflows")}#run-#{run.id}"
      }
    end

    def truncation_payload(test_runs:, selected_cases:, omitted_cases:)
      {
        failed_error_case_limit_per_test_run: @case_limit,
        slow_case_limit_per_test_run: @include_slow_cases ? DEFAULT_SLOW_CASE_LIMIT : 0,
        suite_case_limit_per_suite: @include_suites ? SUITE_CASE_LIMIT : 0,
        test_runs_returned: test_runs,
        selected_cases_returned: selected_cases,
        omitted_failed_error_cases: omitted_cases
      }
    end

    def clamp_case_limit(value)
      parsed = Integer(value, exception: false)
      parsed = DEFAULT_CASE_LIMIT unless parsed&.positive?
      parsed.clamp(1, MAX_CASE_LIMIT)
    end

    def truncate(text)
      return nil if text.blank?

      Mcp::Tools.truncate_text(Mcp::Tools.utf8(text), FAILURE_SNIPPET_BYTES)
    end
  end
end
