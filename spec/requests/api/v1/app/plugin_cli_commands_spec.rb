require "rails_helper"

RSpec.describe "API: plugin CLI commands", type: :request do
  let(:user) { Factories.user(email_address: "cli-commands@example.com") }

  before do
    stub_const("FixtureCliCommand", Class.new do
      include Syrus::Plugin::CliCommand
      class << self
        attr_accessor :result, :failure
      end
      def call(args:, flags:, user:)
        raise self.class.failure if self.class.failure
        self.class.result || Syrus::Plugin::CliCommand::Json.new(value: { args: args, flags: flags, user_id: user.id })
      end
    end)
    register_plugin("fixture_cli", enabled: true)
  end

  after { Syrus::PluginRegistry.reset! }

  def register_plugin(name, enabled:)
    Syrus::PluginRegistry.register(
      name: name, version: "1", default_enabled: enabled,
      cli_commands: [{
        path: "fixture show", summary: "Show the fixture", handler: "FixtureCliCommand",
        arguments: [{ name: "id", type: "integer", required: true }],
        flags: [{ name: "format", type: "enum", values: %w[short long], default: "short" }]
      }]
    )
    PluginRecord.find_by!(name: name).update!(enabled: enabled)
  end

  def body = JSON.parse(response.body)

  it "lists only enabled commands in stable order and honors the ETag" do
    register_plugin("disabled_cli", enabled: false)
    Syrus::PluginRegistry.register(name: "alpha_cli", version: "1", cli_commands: [{ path: "a run", summary: "A", handler: "FixtureCliCommand" }])
    sign_in_as(user)

    get "/api/v1/app/plugin_cli_commands"

    expect(response).to have_http_status(:ok)
    expect(body.fetch("commands").map { |command| command.fetch("plugin") }).to eq(%w[alpha_cli fixture_cli])
    etag = response.headers.fetch("ETag")
    get "/api/v1/app/plugin_cli_commands", headers: { "If-None-Match" => etag }
    expect(response).to have_http_status(:not_modified)
  end

  it "executes table, text, and JSON result handlers" do
    sign_in_as(user)
    results = [
      Syrus::Plugin::CliCommand::Table.new(columns: %w[id], rows: [[1]]),
      Syrus::Plugin::CliCommand::Text.new(text: "done"),
      Syrus::Plugin::CliCommand::Json.new(value: { ok: true })
    ]

    expect(results.map do |result|
      FixtureCliCommand.result = result
      post "/api/v1/app/plugin_cli_commands/execute", params: { plugin: "fixture_cli", path: "fixture show", args: ["1"], flags: {} }
      expect(response).to have_http_status(:ok)
      body.fetch("result").fetch("kind")
    end).to eq(%w[table text json])
  end

  it "validates arguments before invoking the handler" do
    sign_in_as(user)
    post "/api/v1/app/plugin_cli_commands/execute", params: { plugin: "fixture_cli", path: "fixture show", args: ["nope"], flags: {} }
    expect(response).to have_http_status(:unprocessable_content)
    expect(body.dig("error", "code")).to eq("argument_invalid")
  end

  it "returns the handler's authorization failure" do
    FixtureCliCommand.failure = Pundit::NotAuthorizedError.new
    sign_in_as(user)
    post "/api/v1/app/plugin_cli_commands/execute", params: { plugin: "fixture_cli", path: "fixture show", args: ["1"], flags: {} }
    expect(response).to have_http_status(:forbidden)
    expect(body.dig("error", "code")).to eq("forbidden")
  end

  it "rejects a disabled plugin" do
    PluginRecord.find_by!(name: "fixture_cli").update!(enabled: false)
    sign_in_as(user)
    post "/api/v1/app/plugin_cli_commands/execute", params: { plugin: "fixture_cli", path: "fixture show", args: ["1"], flags: {} }
    expect(response).to have_http_status(:unprocessable_content)
    expect(body.dig("error", "code")).to eq("plugin_disabled")
  end

  it "rejects an unknown plugin" do
    sign_in_as(user)
    post "/api/v1/app/plugin_cli_commands/execute", params: { plugin: "missing_cli", path: "fixture show", args: ["1"], flags: {} }
    expect(response).to have_http_status(:unprocessable_content)
    expect(body.dig("error", "code")).to eq("plugin_unknown")
  end

  it "contains handler exceptions" do
    FixtureCliCommand.failure = RuntimeError.new("secret failure")
    sign_in_as(user)
    post "/api/v1/app/plugin_cli_commands/execute", params: { plugin: "fixture_cli", path: "fixture show", args: ["1"], flags: {} }
    expect(response).to have_http_status(:internal_server_error)
    expect(body.dig("error", "code")).to eq("handler_failed")
    expect(response.body).not_to include("secret failure")
  end
end
