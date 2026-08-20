module Api
  module V1
    module App
      class RepositoryTestsController < BaseController
        include RepositoryTabsSerialization

        DEFAULT_INTERESTING_LIMIT = TestIdentity::INTERESTING_LIMIT
        DEFAULT_SEARCH_LIMIT = 50
        MAX_LIMIT = 100

        def index
          repository = find_repository
          query = params[:query].to_s.strip
          default_limit = query.present? ? DEFAULT_SEARCH_LIMIT : DEFAULT_INTERESTING_LIMIT
          limit = params.fetch(:limit, default_limit).to_i.clamp(1, MAX_LIMIT)
          tests = TestIdentity.interesting_for_repository(repository, query: query.presence, limit: limit)

          render json: {
            repository: repository_json(repository),
            tabs: repository_tabs_json(repository),
            query: query,
            limit: limit,
            tests: tests.map { |test_identity| test_identity_json(test_identity) }
          }
        end

        def show
          repository = find_repository
          test_identity = repository.test_identities.find(params[:id])
          cases = test_identity.test_cases
            .includes(test_run: { run: :job })
            .order(created_at: :desc)
            .limit(TestIdentity::HISTORY_LIMIT)

          render json: {
            repository: repository_json(repository),
            tabs: repository_tabs_json(repository),
            test: test_identity_json(test_identity),
            history: cases.map { |test_case| test_case_json(test_case) }.compact.reverse,
            duration_points: cases.filter_map { |test_case| duration_point_json(test_case) }.reverse
          }
        end

        private

        def find_repository
          Current.user.repositories.find(params[:repository_id])
        end

        def repository_json(repository)
          {
            id: repository.id,
            slug: repository.slug,
            github_url: "https://github.com/#{repository.slug}"
          }
        end

        def test_identity_json(test_identity)
          stats = test_identity.recent_stats
          {
            id: test_identity.id,
            suite_name: test_identity.suite_name,
            name: test_identity.name,
            file_path: test_identity.file_path,
            fingerprint: test_identity.fingerprint,
            last_status: test_identity.last_status,
            last_seen_at: test_identity.last_seen_at&.iso8601,
            last_failed_at: test_identity.last_failed_at&.iso8601,
            last_passed_at: test_identity.last_passed_at&.iso8601,
            last_duration_ms: test_identity.last_duration_ms,
            total_count: stats[:total_count],
            failed_count: stats[:failed_count],
            passed_count: stats[:passed_count],
            failure_rate: stats[:failure_rate].round(4),
            avg_duration_ms: stats[:avg_duration_ms],
            interesting_reasons: test_identity.interesting_reasons(stats: stats)
          }
        end

        def test_case_json(test_case)
          run = test_case.test_run.run
          job = run.job
          {
            id: test_case.id,
            status: test_case.status,
            duration_ms: test_case.duration_ms,
            failure_message: test_case.failure_message,
            created_at: test_case.created_at&.iso8601,
            grader_name: test_case.test_run.grader_name,
            run: {
              id: run.id,
              slug: "RUN-#{run.id}",
              path: "#{job_path(job, tab: "workflows")}#run-#{run.id}"
            },
            job: {
              id: job.id,
              slug: job.slug,
              title: job.issue_title
            }
          }
        end

        def duration_point_json(test_case)
          return if test_case.duration_ms.nil?

          {
            test_case_id: test_case.id,
            created_at: test_case.created_at&.iso8601,
            duration_ms: test_case.duration_ms,
            status: test_case.status
          }
        end
      end
    end
  end
end
