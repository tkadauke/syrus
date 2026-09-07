module Api
  module V1
    module Admin
      # Operator-facing twin of TestInsights::Tools::ListRepositoryTestInsightsTool
      # and TestInsights::Tools::ReadTestInsightTool -- same TestInsights::Query /
      # TestInsights::Detail service objects the MCP tools call, reachable with a
      # bearer token instead of a browser session or an agent run.
      class RepositoryTestsController < BaseController
        def index
          result = TestInsights::Query.call(
            user: current_api_user,
            repository_id: params[:repository_id],
            category: params[:state].presence || params[:category].presence || params[:filter],
            sort: params[:sort],
            direction: params[:direction],
            query: params[:query],
            grader_name: params[:grader_name],
            limit: params[:limit],
            filters: filters_param
          )

          render json: {
            repository: repository_json(result.repository),
            filter: result.category,
            sort: result.sort,
            direction: result.direction,
            query: result.query,
            grader_name: params[:grader_name].presence,
            limit: result.limit,
            summary_window: result.summary_window,
            tests: result.tests
          }
        end

        def show
          repository = Repository.find(params[:repository_id])
          test_identity = TestInsights::TestIdentity.for_repository(repository).find(params[:id])

          render json: TestInsights::Detail.call(
            user: current_api_user,
            test_identity_id: test_identity.id,
            history_limit: params[:history_limit],
            include_failures: include_failures_param
          )
        end

        private

        def filters_param
          raw = params[:filters]
          raw.respond_to?(:to_unsafe_h) ? raw.to_unsafe_h : {}
        end

        def include_failures_param
          return true if params[:include_failures].nil?

          ActiveModel::Type::Boolean.new.cast(params[:include_failures])
        end

        def repository_json(repository)
          {
            id: repository.id,
            slug: repository.slug,
            github_url: "https://github.com/#{repository.slug}"
          }
        end
      end
    end
  end
end
