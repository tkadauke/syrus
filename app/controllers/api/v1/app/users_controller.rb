module Api
  module V1
    module App
      # Non-admin user directory for in-app UI pickers (e.g. the group chat
      # invite picker). Unlike Api::V1::App::Admin::UsersController, this has
      # no admin gate — Syrus has no team/org scoping today, so any
      # authenticated user may see the flat instance user list here.
      class UsersController < BaseController
        DEFAULT_LIMIT = 20
        MAX_LIMIT = 100

        def invitable
          scope = User.where.not(id: Current.user.id).order(:id)

          exclude_chat_id = params[:exclude_chat_id].presence
          if exclude_chat_id
            chat_session = Current.user.accessible_chat_sessions.find_by(id: exclude_chat_id)
            scope = scope.where.not(id: chat_session.chat_participants.select(:user_id)) if chat_session
          end

          query = params[:q].to_s.strip
          if query.present?
            pattern = "%#{ActiveRecord::Base.sanitize_sql_like(query)}%"
            scope = scope.where("first_name LIKE :pattern OR last_name LIKE :pattern OR email_address LIKE :pattern", pattern: pattern)
          end

          users = scope.limit(limit_param).map { |user| { id: user.id, name: user.display_name, avatar_url: user.avatar_url } }
          render json: { users: users }
        end

        private

        def limit_param
          params.fetch(:limit, DEFAULT_LIMIT).to_i.clamp(1, MAX_LIMIT)
        end
      end
    end
  end
end
