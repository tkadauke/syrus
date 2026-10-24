module Api
  module V1
    module Admin
      # API mirror of the operator console kill switches.
      #
      # GET  /api/v1/admin/console
      # POST /api/v1/admin/console/pause_polling
      # POST /api/v1/admin/console/unpause_polling
      # POST /api/v1/admin/console/pause_runs
      # POST /api/v1/admin/console/unpause_runs
      class ConsoleController < BaseController
        def show
          render json: console_payload.show
        end

        def pause_polling
          render json: console_payload.pause_polling(source: "api")
        end

        def unpause_polling
          render json: console_payload.unpause_polling(source: "api")
        end

        def pause_runs
          render json: console_payload.pause_runs(source: "api")
        end

        def unpause_runs
          render json: console_payload.unpause_runs(source: "api")
        end

        private

        def console_payload
          ::Admin::Console::Payload.new(actor: current_api_user)
        end
      end
    end
  end
end
