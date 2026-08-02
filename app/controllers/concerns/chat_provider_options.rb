# Chat-provider helpers extracted from Api::V1::App::ChatsController.
module ChatProviderOptions
  private

  def normalized_chat_provider_param(value)
    value.to_s.strip.presence
  end

  def chat_provider_label(provider)
    case provider
    when "claude" then "Claude"
    when "codex" then "Codex"
    else provider.to_s.titleize
    end
  end

  def chat_provider_options(_chat_session)
    configured = Current.user.configured_agent_providers
    User::CHAT_PROVIDERS.map do |provider|
      {
        value: provider,
        label: chat_provider_label(provider),
        configured: configured.include?(provider),
        effective_provider: provider,
        effective_label: chat_provider_label(provider)
      }
    end
  end
end
