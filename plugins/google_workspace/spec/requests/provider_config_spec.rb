require "rails_helper"

RSpec.describe "Google Workspace provider configuration", type: :request do
  let!(:admin) { Factories.user(global_role: "admin") }
  let(:manifest) { Syrus::PluginRegistry.all_plugins.find { |plugin| plugin.name == "google_workspace" } }
  let(:declaration) do
    ConnectedAccounts::ProviderDeclaration.build(plugin_name: manifest.name,
      attributes: manifest.provides.fetch("connected_accounts:provider"))
  end

  before do
    PluginRecord.find_by!(name: "connected_accounts").update!(enabled: true)
    allow(ConnectedAccounts::ProviderRegistry).to receive(:all).and_return([ declaration ])
    sign_in_as(admin)
  end

  it "pins Google configuration while accepting an encrypted client secret" do
    patch "/api/v1/app/admin/connected_accounts/provider_configs/google_workspace", params: {
      provider_config: { client_id: "google-client", client_secret: "google-secret",
        authorize_url: "https://attacker.example/authorize", scope_catalog: [ "calendar.write" ] }
    }, as: :json

    expect(response).to have_http_status(:ok)
    expect(response.media_type).to eq("application/json")
    config = ConnectedAccounts::ProviderConfig.find_by!(provider_key: "google_workspace")
    expect(config).to have_attributes(client_id: "google-client", client_secret: "google-secret",
      authorize_url: "https://accounts.google.com/o/oauth2/v2/auth")
    expect(config.scope_catalog).to eq([ "calendar.read" ])
    expect(response.body).not_to include("google-secret")
  end
end
