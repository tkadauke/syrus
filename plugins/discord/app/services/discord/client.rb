require "net/http"
require "json"

module Discord
  # Thin wrapper around Discord's REST API (bot token auth). Mirrors
  # TelegramClient's shape: one public method per endpoint, each swallowing
  # and logging its own network errors so callers never need to rescue.
  class Client
    BASE = "https://discord.com/api/v10"

    def initialize(token: AppSetting.discord_bot_token)
      @token = token
    end

    # POST /users/@me/channels -- opens (or reuses) a DM channel with a user.
    # Returns the channel id, or nil on failure.
    def create_dm_channel(user_id)
      response = request(Net::HTTP::Post, "/users/@me/channels", { recipient_id: user_id })
      response && response["id"]
    rescue => e
      Rails.logger.error("Discord::Client#create_dm_channel: #{e}")
      nil
    end

    # POST /channels/{channel.id}/messages
    def send_message(channel_id:, content:)
      request(Net::HTTP::Post, "/channels/#{channel_id}/messages", { content: content })
    rescue => e
      Rails.logger.error("Discord::Client#send_message: #{e}")
      nil
    end

    # Opens/reuses the DM channel for `user_id` then posts `text`. Swallows
    # errors (including a failed channel lookup) and returns nil.
    def send_dm(user_id:, text:)
      channel_id = create_dm_channel(user_id)
      return nil unless channel_id

      send_message(channel_id: channel_id, content: text)
    end

    private

    def request(http_method_class, path, body)
      uri = URI("#{BASE}#{path}")
      response = Net::HTTP.start(uri.host, uri.port, use_ssl: true) do |http|
        req = http_method_class.new(uri.request_uri, "Content-Type" => "application/json", "Authorization" => "Bot #{@token}")
        req.body = JSON.generate(body)
        http.request(req)
      end
      JSON.parse(response.body)
    end
  end
end
