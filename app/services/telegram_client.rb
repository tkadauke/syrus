require "net/http"
require "json"

class TelegramClient
  BASE = "https://api.telegram.org"
  class Error < StandardError; end

  def initialize(token: AppSetting.telegram_bot_token)
    @token = token
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
    Rails.logger.error("TelegramClient#send_message: #{e}")
    nil
  end
end
