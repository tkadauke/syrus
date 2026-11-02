module Permissions
  # Read model for the Permissions Hub AI approval section: the registered
  # providers (with their disclosure), the owner's delegations, the core
  # human-only exclusions, and the redacted history of AI decisions. The
  # feature is reported disabled until a provider plugin is registered.
  class ApprovalDelegationPayload
    HISTORY_LIMIT = 100

    def initialize(user, providers: nil)
      @user = user
      @providers = providers || Syrus::PluginRegistry.providers_for(:approval_provider)
    end

    def as_json
      {
        enabled: providers.any?,
        providers: providers.map { |provider| serialize_provider(provider) },
        delegations: delegations.map { |delegation| serialize_delegation(delegation) },
        human_only: {
          effects: ApprovalProviderDelegation::CORE_HUMAN_ONLY_EFFECTS,
          capabilities: [ Permissions::ApprovalProviderAuthorizer::HUMAN_ONLY_CAPABILITY ]
        },
        history: history
      }
    end

    private

    attr_reader :user, :providers

    def delegations
      user.approval_provider_delegations.order(created_at: :desc).limit(HISTORY_LIMIT)
    end

    def serialize_provider(provider)
      { provider_key: provider.provider_key.to_s, display_name: provider.display_name,
        data_sharing: provider.data_sharing, default_guidance: provider.default_guidance }
    end

    def serialize_delegation(delegation)
      provider = providers.find { |candidate| candidate.provider_key.to_s == delegation.provider_key }
      delegation.attributes.slice("id", "provider_key", "capability", "resource_type", "resource_scope",
        "excluded_effects", "revoked_at", "created_at").merge(
        "status" => delegation.active? ? (provider ? "active" : "provider_unavailable") : "revoked",
        "provider_name" => provider&.display_name || delegation.provider_key
      )
    end

    def history
      PendingActionTransition
        .joins(:chat_pending_action)
        .where(event_type: Permissions::ApprovalProviderLifecycle::EVALUATED_EVENT,
          chat_pending_actions: { user_id: user.id })
        .includes(:chat_pending_action).order(created_at: :desc, id: :desc).limit(HISTORY_LIMIT).map do |transition|
        metadata = transition.metadata
        {
          id: transition.id, occurred_at: transition.created_at,
          request_id: transition.chat_pending_action_id, purpose: transition.chat_pending_action.purpose,
          outcome: metadata["outcome"], provider_outcome: metadata["provider_outcome"],
          rationale: metadata.dig("approval_provider", "decision", "rationale"),
          delegation_id: transition.actor_type == "ApprovalProviderDelegation" ? transition.actor_id : nil
        }
      end
    end
  end
end
