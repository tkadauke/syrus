module Api
  module V1
    module Admin
      class PendingActionsController < BaseController
        def invoke
          invocation = ::PendingActions::ApiInvocation.new(
            action_key: params.require(:action_key),
            payload: payload,
            reason: params[:reason],
            user: current_api_user,
            repository: repository
          )

          record = invocation.call
          render json: {
            ok: true,
            message: "Pending action operation invoked.",
            action_key: invocation.action_key,
            result: result_payload(record)
          }
        rescue ::PendingActions::UnknownAction => e
          render_error("unknown_pending_action", e.message, status: :not_found)
        rescue ActiveRecord::RecordInvalid => e
          render_error("invalid_pending_action_payload", e.record.errors.full_messages.to_sentence, status: :unprocessable_content)
        rescue ArgumentError => e
          render_error("pending_action_operation_failed", e.message, status: :unprocessable_content)
        end

        private

        def repository
          return nil if params[:repository_id].blank?

          Repository.find(params[:repository_id])
        end

        def payload
          raw_payload = params[:payload] || {}
          return raw_payload.permit!.to_h if raw_payload.is_a?(ActionController::Parameters)

          raw_payload.to_h
        end

        def result_payload(record)
          return nil unless record

          {
            type: record.class.name,
            id: record.respond_to?(:id) ? record.id : nil,
            slug: record.respond_to?(:slug) ? record.slug : nil
          }.compact
        end
      end
    end
  end
end
