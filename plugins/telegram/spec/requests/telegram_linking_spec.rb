require "rails_helper"
require_relative "../support/telegram_bot_account"

RSpec.describe "Telegram account linking", type: :request do
  let(:user) { Factories.user }

  def parse_body = JSON.parse(response.body)

  before { enable_telegram_plugin! }

  it "lists telegram among the available platforms" do
    sign_in_as(user)

    get "/api/v1/app/platform_identities"

    expect(parse_body["available_platforms"].map { |p| p["platform"] }).to include("telegram")
  end

  it "422s when the platform is not configured" do
    sign_in_as(user)

    post "/api/v1/app/platform_identities/linking_token", params: { platform: "telegram" }

    expect(response).to have_http_status(:unprocessable_entity)
    expect(parse_body.dig("error", "code")).to eq("not_configured")
  end

  it "returns a signed token and instructions when configured" do
    sign_in_as(user)
    connect_telegram_bot!
    allow_any_instance_of(Telegram::Client).to receive(:get_me).and_return("username" => "MyBot")

    post "/api/v1/app/platform_identities/linking_token", params: { platform: "telegram" }

    expect(response).to have_http_status(:ok)
    body = parse_body
    verified = Rails.application.message_verifier(:platform_linking).verify(body["token"])
    expect(verified["user_id"]).to eq(user.id)
    expect(verified["platform"]).to eq("telegram")
    expect(body.dig("instructions", "text")).to include("MyBot")
    expect(body.dig("instructions", "bot_handle")).to eq("MyBot")
  end
end
