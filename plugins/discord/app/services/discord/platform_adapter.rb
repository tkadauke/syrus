module Discord
  # Outbound half of the Discord platform_delivery provider: posts assistant
  # chat replies to a linked user's Discord DM channel. See
  # Discord::GatewayConnectionJob for the inbound half (account linking +
  # message routing).
  class PlatformAdapter
    include Syrus::Plugin::PlatformDelivery

    # Discord's message length cap (Telegram's is 4096).
    DISCORD_MAX_CHARS = 2000

    def self.platform_key = "discord"
    def self.connector_job_class = Discord::GatewayConnectionJob

    def deliver(message:, platform_identity:)
      text = extract_text(message.content)
      return if text.blank?

      split_for_discord(text).each do |chunk|
        Discord::Client.new.send_dm(user_id: platform_identity.external_id, text: chunk)
      end
    rescue => e
      Rails.logger.error("Discord::PlatformAdapter#deliver: #{e}")
    end

    private

    def extract_text(content)
      return content.to_s if content.is_a?(String)
      return "" unless content.is_a?(Hash)
      content["text"].to_s
    end

    def split_for_discord(text)
      return [text] if text.length <= DISCORD_MAX_CHARS

      chunks = []
      remaining = text
      while remaining.length > DISCORD_MAX_CHARS
        chunk = remaining[0, DISCORD_MAX_CHARS]
        split_at = chunk.rindex("\n") || DISCORD_MAX_CHARS
        chunks << remaining[0, split_at]
        remaining = remaining[split_at..].lstrip
      end
      chunks << remaining unless remaining.empty?
      chunks
    end
  end
end
