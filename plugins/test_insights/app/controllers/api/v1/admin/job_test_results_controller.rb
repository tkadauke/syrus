module Api
  module V1
    module Admin
      # Operator-facing twin of TestInsights::Tools::ReadJobTestResultsTool --
      # same TestInsights::RunResults service the MCP tool calls, reachable
      # with a bearer token instead of an agent run.
      class JobTestResultsController < BaseController
        def index
          job = find_job_by_ref(Job.all, params[:job_id])

          render json: TestInsights::RunResults.for_job(
            job: job,
            grader_name: params[:grader_name],
            include_slow_cases: boolean_param(params[:include_slow_cases], default: false),
            include_suites: boolean_param(params[:include_suites], default: false),
            case_limit: params[:case_limit]
          )
        end

        private

        def boolean_param(value, default:)
          return default if value.nil?

          ActiveModel::Type::Boolean.new.cast(value)
        end
      end
    end
  end
end
