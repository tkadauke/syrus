# frozen_string_literal: true

require "rails_helper"

module PluginCliFixture
  class Handler < Syrus::Plugin::CliCommandHandler
    class << self
      attr_accessor :last_user
    end

    def call(args:, flags:, user:)
      self.class.last_user = user
      raise Pundit::NotAuthorizedError if flags["deny"]
      raise "fixture failure" if flags["explode"]

      send("#{flags.fetch('result', 'text')}_result", args)
    end

    private

    def table_result(args) = Result.table(columns: %w[name], rows: [ [ args.fetch("value") ] ])
    def text_result(args) = Result.text(args.fetch("value"))
    def json_result(args) = Result.json({ message: args.fetch("value") })
  end
end

RSpec.describe "Plugin CLI commands", type: :request do
  def response_body = JSON.parse(response.body)

  let(:user) { Factories.user }
  let(:headers) { { "Authorization" => "Bearer #{user.generate_api_token!}" } }
  let(:command) do
    {
      path: "fixture show", summary: "Show fixture output", handler: "PluginCliFixture::Handler",
      arguments: [ { name: "value", type: "string", required: true } ],
      flags: [
        { name: "result", type: "enum", values: %w[text table json], default: "text" },
        { name: "deny", type: "boolean", default: false },
        { name: "explode", type: "boolean", default: false }
      ]
    }
  end

  before do
    Syrus::PluginRegistry.register(name: "fixture_cli", version: "1.0.0", cli_commands: [ command ])
    Syrus::PluginRegistry.register(name: "disabled_cli", version: "1.0.0", cli_commands: [ command ])
    PluginRecord.find_by!(name: "disabled_cli").update!(enabled: false)
    Syrus::PluginRegistry.clear_plugin_record_cache!
  end

  it "catalogs only enabled plugin commands in stable order and honors ETag" do
    get "/api/v1/app/plugin_cli_commands", headers: headers

    expect(response).to have_http_status(:ok)
    expect(response_body.fetch("commands").map { |entry| entry.fetch("plugin") }).to include("fixture_cli")
    expect(response_body.fetch("commands").map { |entry| entry.fetch("plugin") }).not_to include("disabled_cli")
    expect(response_body.fetch("commands")).to eq(response_body.fetch("commands").sort_by { |entry| [ entry.fetch("plugin"), entry.fetch("path") ] })
    etag = response.headers.fetch("ETag")

    get "/api/v1/app/plugin_cli_commands", headers: headers.merge("If-None-Match" => etag)
    expect(response).to have_http_status(:not_modified)
  end

  %w[text table json].each do |kind|
    it "executes a fixture command returning #{kind}" do
      post "/api/v1/app/plugin_cli_commands/execute", params: {
        plugin: "fixture_cli", path: %w[fixture show], args: { value: "hello" }, flags: { result: kind }
      }, headers: headers, as: :json

      expect(response).to have_http_status(:ok)
      expect(response_body.dig("result", "kind")).to eq(kind)
      expect(PluginCliFixture::Handler.last_user).to eq(user)
    end
  end

  it "returns a structured argument validation error" do
    post "/api/v1/app/plugin_cli_commands/execute", params: { plugin: "fixture_cli", path: "fixture show" }, headers: headers, as: :json

    expect(response).to have_http_status(:unprocessable_content)
    expect(response_body.dig("error", "code")).to eq("invalid_arguments")
  end

  it "returns a structured authorization error from the handler" do
    post "/api/v1/app/plugin_cli_commands/execute", params: {
      plugin: "fixture_cli", path: "fixture show", args: { value: "hello" }, flags: { deny: true }
    }, headers: headers, as: :json

    expect(response).to have_http_status(:forbidden)
    expect(response_body.dig("error", "code")).to eq("forbidden")
  end

  it "rejects a disabled plugin" do
    post "/api/v1/app/plugin_cli_commands/execute", params: {
      plugin: "disabled_cli", path: "fixture show", args: { value: "hello" }
    }, headers: headers, as: :json

    expect(response).to have_http_status(:conflict)
    expect(response_body.dig("error", "code")).to eq("plugin_disabled")
  end

  it "rejects an unknown plugin" do
    post "/api/v1/app/plugin_cli_commands/execute", params: {
      plugin: "missing_cli", path: "fixture show", args: { value: "hello" }
    }, headers: headers, as: :json

    expect(response).to have_http_status(:not_found)
    expect(response_body.dig("error", "code")).to eq("unknown_plugin")
  end

  it "contains handler exceptions behind a structured error" do
    post "/api/v1/app/plugin_cli_commands/execute", params: {
      plugin: "fixture_cli", path: "fixture show", args: { value: "hello" }, flags: { explode: true }
    }, headers: headers, as: :json

    expect(response).to have_http_status(:internal_server_error)
    expect(response_body.dig("error", "code")).to eq("handler_error")
  end
end
