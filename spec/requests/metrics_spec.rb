require "rails_helper"

RSpec.describe "GET /metrics", type: :request do
  # `let!` on purpose: User promotes the very first account to admin
  # (see User#first_user), so a lazily-created member would silently be one.
  let!(:admin) { Factories.user(global_role: "admin") }
  let(:member) { Factories.user }
  let(:admin_token) { admin.generate_api_token! }
  let(:member_token) { member.generate_api_token! }

  before do
    # Class-level memoization is process-global and would otherwise let one
    # example's refresh satisfy the next one's.
    MetricsController.last_refresh_at = nil
    allow(Metrics::QueueSampler).to receive(:refresh_gauges!).and_return(true)
  end

  it "serves the Prometheus exposition format to an admin token" do
    get "/metrics", headers: { "Authorization" => "Bearer #{admin_token}" }

    expect(response).to have_http_status(:ok)
    # The exposition format version is part of the content type; Prometheus
    # uses it to pick a parser.
    expect(response.headers["Content-Type"]).to eq(Syrus::Metrics::TextFormat::CONTENT_TYPE)
  end

  it "refuses an anonymous request" do
    get "/metrics"

    expect(response).to have_http_status(:unauthorized)
  end

  it "refuses a non-admin token" do
    get "/metrics", headers: { "Authorization" => "Bearer #{member_token}" }

    expect(response).to have_http_status(:forbidden)
  end

  # Deployments that restrict this at the network layer instead (a
  # NetworkPolicy admitting only the Prometheus pod) should not also have to
  # distribute an admin token to their scrape config. Safe to offer precisely
  # because every metric here is an aggregate with bounded labels -- there is
  # nothing identifying to leak.
  it "can be opened up for network-level restriction instead" do
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("SYRUS_METRICS_PUBLIC").and_return("1")

    get "/metrics"

    expect(response).to have_http_status(:ok)
  end

  # The endpoint exists to be scraped during an incident, so it must not fail
  # when the thing it reports on is the thing that is broken.
  it "still serves per-process metrics when the global sample cannot be refreshed" do
    allow(Metrics::QueueSampler).to receive(:refresh_gauges!)
      .and_raise(ActiveRecord::StatementInvalid, "queue database is unreachable")

    get "/metrics", headers: { "Authorization" => "Bearer #{admin_token}" }

    expect(response).to have_http_status(:ok)
  end
end
