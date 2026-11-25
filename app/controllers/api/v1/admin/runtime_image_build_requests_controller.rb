module Api
  module V1
    module Admin
      # Operator view of runtime image build requests, plus a cancel switch.
      # Reads durable records only and never returns log text, hosts, or
      # addresses (that is the evidence endpoint's job).
      #
      #   GET  /api/v1/admin/runtime_image_build_requests?state=&limit=  - requests with current attempt and result
      #   POST /api/v1/admin/runtime_image_build_requests/:id/cancel     - cancel a request
      class RuntimeImageBuildRequestsController < BaseController
        MAX_LIMIT = 200

        def index
          scope = RuntimeImageBuildRequest.includes(:result, :attempts).order(id: :desc)
          scope = scope.where(state: params[:state]) if RuntimeImageBuildRequest::STATES.include?(params[:state].to_s)
          limit = params.fetch(:limit, 50).to_i.clamp(1, MAX_LIMIT)
          render json: { requests: scope.limit(limit).map { |request| serialize(request) } }
        end

        def cancel
          request_record = RuntimeImageBuildRequest.find(params[:id])
          RuntimeImages::Builds::Orchestrator.new.cancel(request_record, reason: params[:reason].presence || "canceled by an administrator", actor: "admin")
          render json: serialize(request_record.reload), status: :accepted
        end

        private

        def serialize(request)
          attempt = request.attempts.max_by(&:number)
          {
            id: request.id, state: request.state, platform: request.platform, namespace_id: request.runtime_image_namespace_id,
            source_digest: request.source_digest, recipe_digest: request.recipe_digest, requester_kind: request.requester_kind,
            attempts: request.attempts_count, max_attempts: request.max_attempts, cancel_requested: request.cancel_requested?,
            next_attempt_at: request.next_attempt_at, created_at: request.created_at, finished_at: request.finished_at,
            current_attempt: attempt && { number: attempt.number, state: attempt.state, worker: attempt.worker_hostname,
                                          lease_expires_at: attempt.lease_expires_at, error_code: attempt.error_code },
            result: request.result&.slice(*%w[outcome digest error_code message attempts_used finished_at])
          }
        end
      end
    end
  end
end
