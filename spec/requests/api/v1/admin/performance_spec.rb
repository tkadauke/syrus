require "rails_helper"

RSpec.describe "API: /api/v1/admin/performance", type: :request do
  let!(:admin) { Factories.user }
  let!(:admin_token) { admin.generate_api_token! }
  let(:cache_store) { ActiveSupport::Cache::MemoryStore.new }

  def auth = { "Authorization" => "Bearer #{admin_token}" }
  def parse_body = JSON.parse(response.body)

  before do
    allow(Rails).to receive(:cache).and_return(cache_store)
    allow(SyrusVersion).to receive(:current).and_return("new-sha")
    Feature.where(slug: "performance_logging").delete_all
    Feature.create!(slug: "performance_logging", category: "Operations", name: "Performance logging", enabled: true)
    PluginRecord.find_by!(name: "syrus_dev").update!(enabled: true)
    Current.reset
    PerformanceLogging::Store.clear!
    PerformanceLogging::Store.append(
      "event" => "syrus.performance.slow_request",
      "method" => "GET",
      "path" => "/dashboard/jobs",
      "controller" => "DashboardController",
      "action" => "show",
      "duration_ms" => 1_500.0,
      "app_revision" => "new-sha",
      "sql_count" => 12,
      "sql_duration_ms" => 300.0,
      "top_sql_fingerprints" => [
        {
          "fingerprint" => "SELECT * FROM jobs WHERE id = ?",
          "sample_sql" => "SELECT * FROM jobs WHERE id = 1",
          "name" => "Job Load",
          "count" => 2,
          "total_duration_ms" => 80.0,
          "max_duration_ms" => 45.0
        }
      ]
    )
  end

  it "401s without a token" do
    get "/api/v1/admin/performance"

    expect(response).to have_http_status(:unauthorized)
  end

  it "returns performance diagnostics for admin API clients" do
    get "/api/v1/admin/performance", headers: auth

    expect(response).to have_http_status(:ok)
    body = parse_body
    expect(body["enabled"]).to eq(true)
    expect(body["current_revision"]).to eq("new-sha")
    expect(body["revision_scope"]).to eq("current")
    expect(body["thresholds"]).to include("slow_request_ms", "slow_sql_ms", "slow_phase_ms")
    expect(body["storage"]).to include("max_events" => PerformanceLogging::Store::MAX_EVENTS)
    expect(body["events"].first).to include("event" => "syrus.performance.slow_request", "path" => "/dashboard/jobs")
    expect(body.dig("summaries", "slow_requests").first).to include(
      "method" => "GET",
      "path" => "/dashboard/jobs",
      "count" => 1,
      "average_sql_count" => 12.0
    )
    expect(body.dig("summaries", "sql_fingerprints").first).to include(
      "fingerprint" => "SELECT * FROM jobs WHERE id = ?",
      "count" => 2,
      "total_duration_ms" => 80.0
    )
  end

  it "explains read-only SQL for admin API clients" do
    post "/api/v1/admin/performance/explain",
      params: { sql: "SELECT * FROM users WHERE id = ?", analyze: false },
      headers: auth,
      as: :json

    expect(response).to have_http_status(:ok)
    body = parse_body
    expect(body).to include(
      "mode" => "explain",
      "normalized_sql" => "SELECT * FROM users WHERE id = NULL",
      "placeholder_substituted" => true
    )
    expect(body["rows"]).to be_present
  end

  it "rejects write SQL for admin API clients" do
    post "/api/v1/admin/performance/explain",
      params: { sql: "UPDATE users SET admin = 1" },
      headers: auth,
      as: :json

    expect(response).to have_http_status(:unprocessable_entity)
    expect(parse_body.dig("error", "code")).to eq("invalid_sql_explain_request")
  end

  it "404s when the Syrus Dev plugin is disabled" do
    PluginRecord.find_by!(name: "syrus_dev").update!(enabled: false)

    get "/api/v1/admin/performance", headers: auth

    expect(response).to have_http_status(:not_found)
    expect(parse_body).to include("error" => "syrus_dev_plugin_disabled")
  end

  it "404s explain requests when the Syrus Dev plugin is disabled" do
    PluginRecord.find_by!(name: "syrus_dev").update!(enabled: false)

    post "/api/v1/admin/performance/explain",
      params: { sql: "SELECT 1" },
      headers: auth,
      as: :json

    expect(response).to have_http_status(:not_found)
    expect(parse_body).to include("error" => "syrus_dev_plugin_disabled")
  end
end
