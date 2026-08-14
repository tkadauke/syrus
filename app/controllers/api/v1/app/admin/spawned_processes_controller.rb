module Api
  module V1
    module App
      module Admin
        class SpawnedProcessesController < BaseController
          def index
            render json: payload.index
          rescue ArgumentError, TypeError => e
            render_error("bad_request", e.message, status: :bad_request)
          end

          def show
            render json: payload.show(params[:id])
          end

          def kill
            result = payload.kill(params[:id], user: Current.user)
            if result[:error]
              render_error(result.dig(:error, :code), result.dig(:error, :message), status: result[:status])
              return
            end

            render json: result
          end

          private

          def payload
            ::Admin::SpawnedProcesses::Payload.new(params: params, user: Current.user, default_to_running: true)
          end
        end
      end
    end
  end
end
