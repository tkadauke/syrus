module Api
  module V1
    module App
      class CoworkersController < BaseController
        include ChatProviderOptions
        include AgentProviderCatalogOptions

        def index
          render json: {
            coworkers: scope.includes(avatar_attachment: :blob).order(Arel.sql("LOWER(name) ASC"), :id).map { |coworker| summary_json(coworker) },
            syrus: syrus_json,
            model_options: model_options_json
          }
        end

        def show
          coworker = find_coworker
          render json: { coworker: detail_json(coworker) }
        end

        def create
          coworker = Coworkers::Coworker.new(owner_user: Current.user)
          authorize coworker, :create?, policy_class: CoworkerPolicy
          created = Coworkers::Create.call(owner: Current.user, **create_params.to_h.symbolize_keys, avatar: params[:avatar], grants: params[:grants])
          render json: { coworker: detail_json(created), redirect_to: "/coworkers/#{created.id}" }, status: :created
        rescue ActiveRecord::RecordInvalid => error
          render_error("validation_failed", error.record.errors.full_messages.to_sentence, status: :unprocessable_content)
        rescue Coworkers::Create::InvalidRemote, Coworkers::Create::BranchExists, ArgumentError => error
          render_error("validation_failed", error.message, status: :unprocessable_content)
        end

        def create_chat
          coworker = find_coworker
          authorize coworker, :manage_chats?, policy_class: CoworkerPolicy
          repository = workspace_repository(coworker)
          chat = ApplicationRecord.transaction do
            # Phase 1 intentionally works directly from the coworker's home
            # branch. Phase 3 replaces this with per-chat branches merged at
            # turn end; keep side chats attached to the workspace Repository
            # until that branch lifecycle exists.
            session = ChatSession.create!(
              user: Current.user, repository: repository, title: coworker.name,
              **coworker.chat_configuration
            )
            Coworkers::Chat.create!(coworker: coworker, chat_session: session, role: "side")
            session
          end
          render json: { chat_path: "/chats/#{chat.id}" }, status: :created
        end

        def add_to_chat
          chat = owned_chat
          coworker = find_coworker
          entry = Coworkers::ChatAgent.create_or_find_by!(chat_session: chat, coworker: coworker) do |agent|
            agent.added_by_user = Current.user
          end
          render json: { agent: roster_json(entry) }, status: :created
        rescue ActiveRecord::RecordInvalid => error
          render_error("validation_failed", error.record.errors.full_messages.to_sentence, status: :unprocessable_content)
        end

        def remove_from_chat
          entry = Coworkers::ChatAgent.find_by!(chat_session: owned_chat, coworker: find_coworker)
          entry.destroy!
          head :no_content
        end

        def test_remote
          match = params.require(:workspace_repo).to_s.strip.match(%r{\A(?:https://github\.com/|git@github\.com:)([^/]+)/([^/]+?)(?:\.git)?/?\z}i)
          return render_error("validation_failed", I18n.t("api.coworkers.invalid_workspace_remote"), status: :unprocessable_content) unless match

          Coworkers::RemoteWorkspace.new(owner: match[1], name: match[2], user: Current.user).test_push_access!
          render json: { message: I18n.t("api.coworkers.push_access_verified") }
        rescue StandardError => error
          render_error("remote_unavailable", error.message, status: :unprocessable_content)
        end

        def sidebar_badge
          ids = Coworkers::Chat.joins(:coworker).where(coworkers: { owner_user_id: Current.user.id }).select(:chat_session_id)
          render json: { count: ChatSession.where(id: ids).where("last_message_at IS NOT NULL AND (last_read_at IS NULL OR last_message_at > last_read_at)").count }
        end

        private

        def scope = CoworkerPolicy::Scope.new(Current.user, Coworkers::Coworker.all).resolve

        def find_coworker
          scope.includes(:grants, coworker_chats: :chat_session).find(params[:id])
        end

        def owned_chat
          ChatSession.active.find_by!(id: params[:chat_id], user_id: Current.user.id)
        end

        def roster_json(entry)
          coworker = entry.coworker
          { id: coworker.id, name: coworker.name, handle: coworker.handle, color_key: coworker.color_key,
            avatar_key: coworker.avatar_key, avatar_url: coworker.avatar_url, removable: true }
        end

        def create_params
          params.permit(:name, :handle, :workspace_repo, :about, :color_key, :avatar_key, :chat_provider, :chat_model, :chat_effort)
        end

        def summary_json(coworker)
          {
            id: coworker.id, name: coworker.name, handle: coworker.handle, role_summary: coworker.role_summary,
            state: coworker.state, color_key: coworker.color_key, avatar_key: coworker.avatar_key,
            avatar_url: coworker.avatar_url, path: "/coworkers/#{coworker.id}"
          }
        end

        def detail_json(coworker)
          summary_json(coworker).merge(
            chat_provider: coworker.chat_provider, chat_model: coworker.chat_model,
            effective_model: coworker.chat_model,
            workspace_repo: coworker.workspace_repo, soul: soul_for(coworker),
            available_chats: available_chats_json(coworker),
            chats: coworker.coworker_chats.sort_by { |link| [ link.main? ? 0 : 1, link.id ] }.map { |link| { id: link.chat_session_id, role: link.role, title: link.chat_session.title, path: "/chats/#{link.chat_session_id}" } },
            grants: coworker.grants.order(:capability).map { |grant| { capability: grant.capability, approval_policy: grant.approval_policy } },
            message_traffic: message_traffic_json(coworker), spend_usd: spend_usd(coworker)
          )
        end

        def spend_usd(coworker)
          chat_spend = coworker.coworker_chats.joins(:chat_session).sum("chat_sessions.cumulative_cost_usd")
          run_spend = Run.joins(:job).where(jobs: { origin: "coworkers", origin_id: coworker.id.to_s }).sum(:cost_usd)
          (chat_spend + run_spend).to_f
        end

        def message_traffic_json(coworker)
          main_chat = coworker.coworker_chats.find(&:main?)&.chat_session
          messages = main_chat ? main_chat.messages.active.where("created_at >= ?", 30.days.ago).to_a : []
          metadata = messages.filter_map { |message| message.content["coworker_message"] if message.content.is_a?(Hash) }
          delivered = metadata.select { |entry| entry["status"].blank? }
          events = messages.filter_map do |message|
            entry = message.content["coworker_message"] if message.content.is_a?(Hash)
            next unless entry&.fetch("status", nil).in?(%w[refused rate_limited])

            { status: entry.fetch("status"), receiver_handle: entry.fetch("receiver_handle"),
              reason: message.extract_text_from_content, occurred_at: message.created_at.iso8601 }
          end
          { sent: delivered.count { |entry| entry["direction"] == "outgoing" },
            received: delivered.count { |entry| entry["direction"] == "incoming" },
            window_days: 30, delivery_events: events.reverse.first(20) }
        end

        def soul_for(coworker)
          repository = workspace_repository(coworker)
          content = RepositoryContent.for(repository, user: Current.user)
          content.read_if_present(content.resolve("coworkers/#{coworker.handle}"), "SOUL.md")&.text
        rescue ActiveRecord::RecordNotFound, RepositoryContent::Error
          nil
        end

        def available_chats_json(coworker)
          chats = Current.user.chat_sessions.active.order(last_message_at: :desc, id: :desc).limit(100).to_a
          chat_ids = chats.map(&:id)
          rostered_ids = Coworkers::ChatAgent.where(coworker: coworker, chat_session_id: chat_ids).pluck(:chat_session_id).to_set
          own_chat_ids = Coworkers::Chat.where(coworker: coworker, chat_session_id: chat_ids).pluck(:chat_session_id).to_set

          chats.map do |chat|
            {
              id: chat.id, title: chat.title.presence || "Chat ##{chat.id}",
              rostered: rostered_ids.include?(chat.id), implicit: own_chat_ids.include?(chat.id)
            }
          end
        end

        def workspace_repository(coworker)
          match = coworker.workspace_repo.match(%r{github\.com[:/]([^/]+)/([^/]+?)(?:\.git)?\z}i)
          raise ActiveRecord::RecordNotFound unless match

          Repository.where("LOWER(owner) = ? AND LOWER(name) = ?", match[1].downcase, match[2].downcase).first!
        end

        def syrus_json
          { id: "syrus", name: "Syrus", handle: "syrus", role_summary: "Engineer", state: "active", color_key: "coral-deep", avatar_key: nil, avatar_url: nil, path: "/coworkers/syrus", built_in: true, chat_model: nil }
        end

        def model_options_json
          agent_provider_catalog_options(Current.user).fetch(:agent_providers).filter_map do |provider|
            next unless provider.fetch(:configured)

            {
              provider: provider.fetch(:value),
              provider_label: provider.fetch(:label),
              models: provider.fetch(:models)
            }
          end
        end
      end
    end
  end
end
