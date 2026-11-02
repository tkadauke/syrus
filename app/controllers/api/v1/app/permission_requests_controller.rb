module Api
  module V1
    module App
      class PermissionRequestsController < BaseController
        def index
          requests = scope.preload(:origin, :subject, :repository, :authorization_items).order(created_at: :desc).limit(200)
          render json: { requests: requests.map { |request| Permissions::RequestPresenter.new(request).as_json } }
        end

        def decide
          request = scope.includes(:authorization_items).find(params[:id])
          decision = params.require(:decision).to_s
          raise ArgumentError, "decision must be approved or denied" unless decision.in?(%w[approved denied])

          PendingActionItem.transaction do
            request.authorization_items.pending.each do |item|
              duration = decision == "approved" ? selected_duration(item) : nil
              item.decide!(decision, principal: Current.user, duration:, reason: params[:reason])
            end
            request.update!(state: decision == "approved" ? "confirmed" : "rejected")
          end
          render json: { request: Permissions::RequestPresenter.new(request.reload).as_json }
        rescue ArgumentError, ActiveRecord::RecordInvalid => error
          render_error("invalid_permission_decision", error.message, status: :unprocessable_content)
        end

        def dismiss
          request = scope.find(params[:id])
          if request.dismiss!
            render json: { request: Permissions::RequestPresenter.new(request.reload).as_json }
          else
            render_error("permission_request_not_dismissible", I18n.t("api.permission_requests.not_dismissible"), status: :unprocessable_content)
          end
        end

        private

        def scope
          ChatPendingAction.where(user: Current.user, request_kind: "authorization_request")
        end

        def selected_duration(item)
          duration = params[:duration].presence || "invocation"
          raise ArgumentError, "duration is not available for this request" unless item.requested_durations.include?(duration)

          duration
        end
      end
    end
  end
end
