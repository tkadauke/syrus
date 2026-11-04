module Api
  module V1
    module App
      class PermissionRequestsController < BaseController
        PER_PAGE = 50

        def index
          page = [ params[:page].to_i, 1 ].max
          filter = Permissions::RequestFilter.new(scope, ::Filters::QueryParam.decode(params[:q]))
          relation = filter.apply.preload(:origin, :subject, :repository, authorization_items: [ :prerequisites, :resulting_authority ]).order(created_at: :desc)
          total = relation.count
          requests = relation.offset((page - 1) * PER_PAGE).limit(PER_PAGE)
          render json: {
            requests: requests.map { |request| present(request) },
            summary: request_summary(scope),
            filter_options: filter.options,
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

        # Applies the adaptive rule/lease and authorizes the waiting invocation in
        # one transaction; a stale preview or ceiling creates neither.
        def smart_decide
          request = scope.find(params[:id])
          item = request.authorization_items.find(params[:item_id])
          Permissions::AuthorizationDecision.new(request:, item:, user: Current.user)
            .call(decision: "approved", smart: { duration: params.require(:duration).to_s, digest: params[:digest].to_s })
          render json: { request: present(request.reload) }
        rescue Permissions::SmartDecision::AlreadyDecided, Permissions::RuleDraft::Stale => error
          render_error("stale_permission_decision", error.message, status: :conflict)
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

          permission_requests = scope.where(id: ids, action: Permissions::CoworkerPermissionRequest::ACTION).order(:id).to_a
          return decide_coworker_permission_requests!(ids, permission_requests, decision) if permission_requests.any?

          requests = scope.where(id: ids).order(:id).preload(:authorization_items).to_a
            requests = scope.where(id: ids).order(:id).lock.to_a
            raise ActiveRecord::RecordNotFound if requests.length != ids.length
            items = PendingActionItem.where(chat_pending_action_id: ids).order(:id).lock.to_a
            validate_decision!(requests, items, decision)
            duration = decision == "approved" ? selected_duration(items) : nil
            executable, record_only = requests.partition { |request| request.payload.to_h["tool_name"].present? }
            record_only.flat_map(&:authorization_items).each do |item|
              changed = item.decide!(decision, principal: Current.user, duration:, reason: params[:reason])
              raise ArgumentError, "request is no longer actionable" unless changed
            end
            record_only.each { |request| request.update!(state: decision == "approved" ? "confirmed" : "rejected") }
            executable.each do |request|
              request.authorization_items.select(&:actionable?).each do |item|
                Permissions::AuthorizationDecision.new(request:, item:, user: Current.user).call(decision:)
              end
            end
          end
          requests
        end

        # A coworker permission request carries no invocation: it can only be
        # denied here, or approved through the adaptive rule so the owner always
        # sees the exact authority being created.
        def decide_coworker_permission_requests!(ids, permission_requests, decision)
          raise ArgumentError, "coworker permission requests cannot be decided together with other requests" if permission_requests.length != ids.length
          raise ArgumentError, I18n.t("api.permission_requests.smart_decision.duration_required") unless decision == "denied"

          ChatPendingAction.transaction do
            locked = scope.where(id: ids).order(:id).lock.to_a
            raise ActiveRecord::RecordNotFound if locked.length != ids.length
            items = locked.map { |request| request.authorization_items.lock.to_a }
            unless locked.all? { |request| request.pending? && request.actionable? } && items.all? { |list| list.one? && list.first.actionable? }
              raise ArgumentError, "request is no longer actionable"
            end

            locked.zip(items).each do |request, list|
              Permissions::AuthorizationDecision.new(request:, item: list.first, user: Current.user).call(decision: "denied")
            end
            permission_requests = locked
          end
          permission_requests
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
