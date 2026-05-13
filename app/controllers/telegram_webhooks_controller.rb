class TelegramWebhooksController < ActionController::Base
  protect_from_forgery with: :null_session

  def create
    raw_body = request.raw_post
    unless ChatChannel::TelegramWebhookVerifier.valid?(raw_body: raw_body, headers: request.headers)
      head :unauthorized
      return
    end

    payload = JSON.parse(raw_body)
    ChatChannel::Telegram.new.receive_update!(payload)
    head :ok
  rescue JSON::ParserError
    head :bad_request
  end
end
