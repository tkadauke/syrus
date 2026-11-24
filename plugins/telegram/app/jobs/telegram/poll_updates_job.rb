module Telegram
  # Inbound half of the Telegram platform_delivery provider: long-polls
  # getUpdates and re-enqueues itself. Registered as
  # Telegram::PlatformAdapter.connector_job_class, so
  # PlatformDelivery::Registry.start_connectors! starts/stops it with the
  # plugin's enabled state.
  class PollUpdatesJob < PlatformPollingJob
    PluginJob.configure(self, :telegram)

    private

    def configured?
      Telegram::BotAccess.configured?
    end

    def poll_once
      offset = AppSetting.telegram_update_offset
      updates = Telegram::BotAccess.get_updates(offset: offset, timeout: 25)
      updates.each do |update|
        begin
          process_update(update)
        rescue => e
          Rails.logger.error("#{self.class}: failed to process Telegram update #{update["update_id"]}: #{e}")
        ensure
          AppSetting.current.update!(telegram_update_offset: update["update_id"] + 1)
        end
      end
    end

    def telegram_client = Telegram::BotAccess

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
          message_text: text,
          native_message_id: update["update_id"].to_s,
          conversation_id: message.dig("chat", "id")&.to_s || from["id"].to_s
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
      user = User.find(payload["user_id"])

      identity = PlatformIdentity.find_or_initialize_by(platform: "telegram", external_id: from["id"].to_s)
      identity.assign_attributes(user_id: user.id, external_handle: from["username"], linked_at: Time.current)
      identity.save!

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
end
