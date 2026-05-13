require "rails_helper"

RSpec.describe "Telegram webhooks", type: :request do
  let(:raw_body) do
    JSON.generate(
      "update_id" => 1,
      "message" => {
        "chat" => { "id" => 123456 },
        "reply_to_message" => { "message_id" => 99 },
        "text" => "Approved."
      }
    )
  end

  def hmac_for(body, token)
    OpenSSL::HMAC.hexdigest("SHA256", Digest::SHA256.digest(token), body)
  end

  before do
    AppSetting.current.update!(telegram_bot_token: "bot-token")
  end

  it "rejects unsigned inbound Telegram updates" do
    post telegram_webhook_path, params: raw_body, headers: { "CONTENT_TYPE" => "application/json" }

    expect(response).to have_http_status(:unauthorized)
  end

  it "accepts a valid HMAC-signed inbound update and dispatches it" do
    allow_any_instance_of(ChatChannel::Telegram).to receive(:receive_update!)

    post telegram_webhook_path,
         params: raw_body,
         headers: {
           "CONTENT_TYPE" => "application/json",
           "X-Telegram-Bot-Api-Signature" => hmac_for(raw_body, "bot-token")
         }

    expect(response).to have_http_status(:ok)
  end

  it "accepts Telegram's Bot API secret-token header when configured" do
    AppSetting.current.update!(telegram_webhook_secret: "webhook-secret")
    allow_any_instance_of(ChatChannel::Telegram).to receive(:receive_update!)

    post telegram_webhook_path,
         params: raw_body,
         headers: {
           "CONTENT_TYPE" => "application/json",
           "X-Telegram-Bot-Api-Secret-Token" => "webhook-secret"
         }

    expect(response).to have_http_status(:ok)
  end
end
