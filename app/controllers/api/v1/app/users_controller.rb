module Api
  module V1
    module App
      # Non-admin user directory for in-app UI pickers (e.g. the group chat
      # invite picker). Unlike Api::V1::App::Admin::UsersController, this has
      # no admin gate — Syrus has no team/org scoping today, so any
      # authenticated user may see the flat instance user list here.
      class UsersController < BaseController
        def invitable
          scope = User.where.not(id: Current.user.id).order(:id)

          exclude_chat_id = params[:exclude_chat_id].presence
          if exclude_chat_id
            chat_session = Current.user.accessible_chat_sessions.find_by(id: exclude_chat_id)
            scope = scope.where.not(id: chat_session.chat_participants.select(:user_id)) if chat_session
          end

          render json: scope.map { |user| { id: user.id, name: user.display_name } }
        end
      end
    end
  end
end
