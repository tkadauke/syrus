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
        allow_as_owner: true,
        scope_catalog: %w[profile calendar.write],
        read_only_scopes: %w[profile],
        api_origins: [ "https://api.example/" ]
      }
    }, as: :json

    expect(response).to have_http_status(:ok)
    expect(response.media_type).to eq("application/json")
    expect(response.parsed_body.dig("provider_config", "authorize_url")).to eq("https://oauth.example/authorize")
    expect(response.parsed_body.dig("provider_config", "read_only_scopes")).to eq([ "profile" ])
    expect(response.parsed_body.dig("provider_config", "client_secret_configured")).to be(true)
    expect(response.parsed_body.dig("provider_config", "allow_as_owner")).to be(true)

    get "/api/v1/app/admin/connected_accounts/provider_config"

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig("provider_config", "read_only_scopes")).to eq([ "profile" ])
  end

  it "lists configurable providers with their provider-owned settings metadata" do
    declaration = ConnectedAccounts::ProviderDeclaration.build(plugin_name: "example_plugin", attributes: {
      provider: "ConnectedAccounts::FakeProvider", key: "example", display_name: "Example",
      capabilities: ConnectedAccounts::Provider::REQUIRED_CAPABILITIES,
      callback_route: "/api/v1/app/connected_accounts/callback/example", supports_read_only: true,
      settings_notice: "Configure Example with your own client.",
      settings_notice_i18n_key: "example:settings.provider_notice",
      scopes: [ { key: "profile", label: "Read profile", risk: "low", read_only: true,
        syrus_capabilities: [ "profile.read@v1" ] } ]
    })
    allow(ConnectedAccounts::ProviderRegistry).to receive(:all).and_return([ declaration ])

    get "/api/v1/app/admin/connected_accounts/provider_configs"

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.fetch("providers")).to contain_exactly(include(
      "provider_key" => "example", "display_name" => "Example",
      "settings_notice" => "Configure Example with your own client.",
      "settings_notice_i18n_key" => "example:settings.provider_notice"
    ))
  end
end
