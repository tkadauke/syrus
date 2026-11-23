require "rails_helper"

RSpec.describe "Global Search CLI command", type: :request do
  let(:user) { Factories.user }
  let(:results) do
    [
      { type: "job", id: 123, slug: "JOB-123", title: "Fix deploy script", snippet: "<mark>deploy</mark> script", rank: 0, path: "/jobs/123", state: "open", repository_slug: "acme/widgets" },
      { type: "chat", id: 9, title: "General", snippet: "we should <mark>deploy</mark> soon", rank: 1, path: "/chats/1?message_id=9", state: nil, repository_slug: nil }
    ]
  end

  before do
    Syrus::PluginRegistry.reset!
    Syrus::PluginRegistry.register(default_enabled: true, disableable: true, experimental: false, requires_syrus: nil, name: "global_search", version: "1.0.0", cli_commands: [
      { path: %w[search], summary: "Search", handler: "GlobalSearch::Cli::Search", arguments: [ { name: "query", required: true } ], flags: [
        { name: "type" }, { name: "limit", type: :integer }, { name: "json", type: :boolean, default: false }
      ] }
    ])
    PluginRecord.find_by!(name: "global_search").update!(enabled: true)
    sign_in_as(user)
    allow_any_instance_of(GlobalSearch::Cli::Search).to receive(:search).and_return(results: results, filter: {})
  end

  after { Syrus::PluginRegistry.reset! }

  it "returns the former grouped text output shape" do
    post "/api/v1/app/cli_commands/execute", params: { plugin: "global_search", path: %w[search], args: [ "deploy" ], flags: {} }, as: :json

    text = response.parsed_body.dig("result", "text")
    expect(text).to include("JOB (1)", "CHAT (1)")
    expect(text).to match(/JOB-123\s+open\s+Fix deploy script\s+acme\/widgets\s+deploy script/)
    expect(text).to match(/#9\s+-/)
    expect(text).not_to include("<mark>")
  end

  it "returns the former raw JSON response shape for --json" do
    post "/api/v1/app/cli_commands/execute", params: { plugin: "global_search", path: %w[search], args: [ "deploy" ], flags: { json: true } }, as: :json

    expect(JSON.parse(response.parsed_body.dig("result", "text"))).to eq("results" => results.map(&:stringify_keys), "filter" => {})
  end

  it "executes the existing search sources without an internal HTTP call" do
    repository = Factories.repository(user: user, owner: "acme", name: "widgets")
    allow_any_instance_of(GlobalSearch::Cli::Search).to receive(:search).and_call_original

    post "/api/v1/app/cli_commands/execute", params: {
      plugin: "global_search", path: %w[search], args: [ repository.slug ], flags: { type: "repository" }
    }, as: :json

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig("result", "text")).to include("REPOSITORY (1)", repository.slug)
  end
end
