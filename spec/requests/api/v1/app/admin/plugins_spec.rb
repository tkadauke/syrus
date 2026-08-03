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
      version: "1.2.3",
      description: "Adds visible things.",
      homepage: "https://example.test/plugin",
      author: "Ada",
      source: "internal",
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
      "version" => "1.2.3",
      "enabled" => true,
      "description" => "Adds visible things.",
      "homepage" => "https://example.test/plugin",
      "author" => "Ada",
      "source" => "internal"
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
end
