require "net/http"
require "json"

module Discord
  # Thin wrapper around Discord's REST API (bot token auth). Mirrors
  # Telegram::Client's shape: one public method per endpoint, each swallowing
  # and logging its own network errors so callers never need to rescue.
  #
  # The token is a required argument and the client is only ever built inside
  # a brokered call (Discord::Provider), so it lives for the duration of that
  # call. Nothing else should construct one with a long-lived token.
  class Client
    BASE = "https://discord.com/api/v10"

    class Error < StandardError; end
    class Unauthorized < Error; end

    def initialize(token:)
      @token = token
    end

    # GET /users/@me -- the bot's own user. Unlike the delivery methods this
    # raises: Unauthorized when Discord rejects the token, Error for anything
    # else, so account validation can tell a bad token from an outage.
    def current_user
      response = perform(Net::HTTP::Get, "/users/@me", nil)
      code = response.code.to_i
      raise Unauthorized, "Discord rejected the bot token" if [ 401, 403 ].include?(code)
      raise Error, "Discord returned HTTP #{code}" unless code == 200

      JSON.parse(response.body)
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
      JSON.parse(perform(http_method_class, path, body).body)
    end

    def perform(http_method_class, path, body)
      uri = URI("#{BASE}#{path}")
      Net::HTTP.start(uri.host, uri.port, use_ssl: true) do |http|
        req = http_method_class.new(uri.request_uri, "Content-Type" => "application/json", "Authorization" => "Bot #{@token}")
        req.body = JSON.generate(body) if body
        http.request(req)
      end
    end
  end
end
