module Api
  module V1
    module App
      module Admin
        class SupervisorChatsController < BaseController
          include ChatProviderOptions

          CLAUDE_CHAT_MODELS = [
            { value: "claude-opus-4-7", label: "Claude Opus 4.7" },
            { value: "claude-sonnet-4-6", label: "Claude Sonnet 4.6" },
            { value: "claude-haiku-4-5-20251001", label: "Claude Haiku 4.5" }
          ].freeze

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

          private

          def chat_json(chat_session)
            repository = chat_session.repository
            effective_provider = chat_session.effective_chat_provider
            {
              id: chat_session.id,
              title: chat_session.title.presence || ChatSession.fallback_title_for(repository),
              title_pending: chat_session.title_pending?,
              system_kind: chat_session.system_kind,
              pinned: chat_session.pinned?,
              pinned_context: chat_session.pinned_context,
              chat_provider: chat_session.chat_provider,
              effective_chat_provider: effective_provider,
              effective_chat_provider_label: chat_provider_label(effective_provider),
              provider_availability: ::App::ProviderAvailability.for_user(Current.user, effective_provider),
              chat_provider_options: chat_provider_options(chat_session),
              chat_model: chat_session.chat_model,
              available_chat_models: available_chat_models_for(chat_session),
              mode: chat_session.mode,
              local_daemon_state: chat_session.local_daemon_state,
              local_daemon_repo: chat_session.local_daemon_repo,
              local_daemon_branch: chat_session.local_daemon_branch,
              chat_path: chat_path(chat_session),
              repository: repository ? repository_json(repository).merge(repository_path: repository_path(repository)) : nil,
              turn_in_flight: chat_session.turn_in_flight?,
              agent_busy: chat_session.agent_busy?,
              stop_requested_at: chat_session.stop_requested_at&.iso8601,
              suggested_next_step: chat_session.suggested_next_step,
              cumulative_input_tokens: chat_session.cumulative_input_tokens.to_i,
              cumulative_output_tokens: chat_session.cumulative_output_tokens.to_i,
              cumulative_cost_usd: chat_session.cumulative_cost.to_f,
              pending_proposal_count: chat_session.proposals.where(state: "proposed").count +
                chat_session.pending_actions.where(state: "pending").count,
              confirmed_proposal_count: chat_session.proposals.confirmed.count,
              linked_direct_job_count: Job.where(linked_chat_id: chat_session.id, kind: "direct").count,
              scratchpad_items_count: chat_session.scratchpad_items.count,
              coding_checkout_uncommitted: chat_session.coding_checkout_uncommitted?,
              coding_checkout_branch: chat_session.coding_checkout_branch,
              coding_relay_ready: chat_session.coding_relay_address.present?,
              chat_effort: chat_session.chat_effort
            }
          end

          def repository_json(repository)
            {
              id: repository.id,
              slug: repository.slug
            }
          end

          def available_chat_models_for(chat_session)
            return [] unless chat_session.effective_chat_provider == "claude"

            CLAUDE_CHAT_MODELS
          end
        end
      end
    end
  end
end
