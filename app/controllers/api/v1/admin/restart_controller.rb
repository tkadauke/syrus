module Api
  module V1
    module Admin
      # POST /api/v1/admin/restart
      # Body: { component: "web" | "worker" | "all", force: true }
      #
      # Writes a Rails.cache poison-pill timestamp that every web/worker
      # process independently polls for (see RestartWatcher). Restarting
      # `worker` or `all` is refused with 409 while Runs are active unless
      # `force: true` is passed.
      class RestartController < BaseController
        def create
          result = restart_service.request(
            component: params.require(:component),
            force: ActiveModel::Type::Boolean.new.cast(params[:force]),
            source: "api"
          )

          if result[:initiated]
            render json: result, status: :accepted
          else
            render json: result.merge(message: "Pass force: true to restart with active runs"), status: :conflict
          end
        rescue ::Admin::RestartService::InvalidComponent
          render_error("bad_request", "component must be one of #{::Admin::RestartService::COMPONENTS.join(', ')}", status: :bad_request)
        end

        private

        def restart_service
          ::Admin::RestartService.new(actor: current_api_user)
        end
      end
    end
  end
end
