module Api
  module V1
    module App
      class RepositoryFlakyTestsController < BaseController
        def index
          repository = find_repository
          lookback   = params.fetch(:lookback, TestCase::FLAKINESS_LOOKBACK).to_i.clamp(5, 100)
          limit      = params.fetch(:limit, 20).to_i.clamp(1, 100)

          tests = TestCase.top_flaky_tests(repository: repository, lookback: lookback, limit: limit)

          render json: {
            repository_id: repository.id,
            lookback:      lookback,
            tests:         tests.map { |t| flaky_test_json(t) }
          }
        end

        private

        def find_repository
          Current.user.repositories.find(params[:repository_id])
        end

        def flaky_test_json(test)
          {
            suite_name:      test[:suite_name],
            name:            test[:name],
            flakiness_score: test[:flakiness_score].round(4),
            failed_count:    test[:failed_count],
            total_count:     test[:total_count],
            avg_duration_ms: test[:avg_duration_ms],
            last_seen_at:    test[:last_seen_at]
          }
        end
      end
    end
  end
end
