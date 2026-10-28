module Api
  module V1
    module App
      class ChatSharesController < BaseController
        def index
          chat = owned_chat
          render json: payload(chat)
        end

        def create
          chat = owned_chat
          user = User.find_by(id: params[:user_id])
          unless user
            render_error("validation_failed", I18n.t("api.chats.errors.unknown_user_id"), status: :unprocessable_content)
            return
          end

          chat.chat_shares.find_or_create_by!(target: user) { |share| share.shared_by_user = Current.user }
          render json: payload(chat), status: :created
        rescue ActiveRecord::RecordInvalid => error
          render_error("validation_failed", error.record.errors.full_messages.to_sentence, status: :unprocessable_content)
        end

        def destroy
          chat = owned_chat
          chat.chat_shares.find(params[:id]).destroy!
          render json: payload(chat)
        end

        def candidates
          chat = owned_chat
          query = params[:q].to_s.strip
          scope = eligible_people_scope
          exact_handle = Handle.find_by("LOWER(handle) = ?", query.delete_prefix("@").downcase)&.owner
          scope = scope.or(User.where(id: exact_handle.id)) if exact_handle.is_a?(User)
          if query.present?
            pattern = "%#{ActiveRecord::Base.sanitize_sql_like(query.delete_prefix('@').downcase)}%"
            scope = scope.left_joins(:handle_record).where("LOWER(users.name) LIKE :pattern OR LOWER(handles.handle) LIKE :pattern", pattern: pattern)
          end
          excluded_ids = chat.chat_participants.pluck(:user_id) + chat.chat_shares.where(target_type: "User").pluck(:target_id)
          users = scope.where.not(id: excluded_ids).distinct.limit(20)
          render json: { people: users.map { |user| person_json(user, chat) } }
        end

        private

        def owned_chat
          Current.user.chat_sessions.active.find(params[:chat_id])
        end

        def eligible_people_scope
          repository_ids = Repository.accessible_to(Current.user).select(:id)
          team_ids = Current.user.team_memberships.select(:team_id)
          User.where(id: Repository.where(id: repository_ids).select(:user_id))
            .or(User.where(id: RepositoryMembership.where(repository_id: repository_ids).select(:user_id)))
            .or(User.where(id: TeamMembership.where(team_id: team_ids).select(:user_id)))
        end

        def payload(chat)
          { shares: chat.chat_shares.includes(:target).order(:created_at, :id).map { |share| person_json(share.target, chat).merge(id: share.id) } }
        end

        def person_json(user, chat)
          repository = chat.repository
          {
            user_id: user.id,
            name: user.display_name,
            handle: user.handle,
            avatar_url: user.avatar_url,
            repository_access_warning: repository.present? && !Repository.accessible_to(user).exists?(id: repository.id)
          }
        end
      end
    end
  end
end
