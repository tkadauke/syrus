require "rails_helper"

RSpec.describe "Spending Insights CLI commands", type: :request do
  let(:user) { Factories.user(admin: true) }

  before do
    Syrus::PluginRegistry.reset!
    Syrus::PluginRegistry.register(default_enabled: true, disableable: true, experimental: false, requires_syrus: nil,
      name: "spending_insights", version: "1.0.0",
      cli_commands: [
        { path: %w[insights spending], summary: "Summarize agent spend", handler: "SpendingInsights::Cli::Spending", flags: [
          { name: "since", type: :string }, { name: "until", type: :string },
          { name: "group-by", type: :string, default: "repo" },
          { name: "json", type: :boolean, default: false }
        ] }
      ]
    )
    PluginRecord.find_by!(name: "spending_insights").update!(enabled: true)
    sign_in_as(user)
  end

  after { Syrus::PluginRegistry.reset! }

  it "returns the same text summary shape as the former Go command" do
    payload = {
      scope: { admin: true, label: "All users" }, filters: { start_date: "2026-01-01", end_date: "2026-01-31" },
      totals: { week_usd: 1.25, month_usd: 2.5, lifetime_usd: 4.0, workflow_lifetime_usd: 3.0, chat_lifetime_usd: 1.0, average_job_30d_usd: 0.5, average_merged_pr_30d_usd: 0.75 },
      breakdowns: { repositories: [ { label: "acme/widgets", jobs_count: 2, total_usd: 2.5, average_job_usd: 1.25 } ], users: [], epics: [], trigger_kinds: [] }
    }
    allow(SpendingInsights::Payload).to receive(:new).and_return(instance_double(SpendingInsights::Payload, as_json: payload))

    post "/api/v1/app/cli_commands/execute", params: { plugin: "spending_insights", path: %w[insights spending], flags: {} }, as: :json

    expect(response).to have_http_status(:ok)
    text = response.parsed_body.dig("result", "text")
    expect(text).to include("Scope: All users (instance-wide)", "Totals", "By repository")
    expect(text).to match(/acme\/widgets\s+2\s+\$2\.50\s+\$1\.25/)
  end

  it "returns the former raw JSON shape for --json" do
    payload = { scope: { admin: true, label: "All users" }, filters: {}, totals: {}, breakdowns: {} }
    allow(SpendingInsights::Payload).to receive(:new).and_return(instance_double(SpendingInsights::Payload, as_json: payload))

    post "/api/v1/app/cli_commands/execute", params: { plugin: "spending_insights", path: %w[insights spending], flags: { json: true } }, as: :json

    expect(JSON.parse(response.parsed_body.dig("result", "text"))).to eq(payload.deep_stringify_keys)
  end

  it "preserves the former group-by aliases" do
    payload = {
      scope: { admin: true, label: "All users" }, filters: { start_date: "2026-01-01", end_date: "2026-01-31" },
      totals: { week_usd: 0, month_usd: 0, lifetime_usd: 0, workflow_lifetime_usd: 0, chat_lifetime_usd: 0, average_job_30d_usd: 0, average_merged_pr_30d_usd: 0 },
      breakdowns: { repositories: [], users: [], epics: [], trigger_kinds: [] }
    }
    allow(SpendingInsights::Payload).to receive(:new).and_return(instance_double(SpendingInsights::Payload, as_json: payload))

    { " Repository " => "By repository", "repositories" => "By repository", "users" => "By user", "epics" => "By epic", "TRIGGER-KIND" => "By trigger kind", "trigger_kinds" => "By trigger kind" }.each do |group, heading|
      post "/api/v1/app/cli_commands/execute", params: { plugin: "spending_insights", path: %w[insights spending], flags: { "group-by" => group } }, as: :json
      expect(response).to have_http_status(:ok), group
      expect(response.parsed_body.dig("result", "text")).to include(heading), group
    end
  end
end
