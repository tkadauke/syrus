module Api
  module V1
    module App
      module Admin
        class ConsoleController < BaseController
          def show
            render json: console_payload.show
          end

          def pause_polling
            render json: console_payload.pause_polling(source: "app")
          end

          def unpause_polling
            render json: console_payload.unpause_polling(source: "app")
          end

          def pause_runs
            render json: console_payload.pause_runs(source: "app")
          end

          def unpause_runs
            render json: console_payload.unpause_runs(source: "app")
          end

          def clear_github_cache
            render json: console_payload.clear_github_cache(user_id: params[:user_id], source: "app")
          end

          private

          def console_payload
            ::Admin::Console::Payload.new(actor: Current.user)
          end
        end
      end
    end
  end
end
