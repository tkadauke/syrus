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
            render json: payload.update(params[:id], user_params)
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
        end
      end
    end
  end
end
