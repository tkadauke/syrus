require "net/http"
require "json"

module Telegram
  # Thin Telegram Bot API client: one public method per endpoint.
  #
  # The token is a required argument and the client is only ever built inside
  # a brokered call (Telegram::Provider), so it lives for the duration of that
  # call. Telegram puts the token in the request path, which is why nothing
  # here logs or interpolates a URL into an error.
  class Client
    BASE = "https://api.telegram.org"
    class Error < StandardError; end
    class Unauthorized < Error; end

    def initialize(token:)
      @token = token
    end

    # GET /bot{token}/getMe -- the bot's own user. Raises Unauthorized when
    # Telegram rejects the token and Error for anything else, so validation
    # can tell a bad token from an outage.
    def get_me
      uri = URI("#{BASE}/bot#{@token}/getMe")
      response = Net::HTTP.start(uri.host, uri.port, use_ssl: true) { |http| http.get(uri.request_uri) }
      raise Unauthorized, "Telegram rejected the bot token" if [ 401, 404 ].include?(response.code.to_i)

      data = JSON.parse(response.body)
      raise Error, "Telegram getMe failed" unless data["ok"]

      data["result"]
    end

    # GET /bot{token}/getUpdates?offset=N&timeout=T
    # Returns an array of Update objects. Transport and API errors are raised so
    # the polling job can back off before trying again.
    def get_updates(offset:, timeout: 25)
      uri = URI("#{BASE}/bot#{@token}/getUpdates")
      uri.query = URI.encode_www_form(offset: offset, timeout: timeout)
      response = Net::HTTP.start(uri.host, uri.port, use_ssl: true) do |http|
        http.read_timeout = timeout + 10
        http.get(uri.request_uri)
      end
      data = JSON.parse(response.body)
      raise Error, data["description"].presence || "Telegram getUpdates failed" unless data["ok"]

      data["result"]
    end

    # POST /bot{token}/sendMessage
    def send_message(chat_id:, text:, parse_mode: nil)
      uri = URI("#{BASE}/bot#{@token}/sendMessage")
      body = { chat_id: chat_id, text: text }
      body[:parse_mode] = parse_mode if parse_mode
      response = Net::HTTP.start(uri.host, uri.port, use_ssl: true) do |http|
        request = Net::HTTP::Post.new(uri.request_uri, "Content-Type" => "application/json")
        request.body = JSON.generate(body)
        http.request(request)
      end
      JSON.parse(response.body)
    rescue => e
      Rails.logger.error("Telegram::Client#send_message: #{e.class}")
      nil
    end
  end
end
