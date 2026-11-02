module Api
  module V1
    module App
      class PermissionRequestsController < BaseController
        PER_PAGE = 50

        def index
          page = [ params[:page].to_i, 1 ].max
          relation = scope.preload(:origin, :subject, :repository, :authorization_items).order(created_at: :desc)
          total = relation.count
          requests = relation.offset((page - 1) * PER_PAGE).limit(PER_PAGE)
          render json: {
            requests: requests.map { |request| present(request) },
            summary: request_summary(relation),
            pagination: { page:, per_page: PER_PAGE, total:, total_pages: (total.to_f / PER_PAGE).ceil }
          }
        end

        def decide
          requests = decide_requests!([ params[:id] ])
          render json: { request: present(requests.first.reload) }
        rescue ArgumentError, ActiveRecord::RecordInvalid => error
          render_error("invalid_permission_decision", error.message, status: :unprocessable_content)
        end

        def batch_decide
          requests = decide_requests!(params.require(:request_ids))
          render json: { requests: requests.map { |request| present(request.reload) } }
        rescue ArgumentError, ActiveRecord::RecordInvalid => error
          render_error("invalid_permission_decision", error.message, status: :unprocessable_content)
        end

        def dismiss
          request = scope.find(params[:id])
          if request.dismiss!
            render json: { request: present(request.reload) }
          else
            render_error("permission_request_not_dismissible", I18n.t("api.permission_requests.not_dismissible"), status: :unprocessable_content)
          end
        end

        private

        def scope
          ChatPendingAction.where(user: Current.user, request_kind: "authorization_request")
        end

        def decide_requests!(ids)
          ids = Array(ids).map(&:to_i).uniq
          raise ArgumentError, "at least one request is required" if ids.empty?
          decision = params.require(:decision).to_s
          raise ArgumentError, "decision must be approved or denied" unless decision.in?(%w[approved denied])

          requests = []
          ChatPendingAction.transaction do
            requests = scope.where(id: ids).order(:id).lock.to_a
            raise ActiveRecord::RecordNotFound if requests.length != ids.length
            items = PendingActionItem.where(chat_pending_action_id: ids).order(:id).lock.to_a
            validate_decision!(requests, items, decision)
            duration = decision == "approved" ? selected_duration(items) : nil
            items.each do |item|
              changed = item.decide!(decision, principal: Current.user, duration:, reason: params[:reason])
              raise ArgumentError, "request is no longer actionable" unless changed
            end
            requests.each { |request| request.update!(state: decision == "approved" ? "confirmed" : "rejected") }
          end
          requests
        end

        def validate_decision!(requests, items, decision)
          raise ArgumentError, "request is no longer actionable" unless requests.all? { |request| request.pending? && request.actionable? }
          raise ArgumentError, "all request items must be pending" if items.empty? || items.any? { |item| !item.pending? }
          selected_duration(items) if decision == "approved"
        end

        def selected_duration(items)
          duration = params[:duration].presence || "invocation"
          raise ArgumentError, "duration is not compatible with every request item" unless items.all? { |item| item.requested_durations.include?(duration) }

          duration
        end

        def present(request)
          Permissions::RequestPresenter.new(request, current_user: Current.user).as_json
        end

        def request_summary(relation)
          pending = relation.where(state: "pending")
          {
            pending_count: pending.count,
            blocked_agent_count: pending.where(checkpoint_state: "waiting").count
          }
        end
      end
    end
  end
end
