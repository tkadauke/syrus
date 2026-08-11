require "rails_helper"

RSpec.describe "API: /api/v1/app/platform_identities", type: :request do
  let(:user) { Factories.user }
  let(:other) { Factories.user }

  def parse_body
    JSON.parse(response.body)
  end

  describe "GET /api/v1/app/platform_identities" do
    it "401s when signed out" do
      get "/api/v1/app/platform_identities"
      expect(response).to have_http_status(:unauthorized)
    end

    it "returns the current user's linked identities" do
      sign_in_as(user)
      pi = Factories.platform_identity(user: user, platform: "telegram", external_handle: "@alice")
      Factories.platform_identity(user: other, platform: "telegram", external_handle: "@bob")

      get "/api/v1/app/platform_identities"

      expect(response).to have_http_status(:ok)
      body = parse_body
      expect(body["platform_identities"].length).to eq(1)
      expect(body["platform_identities"].first).to include(
        "id" => pi.id,
        "platform" => "telegram",
        "external_handle" => "@alice"
      )
      expect(body["platform_identities"].first["linked_at"]).to be_present
    end

    it "returns available_platforms with configured status" do
      sign_in_as(user)

      get "/api/v1/app/platform_identities"

      expect(response).to have_http_status(:ok)
      body = parse_body
      expect(body["available_platforms"]).to be_an(Array)
      platforms = body["available_platforms"].map { |p| p["platform"] }
      expect(platforms).to include("telegram", "slack")
    end

    it "returns empty list when user has no linked identities" do
      sign_in_as(user)

      get "/api/v1/app/platform_identities"

      expect(response).to have_http_status(:ok)
      expect(parse_body["platform_identities"]).to eq([])
    end

    context "with a plugin-registered platform" do
      let(:discord_adapter_class) do
        Class.new do
          include Syrus::Plugin::PlatformDelivery
          def self.platform_key = "discord"
          def deliver(message:, platform_identity:) = nil
        end
      end

      around do |ex|
        Syrus::PluginRegistry.reset!
        ex.run
        Syrus::PluginRegistry.reset!
      end

      it "includes the plugin's platform in available_platforms, marked not configured" do
        Syrus::PluginRegistry.register(
          name: "discord_plugin", version: "1.0.0",
          provides: { platform_delivery: discord_adapter_class }
        )
        sign_in_as(user)

        get "/api/v1/app/platform_identities"

        expect(response).to have_http_status(:ok)
        available = parse_body["available_platforms"]
        discord = available.find { |p| p["platform"] == "discord" }
        expect(discord).to include("platform" => "discord", "configured" => false)
      end

      it "excludes the platform when the plugin is disabled" do
        Syrus::PluginRegistry.register(
          name: "discord_plugin", version: "1.0.0", default_enabled: false,
          provides: { platform_delivery: discord_adapter_class }
        )
        sign_in_as(user)

        get "/api/v1/app/platform_identities"

        platforms = parse_body["available_platforms"].map { |p| p["platform"] }
        expect(platforms).not_to include("discord")
      end
    end
  end

  describe "DELETE /api/v1/app/platform_identities/:id" do
    it "401s when signed out" do
      pi = Factories.platform_identity(user: user)
      delete "/api/v1/app/platform_identities/#{pi.id}"
      expect(response).to have_http_status(:unauthorized)
    end

    it "destroys the current user's identity" do
      sign_in_as(user)
      pi = Factories.platform_identity(user: user)

      expect {
        delete "/api/v1/app/platform_identities/#{pi.id}"
      }.to change { user.platform_identities.count }.by(-1)

      expect(response).to have_http_status(:ok)
      body = parse_body
      expect(body["message"]).to eq("Platform account disconnected.")
      expect(body["platform_identities"]).to eq([])
    end

    it "404s when trying to destroy another user's identity" do
      sign_in_as(user)
      other_pi = Factories.platform_identity(user: other)

      expect {
        delete "/api/v1/app/platform_identities/#{other_pi.id}"
      }.not_to change { PlatformIdentity.count }

      expect(response).to have_http_status(:not_found)
    end
  end

  describe "POST /api/v1/app/platform_identities/linking_token" do
    it "401s when signed out" do
      post "/api/v1/app/platform_identities/linking_token", params: { platform: "telegram" }
      expect(response).to have_http_status(:unauthorized)
    end

    it "400s for an unsupported platform" do
      sign_in_as(user)
      post "/api/v1/app/platform_identities/linking_token", params: { platform: "discord" }
      expect(response).to have_http_status(:bad_request)
      expect(parse_body.dig("error", "code")).to eq("bad_request")
    end

    it "422s when the platform is not configured" do
      sign_in_as(user)
      allow(AppSetting).to receive(:telegram_configured?).and_return(false)

      post "/api/v1/app/platform_identities/linking_token", params: { platform: "telegram" }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(parse_body.dig("error", "code")).to eq("not_configured")
    end

    it "returns a signed token and instructions when configured" do
      sign_in_as(user)
      allow(AppSetting).to receive(:telegram_configured?).and_return(true)
      allow(AppSetting).to receive(:telegram_bot_handle).and_return("MyBot")

      post "/api/v1/app/platform_identities/linking_token", params: { platform: "telegram" }

      expect(response).to have_http_status(:ok)
      body = parse_body
      expect(body["token"]).to be_present
      expect(body.dig("instructions", "text")).to include("MyBot")
      expect(body.dig("instructions", "bot_handle")).to eq("MyBot")
    end

    it "issues a verifiable token containing user_id and platform" do
      sign_in_as(user)
      allow(AppSetting).to receive(:telegram_configured?).and_return(true)
      allow(AppSetting).to receive(:telegram_bot_handle).and_return("MyBot")

      post "/api/v1/app/platform_identities/linking_token", params: { platform: "telegram" }

      token = parse_body["token"]
      verified = Rails.application.message_verifier(:platform_linking).verify(token)
      # MessageVerifier serializes via JSON so keys come back as strings
      expect(verified["user_id"]).to eq(user.id)
      expect(verified["platform"]).to eq("telegram")
    end

    context "with a plugin-registered platform" do
      let(:discord_adapter_class) do
        Class.new do
          include Syrus::Plugin::PlatformDelivery
          def self.platform_key = "discord"
          def deliver(message:, platform_identity:) = nil
        end
      end

      around do |ex|
        Syrus::PluginRegistry.reset!
        ex.run
        Syrus::PluginRegistry.reset!
      end

      it "is no longer a bad_request once the plugin is registered, but is not configured" do
        Syrus::PluginRegistry.register(
          name: "discord_plugin", version: "1.0.0",
          provides: { platform_delivery: discord_adapter_class }
        )
        sign_in_as(user)

        post "/api/v1/app/platform_identities/linking_token", params: { platform: "discord" }

        expect(response).to have_http_status(:unprocessable_entity)
        expect(parse_body.dig("error", "code")).to eq("not_configured")
      end
    end
  end
end
