require "rails_helper"
require Rails.root.join("spec/fixtures/plugin_cli_fixture")

RSpec.describe "API: /api/v1/app/cli_commands", type: :request do
  let(:user) { Factories.user(email_address: "cli@example.com") }

  def register_fixture_plugin(name: "fixture_cli", enabled: true)
    Syrus::PluginRegistry.register(default_enabled: true, disableable: true, experimental: false, requires_syrus: nil,
      name: name, version: "1.0.0",
      cli_commands: [
        { path: %w[fixture greet], summary: "Greet someone", handler: "PluginCliFixture::Handler", arguments: [ { name: "name", type: "string", required: true } ], flags: [ { name: "loud", type: "boolean", default: false } ] },
        { path: %w[fixture table], summary: "Show a table", handler: "PluginCliFixture::TableHandler", flags: [ { name: "active", type: "boolean" } ] },
        { path: %w[fixture json], summary: "Show JSON", handler: "PluginCliFixture::JsonHandler" },
        { path: %w[fixture denied], summary: "Deny access", handler: "PluginCliFixture::UnauthorizedHandler" },
        { path: %w[fixture explode], summary: "Raise an error", handler: "PluginCliFixture::ExplodingHandler" }
      ]
    )
    PluginRecord.find_by!(name: name).update!(enabled: enabled)
  end

  before do
    Syrus::PluginRegistry.reset!
    sign_in_as(user)
  end
  after { Syrus::PluginRegistry.reset! }

  it "requires an authenticated API user" do
    delete session_path

    get "/api/v1/app/cli_commands"

    expect(response).to have_http_status(:unauthorized)
    expect(response.parsed_body.dig("error", "code")).to eq("unauthorized")
  end

  it "lists only enabled plugins in stable order and honors the ETag" do
    register_fixture_plugin(name: "z_enabled")
    register_fixture_plugin(name: "a_disabled", enabled: false)
    get "/api/v1/app/cli_commands"

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.fetch("commands").map { |command| command.fetch("plugin") }.uniq).to eq([ "z_enabled" ])
    paths = response.parsed_body.fetch("commands").map { |command| command.fetch("path") }
    expect(paths).to eq(paths.sort)
    etag = response.headers.fetch("ETag")

    get "/api/v1/app/cli_commands", headers: { "If-None-Match" => etag }
    expect(response).to have_http_status(:not_modified)
  end

  it "executes text, table, and json result handlers as the authenticated user" do
    register_fixture_plugin
    post "/api/v1/app/cli_commands/execute", params: { plugin: "fixture_cli", path: %w[fixture greet], args: [ "Thomas" ], flags: { loud: true } }, as: :json
    expect(response.parsed_body.fetch("result")).to eq("kind" => "text", "text" => "Thomas, cli@example.com!")

    post "/api/v1/app/cli_commands/execute", params: { plugin: "fixture_cli", path: %w[fixture table], flags: { active: true } }, as: :json
    expect(response.parsed_body.fetch("result")).to eq("kind" => "table", "columns" => %w[name active], "rows" => [ [ "cli@example.com", true ] ])

    post "/api/v1/app/cli_commands/execute", params: { plugin: "fixture_cli", path: %w[fixture json], args: [], flags: {} }, as: :json
    expect(response.parsed_body.dig("result", "kind")).to eq("json")
    expect(response.parsed_body.dig("result", "value", "user_id")).to eq(user.id)
  end

  it "returns a structured validation error for invalid arguments" do
    register_fixture_plugin
    post "/api/v1/app/cli_commands/execute", params: { plugin: "fixture_cli", path: %w[fixture greet], args: [] }, as: :json
    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body.dig("error", "code")).to eq("invalid_arguments")
  end

  it "rejects malformed argument and flag containers as invalid arguments" do
    register_fixture_plugin

    [
      { args: { name: "Thomas" } },
      { args: "Thomas" },
      { flags: "loud" },
      { flags: [ "loud" ] }
    ].each do |invalid_input|
      post "/api/v1/app/cli_commands/execute",
           params: { plugin: "fixture_cli", path: %w[fixture greet], args: [ "Thomas" ] }.merge(invalid_input),
           as: :json

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body.dig("error", "code")).to eq("invalid_arguments")
    end
  end
  it "returns forbidden when the handler rejects the user" do
    register_fixture_plugin
    post "/api/v1/app/cli_commands/execute", params: { plugin: "fixture_cli", path: %w[fixture denied] }, as: :json
    expect(response).to have_http_status(:forbidden)
    expect(response.parsed_body.dig("error", "code")).to eq("forbidden")
  end

  it "does not execute commands from disabled plugins" do
    register_fixture_plugin(enabled: false)
    post "/api/v1/app/cli_commands/execute", params: { plugin: "fixture_cli", path: %w[fixture greet], args: [ "Thomas" ] }, as: :json
    expect(response).to have_http_status(:not_found)
    expect(response.parsed_body.dig("error", "code")).to eq("plugin_disabled")
  end

  it "returns a structured error for an unknown plugin" do
    post "/api/v1/app/cli_commands/execute", params: { plugin: "absent", path: %w[fixture greet] }, as: :json

    expect(response).to have_http_status(:not_found)
    expect(response.parsed_body.dig("error", "code")).to eq("plugin_not_found")
  end

  it "turns handler exceptions into translated structured errors" do
    register_fixture_plugin
    allow(Rails.logger).to receive(:error)
    post "/api/v1/app/cli_commands/execute", params: { plugin: "fixture_cli", path: %w[fixture explode] }, as: :json
    expect(response).to have_http_status(:internal_server_error)
    expect(response.parsed_body.dig("error", "code")).to eq("handler_error")
    expect(response.body).not_to include("fixture failure")
  end
end
