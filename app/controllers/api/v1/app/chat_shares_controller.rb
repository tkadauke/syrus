module Api
  module V1
    module App
      class ChatSharesController < BaseController
        def index
          chat = owned_chat
          render json: { shares: shares_payload(chat), candidates: candidates_payload(chat) }
        end

        def create
          chat = owned_chat
          target = eligible_target(chat)
          unless target
            render_error("validation_failed", "That person cannot be shared with.", status: :unprocessable_content)
            return
          end

          share = chat.chat_shares.create!(target: target, shared_by_user: Current.user)
          NotificationService.create_for(
            user: target,
            kind: "chat_mention",
            repository: chat.repository,
            actor: Current.user,
            body: "#{Current.user.display_name} shared a chat with you.",
            target_path: "/chats/#{chat.id}",
            dedupe_key: "chat-share:#{share.id}:user:#{target.id}"
          )
          render json: { shares: shares_payload(chat) }, status: :created
        end

        def destroy
          chat = owned_chat
          chat.chat_shares.find(params[:id]).destroy!
          render json: { shares: shares_payload(chat) }
        end

        private

        def owned_chat
          Current.user.chat_sessions.active.find(params[:chat_id])
        end

        def eligible_target(chat)
          user = User.find_by(id: params[:user_id])
          user if user && user != Current.user && eligible_users(chat).where(id: user.id).exists?
        end

        def eligible_users(chat)
          exact_handle = params[:q].to_s.strip.downcase.delete_prefix("@")
          return User.joins(:handle_record).where(handles: { handle: exact_handle }) if exact_handle.present?

          repository_user_ids = chat.repository ? RepositoryMembership.where(repository_id: chat.repository.id).select(:user_id) : User.none.select(:id)
          team_ids = Current.user.team_memberships.select(:team_id)
          team_user_ids = TeamMembership.where(team_id: team_ids).select(:user_id)
          User.where(id: repository_user_ids).or(User.where(id: team_user_ids))
        end

        def candidates_payload(chat)
          shared_ids = chat.chat_shares.where(target_type: "User").pluck(:target_id)
          eligible_users(chat).where.not(id: [ Current.user.id, *shared_ids ]).includes(:handle_record).map do |user|
            user_payload(user, chat)
          end
        end

        def shares_payload(chat)
          chat.chat_shares.includes(:target).order(:created_at, :id).map do |share|
            user_payload(share.target, chat).merge(id: share.id)
          end
        end

        def user_payload(user, chat)
          {
            user_id: user.id,
            name: user.display_name,
            handle: user.handle,
            avatar_url: user.avatar_url,
            repository_access: chat.repository.nil? || Repository.accessible_to(user).exists?(id: chat.repository.id)
          }
        end
      end
    end
  end
end
