# Chat-provider helpers extracted from Api::V1::App::ChatsController.
module ChatProviderOptions
  private

  def chat_provider_label(provider)
    case provider
    when "claude" then "Claude"
    when "codex" then "Codex"
    else provider.to_s.titleize
    end
  end

end
