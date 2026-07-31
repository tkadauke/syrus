module Api
  module V1
    module App
      module Admin
        class SupervisorChatsController < Api::V1::App::ChatsController
          before_action :require_admin

          def show
            unless Feature.admin_supervisor_chat_enabled?
              render_error("feature_disabled", "Admin supervisor chat is not enabled.", status: :not_found)
              return
            end

            chat_session = SupervisorChat.ensure_for!(Current.user)
            render json: {
              message: "Supervisor chat opened.",
              redirect_to: chat_path(chat_session),
              chat: chat_json(chat_session)
            }
          end
        end
      end
    end
  end
end
