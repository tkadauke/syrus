module Api
  module V1
    module App
      class JobTestResultsController < Syrus::Host::AppController
        def index
          job = find_job
          render json: TestInsights::RunResults.for_job(
            job: job,
            grader_name: params[:grader_name],
            include_suites: ActiveModel::Type::Boolean.new.cast(params[:include_suites]),
            case_limit: params[:case_limit]
          )
        end

        private

        def find_job
          scope = Job.visible_to(Syrus::Host::Current.user)
          find_job_by_ref(scope, params[:job_id])
        end
      end
    end
  end
end
