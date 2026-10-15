module Api
  module V1
    module App
      class JobTestResultsController < BaseController
        def index
          job = find_job
          render json: TestInsights::RunResults.for_job(
            job: job,
            include_suites: true,
            case_limit: params[:case_limit]
          )
        end

        private

        def find_job
          scope = Job.accessible_to(Current.user)
          find_job_by_ref(scope, params[:job_id])
        end
      end
    end
  end
end
