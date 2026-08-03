require "rails_helper"

RSpec.describe "API: /api/v1/admin/plugins", type: :request do
  let(:admin) { Factories.user(admin: true) }
  let(:admin_token) { admin.generate_api_token! }

  def auth = { "Authorization" => "Bearer #{admin_token}" }
  def parse_body = JSON.parse(response.body)

  after { Syrus::PluginRegistry.reset! }

  it "401s without a token" do
    get "/api/v1/admin/plugins"

    expect(response).to have_http_status(:unauthorized)
  end

  it "returns registered plugins" do
    admin_token
    Syrus::PluginRegistry.reset!
    Syrus::PluginRegistry.register(
      name: "api-plugin",
      version: "2.0.0",
      provides: { agent_provider: AdminPluginsSpec::AvailableProvider }
    )

    get "/api/v1/admin/plugins", headers: auth

    expect(response).to have_http_status(:ok)
    expect(parse_body.fetch("plugins").sole).to include("name" => "api-plugin", "version" => "2.0.0")
  end
end
