require "rails_helper"

RSpec.describe "API: /api/v1/app/admin/plugins", type: :request do
  let(:admin) { Factories.user(admin: true) }
  let(:non_admin) do
    admin
    Factories.user(admin: false)
  end

  def parse_body = JSON.parse(response.body)

  after do
    Syrus::PluginRegistry.reset!
  end

  it "401s with a JSON error when signed out" do
    get "/api/v1/app/admin/plugins"

    expect(response).to have_http_status(:unauthorized)
    expect(parse_body.dig("error", "code")).to eq("unauthorized")
  end

  it "403s with a JSON error for non-admin users" do
    sign_in_as(non_admin)

    get "/api/v1/app/admin/plugins"

    expect(response).to have_http_status(:forbidden)
    expect(parse_body.dig("error", "code")).to eq("forbidden")
  end

  it "returns registered plugins and their extension points" do
    sign_in_as(admin)
    Syrus::PluginRegistry.reset!
    repository = Factories.repository(user: admin)
    AdminPluginsSpec::CustomInputSource.create!(user: admin, repository: repository)
    Syrus::PluginRegistry.register(
      name: "visibility-plugin",
      display_name: "Visibility",
      version: "1.2.3",
      description: "Adds visible things.",
      homepage: "https://example.test/plugin",
      author: "Ada",
      source: "internal",
      frontend: {
        routes: {
          "visibility/Admin" => "app/frontend/routes/Admin.tsx"
        },
        i18n: [ "app/frontend/i18n/locales/*/visibility.json" ]
      },
      routes: [
        {
          verb: "GET",
          path: "/admin/visibility",
          controller: "visibility/admin#show"
        }
      ],
      provides: {
        agent_provider: AdminPluginsSpec::AvailableProvider,
        input_source: AdminPluginsSpec::CustomInputSource
      }
    )

    get "/api/v1/app/admin/plugins"

    expect(response).to have_http_status(:ok)
    plugin = parse_body.fetch("plugins").sole
    expect(plugin).to include(
      "name" => "visibility-plugin",
      "display_name" => "Visibility",
      "disable_blockers" => [
        {
          "kind" => "configured_input_sources",
          "label" => "Configured input sources use AdminPluginsSpec::CustomInputSource",
          "count" => 1
        }
      ],
      "version" => "1.2.3",
      "enabled" => true,
      "default_enabled" => true,
      "disableable" => true,
      "description" => "Adds visible things.",
      "homepage" => "https://example.test/plugin",
      "author" => "Ada",
      "source" => "internal",
      "frontend" => {
        "routes" => {
          "visibility/Admin" => "app/frontend/routes/Admin.tsx"
        },
        "i18n" => [ "app/frontend/i18n/locales/*/visibility.json" ]
      },
      "routes" => [
        {
          "verb" => "GET",
          "path" => "/admin/visibility",
          "controller" => "visibility/admin#show"
        }
      ]
    )
    expect(plugin.fetch("extension_points")).to contain_exactly(
      include(
        "extension_point" => "agent_provider",
        "class_name" => "AdminPluginsSpec::AvailableProvider",
        "availability" => include("status" => "available", "label" => "Available")
      ),
      include(
        "extension_point" => "input_source",
        "class_name" => "AdminPluginsSpec::CustomInputSource",
        "availability" => include("status" => "configured", "label" => "Configured", "configured_count" => 1)
      )
    )
  end

  it "filters plugins by a full text search query" do
    sign_in_as(admin)
    Syrus::PluginRegistry.reset!
    Syrus::PluginRegistry.register(
      name: "search-target-plugin",
      display_name: "Weather Radar",
      version: "1.0.0",
      description: "Watches storms roll in.",
      category: "monitoring",
      provides: { agent_provider: AdminPluginsSpec::AvailableProvider }
    )
    Syrus::PluginRegistry.register(
      name: "search-other-plugin",
      display_name: "Ticket Sync",
      version: "1.0.0",
      description: "Keeps issues in sync.",
      category: "integration"
    )

    get "/api/v1/app/admin/plugins", params: { q: "storms" }

    expect(response).to have_http_status(:ok)
    expect(parse_body.fetch("plugins").map { |p| p["name"] }).to eq([ "search-target-plugin" ])
  end

  it "returns every plugin when the search query is blank" do
    sign_in_as(admin)
    Syrus::PluginRegistry.reset!
    Syrus::PluginRegistry.register(name: "blank-query-plugin", version: "1.0.0")

    get "/api/v1/app/admin/plugins", params: { q: "" }

    expect(response).to have_http_status(:ok)
    expect(parse_body.fetch("plugins").map { |p| p["name"] }).to eq([ "blank-query-plugin" ])
  end

  it "handles zero plugins gracefully" do
    sign_in_as(admin)
    Syrus::PluginRegistry.reset!

    get "/api/v1/app/admin/plugins"

    expect(response).to have_http_status(:ok)
    expect(parse_body).to eq("plugins" => [])
  end

  it "reflects agent provider availability" do
    sign_in_as(admin)
    Syrus::PluginRegistry.reset!
    Syrus::PluginRegistry.register(
      name: "offline-provider",
      version: "0.1.0",
      provides: { agent_provider: AdminPluginsSpec::UnavailableProvider }
    )

    get "/api/v1/app/admin/plugins"

    extension = parse_body.dig("plugins", 0, "extension_points", 0)
    expect(extension.fetch("availability")).to include("status" => "unavailable", "label" => "Unavailable")
  end

  it "enables and disables an installed disableable plugin live" do
    sign_in_as(admin)
    Syrus::PluginRegistry.reset!
    Syrus::PluginRegistry.register(
      name: "toggle-plugin",
      version: "0.1.0",
      provides: { agent_provider: AdminPluginsSpec::AvailableProvider }
    )

    post "/api/v1/app/admin/plugins/toggle-plugin/disable"

    expect(response).to have_http_status(:ok)
    expect(parse_body.fetch("plugins").sole).to include("name" => "toggle-plugin", "enabled" => false)
    expect(Syrus::PluginRegistry.providers_for(:agent_provider)).to eq([])

    post "/api/v1/app/admin/plugins/toggle-plugin/enable"

    expect(response).to have_http_status(:ok)
    expect(parse_body.fetch("plugins").sole).to include("name" => "toggle-plugin", "enabled" => true)
    expect(Syrus::PluginRegistry.providers_for(:agent_provider)).to eq([ AdminPluginsSpec::AvailableProvider ])
  end

  it "rejects disabling a non-disableable plugin" do
    sign_in_as(admin)
    Syrus::PluginRegistry.reset!
    Syrus::PluginRegistry.register(
      name: "required-plugin",
      version: "0.1.0",
      disableable: false,
      provides: { agent_provider: AdminPluginsSpec::AvailableProvider }
    )

    post "/api/v1/app/admin/plugins/required-plugin/disable"

    expect(response).to have_http_status(:unprocessable_content)
    expect(parse_body.dig("error", "code")).to eq("plugin_not_disableable")
    expect(PluginRecord.find_by!(name: "required-plugin").enabled).to be(true)
  end

  it "rejects disabling a plugin while configured resources use it" do
    sign_in_as(admin)
    Syrus::PluginRegistry.reset!
    Syrus::PluginRegistry.register(
      name: "used-plugin",
      version: "0.1.0",
      provides: { agent_provider: AdminPluginsSpec::AvailableProvider }
    )
    admin.update!(agent_provider: "available")

    get "/api/v1/app/admin/plugins"
    expect(parse_body.dig("plugins", 0, "disable_blockers")).to include(
      include("kind" => "configured_users", "count" => 1)
    )

    post "/api/v1/app/admin/plugins/used-plugin/disable"

    expect(response).to have_http_status(:conflict)
    expect(parse_body.dig("error", "code")).to eq("plugin_in_use")
    expect(PluginRecord.find_by!(name: "used-plugin").enabled).to be(true)
  end

  describe "GET /api/v1/app/admin/plugins/:name/config" do
    it "403s for non-admin users" do
      sign_in_as(non_admin)
      Syrus::PluginRegistry.register(
        name: "config-plugin",
        version: "1.0.0",
        provides: { agent_provider: AdminPluginsSpec::AvailableProvider },
        config_schema: [
          { key: "hostname", label: "Hostname", type: :string }
        ]
      )

      get "/api/v1/app/admin/plugins/config-plugin/config"

      expect(response).to have_http_status(:forbidden)
    end

    it "returns config_schema and current config values" do
      sign_in_as(admin)
      Syrus::PluginRegistry.reset!
      Syrus::PluginRegistry.register(
        name: "schema-plugin",
        version: "1.0.0",
        provides: { agent_provider: AdminPluginsSpec::AvailableProvider },
        config_schema: [
          { key: "hostname", label: "Device Hostname", type: :string, required: false },
          { key: "exit_node", label: "Advertise exit node", type: :boolean, default: false }
        ]
      )

      get "/api/v1/app/admin/plugins/schema-plugin/config"

      expect(response).to have_http_status(:ok)
      body = parse_body
      expect(body["config_schema"]).to contain_exactly(
        { "key" => "hostname", "label" => "Device Hostname", "type" => "string", "required" => false },
        { "key" => "exit_node", "label" => "Advertise exit node", "type" => "boolean", "default" => false }
      )
      expect(body["config"]).to eq("exit_node" => false, "hostname" => nil)
    end

    it "returns { present: bool } for secret_env entries and never the raw value" do
      sign_in_as(admin)
      Syrus::PluginRegistry.reset!
      Syrus::PluginRegistry.register(
        name: "secret-plugin",
        version: "1.0.0",
        provides: { agent_provider: AdminPluginsSpec::AvailableProvider },
        config_schema: [
          { key: "auth_key", label: "Auth Key", type: :secret_env, env_var: "TS_TEST_AUTHKEY",
            required: true, description: "Set in .env — not stored in DB" }
        ]
      )

      previous = ENV["TS_TEST_AUTHKEY"]
      ENV["TS_TEST_AUTHKEY"] = "s3cr3t"
      begin
        get "/api/v1/app/admin/plugins/secret-plugin/config"
      ensure
        previous.nil? ? ENV.delete("TS_TEST_AUTHKEY") : ENV["TS_TEST_AUTHKEY"] = previous
      end

      expect(response).to have_http_status(:ok)
      body = parse_body
      expect(body["config"]["auth_key"]).to eq("present" => true)
      expect(body.to_json).not_to include("s3cr3t")

      get "/api/v1/app/admin/plugins/secret-plugin/config"

      expect(parse_body["config"]["auth_key"]).to eq("present" => false)
    end
  end

  describe "PATCH /api/v1/app/admin/plugins/:name/config" do
    it "403s for non-admin users" do
      sign_in_as(non_admin)
      Syrus::PluginRegistry.register(
        name: "config-plugin",
        version: "1.0.0",
        provides: { agent_provider: AdminPluginsSpec::AvailableProvider },
        config_schema: [
          { key: "hostname", label: "Hostname", type: :string }
        ]
      )

      patch "/api/v1/app/admin/plugins/config-plugin/config", params: { config: { hostname: "myhost" } }

      expect(response).to have_http_status(:forbidden)
    end

    it "persists non-secret config values to PluginRecord#config settings" do
      sign_in_as(admin)
      Syrus::PluginRegistry.reset!
      Syrus::PluginRegistry.register(
        name: "writable-plugin",
        version: "1.0.0",
        provides: { agent_provider: AdminPluginsSpec::AvailableProvider },
        config_schema: [
          { key: "hostname", label: "Hostname", type: :string },
          { key: "exit_node", label: "Exit node", type: :boolean, default: false }
        ]
      )

      patch "/api/v1/app/admin/plugins/writable-plugin/config",
            params: { config: { hostname: "myhost", exit_node: true } }.to_json,
            headers: { "Content-Type" => "application/json" }

      expect(response).to have_http_status(:ok)
      body = parse_body
      expect(body["config"]).to eq("hostname" => "myhost", "exit_node" => true)

      record = PluginRecord.find_by!(name: "writable-plugin")
      expect(record.config["settings"]).to eq("hostname" => "myhost", "exit_node" => true)
    end

    it "ignores secret_env keys and does not persist them" do
      sign_in_as(admin)
      Syrus::PluginRegistry.reset!
      Syrus::PluginRegistry.register(
        name: "secret-write-plugin",
        version: "1.0.0",
        provides: { agent_provider: AdminPluginsSpec::AvailableProvider },
        config_schema: [
          { key: "hostname", label: "Hostname", type: :string },
          { key: "auth_key", label: "Auth Key", type: :secret_env, env_var: "TS_TEST_AUTHKEY" }
        ]
      )

      patch "/api/v1/app/admin/plugins/secret-write-plugin/config",
            params: { config: { hostname: "myhost", auth_key: "should-not-be-stored" } }

      expect(response).to have_http_status(:ok)
      record = PluginRecord.find_by!(name: "secret-write-plugin")
      expect(record.config.to_h["settings"]).not_to have_key("auth_key")
      expect(record.config.to_h["settings"]).to eq("hostname" => "myhost")
    end
  end
end
