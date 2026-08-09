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

  it "toggles installed plugins through the token admin API" do
    admin_token
    Syrus::PluginRegistry.reset!
    Syrus::PluginRegistry.register(
      name: "api-toggle-plugin",
      version: "2.0.0",
      provides: { agent_provider: AdminPluginsSpec::AvailableProvider }
    )

    post "/api/v1/admin/plugins/api-toggle-plugin/disable", headers: auth

    expect(response).to have_http_status(:ok)
    expect(parse_body.fetch("plugins").sole).to include("name" => "api-toggle-plugin", "enabled" => false)
  end

  it "rejects disabling a plugin through the token admin API while it is in use" do
    admin_token
    Syrus::PluginRegistry.reset!
    Syrus::PluginRegistry.register(
      name: "api-used-plugin",
      version: "2.0.0",
      provides: { agent_provider: AdminPluginsSpec::AvailableProvider }
    )
    admin.update!(agent_provider: "available")

    post "/api/v1/admin/plugins/api-used-plugin/disable", headers: auth

    expect(response).to have_http_status(:conflict)
    expect(parse_body.dig("error", "code")).to eq("plugin_in_use")
  end

  it "401s GET config without a token" do
    Syrus::PluginRegistry.register(
      name: "api-config-plugin",
      version: "1.0.0",
      provides: { agent_provider: AdminPluginsSpec::AvailableProvider },
      config_schema: [ { key: "hostname", label: "Hostname", type: :string } ]
    )

    get "/api/v1/admin/plugins/api-config-plugin/config"

    expect(response).to have_http_status(:unauthorized)
  end

  it "returns config_schema and current config via bearer token" do
    admin_token
    Syrus::PluginRegistry.reset!
    Syrus::PluginRegistry.register(
      name: "api-schema-plugin",
      version: "1.0.0",
      provides: { agent_provider: AdminPluginsSpec::AvailableProvider },
      config_schema: [
        { key: "hostname", label: "Hostname", type: :string },
        { key: "auth_key", label: "Auth Key", type: :secret_env, env_var: "TS_TEST_AUTHKEY" }
      ]
    )

    get "/api/v1/admin/plugins/api-schema-plugin/config", headers: auth

    expect(response).to have_http_status(:ok)
    body = parse_body
    expect(body["config_schema"]).to contain_exactly(
      include("key" => "hostname", "type" => "string"),
      include("key" => "auth_key", "type" => "secret_env")
    )
    expect(body["config"]["auth_key"]).to eq("present" => false)
    expect(body["config"]["hostname"]).to be_nil
  end

  it "persists non-secret config values via PATCH and ignores secret keys" do
    admin_token
    Syrus::PluginRegistry.reset!
    Syrus::PluginRegistry.register(
      name: "api-writable-plugin",
      version: "1.0.0",
      provides: { agent_provider: AdminPluginsSpec::AvailableProvider },
      config_schema: [
        { key: "hostname", label: "Hostname", type: :string },
        { key: "auth_key", label: "Auth Key", type: :secret_env, env_var: "TS_TEST_AUTHKEY" }
      ]
    )

    patch "/api/v1/admin/plugins/api-writable-plugin/config",
          headers: auth,
          params: { config: { hostname: "myhost", auth_key: "should-not-be-stored" } }

    expect(response).to have_http_status(:ok)
    body = parse_body
    expect(body["config"]["hostname"]).to eq("myhost")
    record = PluginRecord.find_by!(name: "api-writable-plugin")
    expect(record.config.to_h["settings"]).to eq("hostname" => "myhost")
    expect(record.config.to_h["settings"]).not_to have_key("auth_key")
  end
end
