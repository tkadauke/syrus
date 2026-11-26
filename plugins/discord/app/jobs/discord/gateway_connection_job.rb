module Discord
  # Inbound half of the Discord platform_delivery provider (registered as
  # Discord::PlatformAdapter.connector_job_class, so PlatformDelivery::Registry
  # .start_connectors! starts/stops it with the plugin's enabled state).
  #
  # Subclassing PlatformPollingJob gets deduplication (at most one live
  # Gateway session, via #duplicate_running?), error logging, and
  # self-re-enqueue for free -- each #poll_once owns exactly one
  # Discord::GatewayClient#run call (one Gateway session's lifetime); when it
  # returns, the base class re-enqueues a fresh job, which opens a
  # fresh connection after a backoff, giving reconnection across worker
  # restarts/deploys the same way Telegram's long-poll loop does.
  class GatewayConnectionJob < Syrus::Host::PlatformPollingJob
    Syrus::Host::PluginJob.configure(self, :discord)
    RECONNECT_BACKOFF_SECONDS = 5
    MAX_RECONNECT_BACKOFF_SECONDS = 5.minutes
    RECONNECT_ATTEMPT_CACHE_KEY = "discord:gateway_connection_job:reconnect_attempts"

    private

    def configured?
      Discord::BotAccess.configured?
    end

    # The bot token is held only inside Discord::Provider for the lifetime of
    # one Gateway session, obtained through the Connected Accounts broker.
    # When the account's credential is rotated or revoked the session ends
    # with :credential_changed; the re-enqueued job then reconnects with the
    # new token, or stops if the account is gone (configured? turns false).
    def poll_once
      @session = Discord::BotAccess.gateway_session(on_event: ->(event) { process_dispatch(event) })

      if @session[:fatal_close_code].present?
        stop_polling_after_fatal_close
      else
        schedule_reconnect
      end
    rescue => e
      Rails.logger.error("Discord::GatewayConnectionJob: #{e}")
      @session = nil
      schedule_reconnect
    end

    def discord_client = Discord::BotAccess

    def continue_polling?
      @continue_polling != false
    end

    def polling_restart_delay
      @polling_restart_delay
    end

    def stop_polling_after_fatal_close
      Rails.cache.delete(RECONNECT_ATTEMPT_CACHE_KEY)
      @continue_polling = false
      Rails.logger.error(
        "Discord::GatewayConnectionJob: Gateway closed with fatal code " \
        "#{@session[:fatal_close_code]}#{": #{@session[:fatal_close_reason]}" if @session[:fatal_close_reason].present?}; " \
        "not re-enqueuing until the connector is re-primed"
      )
    end

    def schedule_reconnect
      @polling_restart_delay = next_reconnect_delay
    end

    def next_reconnect_delay
      if @session&.dig(:run_outcome) == :credential_changed
        Rails.cache.delete(RECONNECT_ATTEMPT_CACHE_KEY)
        return 0
      end

      if @session&.dig(:reset_reconnect_backoff)
        Rails.cache.delete(RECONNECT_ATTEMPT_CACHE_KEY)
        return RECONNECT_BACKOFF_SECONDS
      end

      attempts =
        Rails.cache.read(RECONNECT_ATTEMPT_CACHE_KEY).to_i + 1

      Rails.cache.write(RECONNECT_ATTEMPT_CACHE_KEY, attempts, expires_in: 1.hour)
      [ RECONNECT_BACKOFF_SECONDS * (2 ** (attempts - 1)), MAX_RECONNECT_BACKOFF_SECONDS ].min
    end

    def process_dispatch(event)
      return unless event["t"] == "MESSAGE_CREATE"

      message = event["d"]
      return unless message
      return unless message["guild_id"].nil? # DMs only -- ignore guild channel messages

      author = message["author"] || {}
      return if author["bot"] # ignore bot-authored messages, including our own

      text = message["content"].to_s.strip
      return if text.blank?

      if text.start_with?("/link ")
        handle_linking(token: text.delete_prefix("/link ").strip, author: author)
      else
        route_message(text: text, author: author, message: message)
      end
    end

    def route_message(text:, author:, message:)
      result = Syrus::Host::InboundMessageRouter.new(
        platform: "discord",
        external_id: author["id"].to_s,
        external_handle: author["username"],
        message_text: text,
        native_message_id: message["id"]&.to_s,
        conversation_id: message["channel_id"]&.to_s
      ).call

      return unless result.status == :not_linked

      discord_client.send_dm(
        user_id: author["id"],
        text: "I don't recognize your account. Link it from the Syrus web UI under Settings → Connected Platforms."
      )
    end

    def handle_linking(token:, author:)
      payload = Rails.application.message_verifier(:platform_linking).verify(token)
      user = Syrus::Host::UserRecord.find(payload["user_id"])

      identity = Syrus::Host::PlatformIdentityRecord.find_or_initialize_by(platform: "discord", external_id: author["id"].to_s)
      identity.assign_attributes(user_id: user.id, external_handle: author["username"], linked_at: Time.current)
      identity.save!

      discord_client.send_dm(user_id: author["id"], text: "You're connected! You can now chat with Syrus here.")
    rescue ActiveSupport::MessageVerifier::InvalidSignature
      discord_client.send_dm(
        user_id: author["id"],
        text: "This link has expired or is invalid. Please generate a new one from Syrus → Settings → Connected Platforms."
      )
    end
  end
end
