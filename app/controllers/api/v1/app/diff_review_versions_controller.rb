module Api
  module V1
    module App
      class DiffReviewVersionsController < BaseController
        def index
          job = find_job
          render json: ::App::DiffReviewVersionsPayload.index(job: job)
        end

        def show
          job = find_job
          version = job.diff_review_versions.find(params[:id])
          render json: ::App::DiffReviewVersionsPayload.show(version: version)
        end

        private

        def find_job
          find_job_by_ref(policy_scope(Job).includes(:repository), params[:job_id])
        end
      end
    end
  end
end
