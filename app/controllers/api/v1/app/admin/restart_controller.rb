module Api
  module V1
    module App
      module Admin
        # Session-authenticated mirror of Api::V1::Admin::RestartController
        # for the operator console's Maintenance section.
        class RestartController < BaseController
          def create
            result = restart_service.request(
              component: params.require(:component),
              force: ActiveModel::Type::Boolean.new.cast(params[:force]),
              source: "app"
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
            ::Admin::RestartService.new(actor: Current.user)
          end
        end
      end
    end
  end
end
