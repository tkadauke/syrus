module Api
  module V1
    module App
      module Admin
        class UsersController < BaseController
          def index
            render json: payload.index
          end

          def show
            render json: payload.show(params[:id])
          end

          def update
            attributes = user_params
            return render_invalid_role if invalid_role?(attributes)

            render json: payload.update(params[:id], attributes)
          end

          def pause_scheduling
            render json: payload.pause_scheduling(params[:id])
          end

          def unpause_scheduling
            render json: payload.unpause_scheduling(params[:id])
          end

          private

          def payload
            ::Admin::Users::Payload.new(params: params, actor: Current.user)
          end

          def user_params
            params.expect(user: [ :role ])
          end

          def invalid_role?(attributes)
            attributes.key?(:role) && !User::ROLES.include?(attributes[:role])
          end

          def render_invalid_role
            render_error(
              "validation_failed",
              "Role must be one of #{User::ROLES.join(', ')}.",
              status: :unprocessable_content
            )
          end
        end
      end
    end
  end
end
