require "rails_helper"

RSpec.describe "Connected accounts provider configuration", type: :request do
  let!(:admin) { Factories.user(global_role: "admin") }

  before do
    PluginRecord.find_by!(name: "connected_accounts").update!(enabled: true)
    sign_in_as(admin)
  end

  it "saves a valid generic OAuth provider configuration" do
    patch "/api/v1/app/admin/connected_accounts/provider_config", params: {
      provider_config: {
        authorize_url: "https://oauth.example/authorize",
        token_url: "https://oauth.example/token",
        revoke_url: "https://oauth.example/revoke",
        identity_url: "https://api.example/me",
        validate_url: "https://api.example/health",
        client_id: "client-id",
        client_secret: "client-secret",
        scope_catalog: %w[profile calendar.write],
        read_only_scopes: %w[profile],
        api_origins: [ "https://api.example/" ]
      }
    }, as: :json

    expect(response).to have_http_status(:ok)
    expect(response.media_type).to eq("application/json")
    expect(response.parsed_body.dig("provider_config", "authorize_url")).to eq("https://oauth.example/authorize")
    expect(response.parsed_body.dig("provider_config", "client_secret_configured")).to be(true)
  end
end
