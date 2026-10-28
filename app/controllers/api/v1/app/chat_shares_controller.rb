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
          target = share_target
          unless target
            render_error("validation_failed", I18n.t("api.chats.errors.unknown_user_id"), status: :unprocessable_content)
            return
          end

          chat.chat_shares.find_or_create_by!(target: target) { |share| share.shared_by_user = Current.user }
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
          coworkers = filtered_plugin_share_candidates(query).reject do |candidate|
            chat.chat_shares.exists?(target_type: candidate.class.polymorphic_name, target_id: candidate.id)
          end
          people = users.map { |user| target_json(user, chat) }
          render json: { people: people, targets: people + coworkers.map { |coworker| target_json(coworker, chat) } }
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
          { shares: chat.chat_shares.includes(:target).order(:created_at, :id).map { |share| target_json(share.target, chat).merge(id: share.id) } }
        end

        def target_json(target, chat)
          repository = chat.repository
          {
            target_type: target.class.polymorphic_name,
            target_id: target.id,
            user_id: (target.id if target.is_a?(User)),
            kind: target.kind,
            name: target.display_name,
            handle: target.handle,
            avatar_url: target.avatar_url,
            repository_access_warning: target.is_a?(User) && repository.present? && !Repository.accessible_to(target).exists?(id: repository.id)
          }
        end

        def share_target
          return User.find_by(id: params[:user_id]) if params[:user_id].present?

          type = params[:target_type].to_s
          id = Integer(params[:target_id], exception: false)
          return unless id

          plugin_share_candidates.find do |target|
            target.class.polymorphic_name == type && target.id == id
          end
        end

        def plugin_share_candidates
          @plugin_share_candidates ||= Syrus::PluginRegistry.providers_for(:mentionable).flat_map do |provider|
            provider.respond_to?(:share_candidates) ? Array(provider.share_candidates(user: Current.user)) : []
          end
        end

        def filtered_plugin_share_candidates(query)
          return plugin_share_candidates if query.blank?

          needle = query.delete_prefix("@").downcase
          plugin_share_candidates.select do |target|
            target.display_name.to_s.downcase.include?(needle) || target.handle.to_s.downcase.include?(needle)
          end
        end
      end
    end
  end
end
