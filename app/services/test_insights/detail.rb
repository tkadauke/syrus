module TestInsights
  class Detail
    include Rails.application.routes.url_helpers

    DEFAULT_HISTORY_LIMIT = 25
    MAX_HISTORY_LIMIT = 100
    FAILURE_SNIPPET_BYTES = 2.kilobytes

    class << self
      def call(...) = new(...).call
    end

    def initialize(user:, test_identity_id:, history_limit: nil, include_failures: true)
      @user = user
      @test_identity_id = test_identity_id
      @history_limit = clamp_history_limit(history_limit)
      @include_failures = include_failures != false
    end

    def call
      identity = TestIdentity.includes(:repository).find(@test_identity_id)
      repository = accessible_scope.find(identity.repository_id)
      history_cases = identity.test_cases
        .includes(test_run: { run: :job })
        .order(created_at: :desc, id: :desc)
        .limit(@history_limit)
        .to_a

      {
        repository: repository_payload(repository),
        test: test_identity_payload(identity),
        history_limit: @history_limit,
        history: history_cases.map { |test_case| history_payload(test_case) },
        duration_points: duration_points(identity),
        related: related_payload(history_cases)
      }
    end

    private

    def accessible_scope
      @user.admin? ? Repository.all : Repository.accessible_to(@user)
    end

    def clamp_history_limit(value)
      parsed = Integer(value, exception: false)
      parsed = DEFAULT_HISTORY_LIMIT unless parsed&.positive?
      parsed.clamp(1, MAX_HISTORY_LIMIT)
    end

    def repository_payload(repository)
      {
        id: repository.id,
        slug: repository.slug,
        github_url: "https://github.com/#{repository.slug}"
      }
    end

    def test_identity_payload(identity)
      stats = identity.recent_stats(lookback: @history_limit)

      {
        id: identity.id,
        type: "TestIdentity",
        suite_name: identity.suite_name,
        name: identity.name,
        file_path: identity.file_path,
        fingerprint: identity.fingerprint,
        last_status: identity.last_status,
        last_seen_at: iso8601(identity.last_seen_at),
        last_failed_at: iso8601(identity.last_failed_at),
        last_passed_at: iso8601(identity.last_passed_at),
        last_duration_ms: identity.last_duration_ms,
        recent_failure_count: stats.fetch(:failed_count),
        recent_pass_count: stats.fetch(:passed_count),
        recent_total_count: stats.fetch(:total_count),
        failure_rate: stats.fetch(:failure_rate).round(4),
        avg_duration_ms: stats.fetch(:avg_duration_ms),
        reasons: identity.interesting_reasons(stats: stats),
        links: {
          app_path: repository_path(identity.repository, tab: "tests", test_id: identity.id)
        }
      }
    end

    def history_payload(test_case)
      test_run = test_case.test_run
      run = test_run.run
      job = run.job
      payload = {
        test_case: {
          id: test_case.id,
          type: "TestCase",
          status: test_case.status,
          duration_ms: test_case.duration_ms,
          created_at: iso8601(test_case.created_at)
        },
        test_run: {
          id: test_run.id,
          type: "TestRun",
          grader_name: test_run.grader_name,
          total_count: test_run.total_count,
          passed_count: test_run.passed_count,
          failed_count: test_run.failed_count,
          skipped_count: test_run.skipped_count,
          error_count: test_run.error_count,
          duration_ms: test_run.duration_ms
        },
        run: {
          id: run.id,
          type: "Run",
          slug: "RUN-#{run.id}",
          path: "#{job_path(job, tab: "workflows")}#run-#{run.id}"
        },
        job: {
          id: job.id,
          type: "Job",
          slug: job.slug,
          title: job.issue_title,
          path: job_path(job)
        }
      }

      payload[:failure] = failure_payload(test_case) if @include_failures && test_case.status.in?(%w[failed error])
      payload
    end

    def duration_points(identity)
      identity.test_cases
        .where.not(duration_ms: nil)
        .order(created_at: :desc, id: :desc)
        .limit(TestIdentity::HISTORY_LIMIT)
        .pluck(:id, :created_at, :duration_ms, :status)
        .reverse
        .map do |id, created_at, duration_ms, status|
          {
            test_case_id: id,
            created_at: iso8601(created_at),
            duration_ms: duration_ms,
            status: status
          }
        end
    end

    def related_payload(history_cases)
      {
        grader_names: history_cases.map { |test_case| test_case.test_run.grader_name }.uniq,
        run_refs: history_cases.map { |test_case| "RUN-#{test_case.test_run.run_id}" }.uniq,
        job_refs: history_cases.map { |test_case| test_case.test_run.run.job.slug }.uniq
      }
    end

    def failure_payload(test_case)
      {
        message: truncate(test_case.failure_message),
        backtrace: truncate(test_case.failure_backtrace),
        output: truncate(test_case.output)
      }.compact
    end

    def truncate(text)
      return nil if text.blank?

      Mcp::Tools.truncate_text(Mcp::Tools.utf8(text), FAILURE_SNIPPET_BYTES)
    end

    def iso8601(value)
      value.respond_to?(:iso8601) ? value.iso8601 : value&.to_s
    end
  end
end
