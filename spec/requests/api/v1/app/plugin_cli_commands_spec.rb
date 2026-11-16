require "rails_helper"

module CliCommandFixture
  class Handler
    include Syrus::Plugin::CliCommand

    def call(args:, flags:, user:)
      raise Pundit::NotAuthorizedError unless user.admin? || flags["public"]

      case flags["result"]
      when "table"
        Syrus::Plugin::CliCommand::Result.table(columns: [ "name", "count" ], rows: [ [ args["name"], flags["count"] ] ])
      when "json"
        Syrus::Plugin::CliCommand::Result.json(value: { name: args["name"], tags: flags["tag"] })
      else
        Syrus::Plugin::CliCommand::Result.text(text: "Hello #{args.fetch('name')}")
      end
    end
  end

  class FailingHandler
    include Syrus::Plugin::CliCommand

    def call(**) = raise("fixture handler exploded")
  end
end

RSpec.describe "Plugin CLI commands", :reset_plugin_registry, type: :request do
  let!(:admin) { Factories.user(global_role: "admin") }
  let(:member) { Factories.user(global_role: "user") }
  let(:headers) { { "Authorization" => "Bearer #{admin.generate_api_token!}" } }

  before do
    definition = Syrus::PluginApi::Definition.new(
      name: "cli_fixture", namespace: CliCommandFixture, lib_dir: __dir__
    )
    definition.cli_command(
      "fixture show",
      summary: "Show fixture data",
      handler: "CliCommandFixture::Handler",
      arguments: [ { name: "name", type: "string", required: true } ],
      flags: [
        { name: "result", type: "enum", values: %w[text table json], default: "text" },
        { name: "count", type: "integer", default: 1 },
        { name: "tag", type: "repeatable_string", default: [] },
        { name: "public", type: "boolean", default: false }
      ]
    )
    definition.cli_command(
      "fixture fail", summary: "Fail deliberately", handler: "CliCommandFixture::FailingHandler"
    )
    Syrus::PluginRegistry.register(**definition.manifest_arguments)
  end

  it "lists enabled plugin commands in stable order and honors ETag" do
    get "/api/v1/app/cli/commands", headers: headers

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.fetch("commands").pluck("path")).to eq([ "fixture fail", "fixture show" ])
    expect(response.parsed_body.dig("commands", 1)).not_to have_key("handler")

    get "/api/v1/app/cli/commands", headers: headers.merge("If-None-Match" => response.headers.fetch("ETag"))
    expect(response).to have_http_status(:not_modified)
  end

  it "allows an authenticated non-admin to discover commands" do
    member_headers = { "Authorization" => "Bearer #{member.generate_api_token!}" }

    get "/api/v1/app/cli/commands", headers: member_headers

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.fetch("commands").pluck("path")).to eq([ "fixture fail", "fixture show" ])
  end

  it "omits disabled plugins from the catalog" do
    PluginRecord.find_by!(name: "cli_fixture").update!(enabled: false)
    Syrus::PluginRegistry.clear_plugin_record_cache!

    get "/api/v1/app/cli/commands", headers: headers
    expect(response.parsed_body.fetch("commands")).to be_empty
  end

  it "executes text, table, and json result kinds" do
    expectations = {
      "text" => { "kind" => "text", "text" => "Hello Ada" },
      "table" => { "kind" => "table", "columns" => [ "name", "count" ], "rows" => [ [ "Ada", 2 ] ] },
      "json" => { "kind" => "json", "value" => { "name" => "Ada", "tags" => %w[a b] } }
    }

    expectations.each do |kind, expected|
      post "/api/v1/app/cli/commands/execute", headers: headers, params: {
        plugin: "cli_fixture", path: %w[fixture show], args: { name: "Ada" },
        flags: { result: kind, count: "2", tag: %w[a b] }
      }
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.fetch("result")).to eq(expected)
    end
  end

  it "returns a translated structured argument validation error" do
    post "/api/v1/app/cli/commands/execute", headers: headers, params: {
      plugin: "cli_fixture", path: "fixture show", args: {}, flags: { count: "many" }
    }

    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body.dig("error", "code")).to eq("invalid_arguments")
    expect(response.parsed_body.dig("error", "message")).to include("name is required")
  end

  it "rejects non-object arguments as an argument validation error" do
    post "/api/v1/app/cli/commands/execute", headers: headers, params: {
      plugin: "cli_fixture", path: "fixture show", args: "not-an-object"
    }

    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body.dig("error", "code")).to eq("invalid_arguments")
    expect(response.parsed_body.dig("error", "message")).to include("args and flags must be objects")
  end

  it "rejects arrays of pairs for arguments and flags instead of coercing them to objects" do
    [
      { args: [ [ "name", "Ada" ] ], flags: {} },
      { args: { name: "Ada" }, flags: [ [ "public", true ] ] }
    ].each do |values|
      post "/api/v1/app/cli/commands/execute", headers: headers, as: :json, params: {
        plugin: "cli_fixture", path: "fixture show", **values
      }

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body.dig("error", "code")).to eq("invalid_arguments")
      expect(response.parsed_body.dig("error", "message")).to include("args and flags must be objects")
    end
  end

  it "preserves handler authorization as a forbidden response" do
    member_headers = { "Authorization" => "Bearer #{member.generate_api_token!}" }
    post "/api/v1/app/cli/commands/execute", headers: member_headers, params: {
      plugin: "cli_fixture", path: "fixture show", args: { name: "Ada" }
    }

    expect(response).to have_http_status(:forbidden)
    expect(response.parsed_body.dig("error", "code")).to eq("forbidden")
  end

  it "rejects execution for a disabled plugin" do
    PluginRecord.find_by!(name: "cli_fixture").update!(enabled: false)
    Syrus::PluginRegistry.clear_plugin_record_cache!

    post "/api/v1/app/cli/commands/execute", headers: headers, params: {
      plugin: "cli_fixture", path: "fixture show", args: { name: "Ada" }
    }
    expect(response).to have_http_status(:not_found)
    expect(response.parsed_body.dig("error", "code")).to eq("disabled_plugin")
  end

  it "reports an unhealthy plugin as unavailable" do
    Syrus::PluginRegistry.register(
      name: "cli_fixture",
      version: "1.0.0",
      cli_commands: [ { path: "fixture show", summary: "Show fixture data" } ]
    )

    post "/api/v1/app/cli/commands/execute", headers: headers, params: {
      plugin: "cli_fixture", path: "fixture show", args: { name: "Ada" }
    }

    expect(response).to have_http_status(:service_unavailable)
    expect(response.parsed_body.dig("error", "code")).to eq("unavailable_plugin")
  end

  it "contains handler exceptions behind a structured error" do
    allow(Rails.error).to receive(:report)
    post "/api/v1/app/cli/commands/execute", headers: headers, params: {
      plugin: "cli_fixture", path: "fixture fail"
    }

    expect(response).to have_http_status(:internal_server_error)
    expect(response.parsed_body.dig("error", "code")).to eq("handler_error")
  end
end
