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
          return unless stale?(etag: [ "diff-review-version", version.id, version.base_sha, version.head_sha ], public: false)

          expires_in 1.year, public: false, immutable: true
          render json: ::App::DiffReviewVersionsPayload.show(version: version, user: Current.user)
        end

        private

        def find_job
          find_job_by_ref(policy_scope(Job).includes(:repository), params[:job_id])
        end
      end
    end
  end
end
