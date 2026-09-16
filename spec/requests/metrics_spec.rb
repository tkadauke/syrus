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

  # Core cannot hardcode a plugin sampler by name (see CLAUDE.md, "Core specs
  # must not enumerate plugin-provided things"), so this exercises the generic
  # path instead: any registered :callbacks provider gets asked to refresh its
  # own cache-mediated gauges on every scrape.
  describe "plugin metrics refresh" do
    let(:callbacks_provider) { Class.new { include Syrus::Plugin::Callbacks } }

    # Registers alongside the real bundled plugins (restored fresh before
    # every example by spec/support/bundled_plugins.rb) rather than resetting
    # the whole registry, which would also drop the agent-provider plugins
    # `let!(:admin)` above depends on.
    before do
      Syrus::PluginRegistry.register(
        name: "probe_metrics_plugin", version: "1.0.0", provides: { callbacks: callbacks_provider }
      )
    end

    it "calls on_metrics_scrape for every enabled plugin's callbacks provider" do
      allow(callbacks_provider).to receive(:on_metrics_scrape)

      get "/metrics", headers: { "Authorization" => "Bearer #{admin_token}" }

      expect(callbacks_provider).to have_received(:on_metrics_scrape)
    end

    it "does not let one plugin's refresh failure blank the rest of the scrape" do
      allow(callbacks_provider).to receive(:on_metrics_scrape).and_raise(StandardError, "boom")

      get "/metrics", headers: { "Authorization" => "Bearer #{admin_token}" }

      expect(response).to have_http_status(:ok)
    end
  end

  # The acceptance test for "SampleGlobalMetricsJob and MetricsController need
  # zero changes to pick up a new sampler": register a spec-local class the
  # controller has never heard of and prove it gets refreshed on a scrape.
  describe "sampler refresh" do
    it "refreshes any sampler registered with Syrus::Metrics, core or plugin, with no controller change" do
      MetricsController.last_refresh_at = nil
      probe = Class.new do
        class << self
          attr_accessor :refreshed
        end

        def self.refresh_gauges! = self.refreshed = true
      end
      Syrus::Metrics.register_sampler(probe)

      get "/metrics", headers: { "Authorization" => "Bearer #{admin_token}" }

      expect(probe.refreshed).to be(true)
      Syrus::Metrics.unregister_sampler(probe)
    end

    it "does not let one sampler's refresh failure blank the rest of the scrape" do
      MetricsController.last_refresh_at = nil
      failing = Class.new { def self.refresh_gauges! = raise("boom") }
      Syrus::Metrics.register_sampler(failing)

      get "/metrics", headers: { "Authorization" => "Bearer #{admin_token}" }

      expect(response).to have_http_status(:ok)
      Syrus::Metrics.unregister_sampler(failing)
    end
  end
end
