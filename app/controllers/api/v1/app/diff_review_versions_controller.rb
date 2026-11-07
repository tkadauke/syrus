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
          payload = ::App::DiffReviewVersionsPayload.show(version: version, user: Current.user)
          return unless stale?(etag: payload_etag("diff-review-version", payload), public: false)

          render json: payload
        end

        private

        def payload_etag(namespace, payload)
          [ namespace, payload[:base_sha], payload[:head_sha], Digest::SHA256.hexdigest(payload.to_json) ]
        end

        def find_job
          find_job_by_ref(policy_scope(Job).includes(:repository), params[:job_id])
        end
      end
    end
  end
end
