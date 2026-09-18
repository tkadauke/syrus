# Chat-provider helpers extracted from Api::V1::App::ChatsController.
module ChatProviderOptions
  private

  def normalized_chat_provider_param(value)
    value.to_s.strip.presence
  end

  def chat_provider_label(provider)
    ChatProviders.display_name(provider)
  end

  def chat_provider_options(_chat_session)
    User.chat_providers.map do |provider|
      {
        value: provider,
        label: chat_provider_label(provider),
        configured: Current.user.chat_provider_configured?(provider),
        effective_provider: provider,
        effective_label: chat_provider_label(provider)
      }
    end
  end

  def validated_chat_provider_param(value, allow_blank: true)
    provider = normalized_chat_provider_param(value)
    return nil if provider.blank? && allow_blank

    unless User.chat_providers.include?(provider)
      render_error("validation_failed", "Invalid provider. Must be one of: #{User.chat_providers.join(", ")}.", status: :unprocessable_content)
      return
    end

    unless Current.user.chat_provider_configured?(provider)
      render_error("validation_failed", "Chat provider is not configured.", status: :unprocessable_content)
      return
    end

    provider
  end
end
