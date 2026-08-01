class PollTelegramUpdatesJob < PlatformPollingJob
  private

  def configured?
    AppSetting.telegram_configured?
  end

  def poll_once
    offset = AppSetting.telegram_update_offset
    updates = telegram_client.get_updates(offset: offset, timeout: 25)
    updates.each do |update|
      process_update(update)
      AppSetting.current.update!(telegram_update_offset: update["update_id"] + 1)
    end
  end

  def telegram_client
    @telegram_client ||= TelegramClient.new
  end

  def process_update(update)
    message = update["message"] or return
    from = message["from"] or return
    text = message["text"].to_s.strip
    return if text.blank?

    if text.start_with?("/start ")
      handle_linking(token: text.delete_prefix("/start ").strip, from: from)
    else
      result = InboundMessageRouter.new(
        platform: "telegram",
        external_id: from["id"].to_s,
        external_handle: from["username"],
        message_text: text
      ).call

      if result.status == :not_linked
        telegram_client.send_message(
          chat_id: from["id"],
          text: "I don't recognize your account. Link it from the Syrus web UI under Settings → Connected Platforms."
        )
      end
    end
  end

  def handle_linking(token:, from:)
    payload = Rails.application.message_verifier(:platform_linking).verify(token)
    user_id = payload["user_id"]

    identity = PlatformIdentity.find_or_initialize_by(platform: "telegram", external_id: from["id"].to_s)
    identity.assign_attributes(user_id: user_id, external_handle: from["username"], linked_at: Time.current)
    identity.save!

    AppEvents.broadcast(
      user: identity.user,
      type: "platform_identity_linked",
      resource: "platform_identity",
      id: identity.id,
      payload: App::PlatformIdentitiesPayload.call(user: identity.user)
    )

    telegram_client.send_message(
      chat_id: from["id"],
      text: "You're connected! You can now chat with Syrus here."
    )
  rescue ActiveSupport::MessageVerifier::InvalidSignature
    telegram_client.send_message(
      chat_id: from["id"],
      text: "This link has expired or is invalid. Please generate a new one from Syrus → Settings → Connected Platforms."
    )
  end
end
