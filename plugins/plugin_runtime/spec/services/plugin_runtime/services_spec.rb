require "rails_helper"

RSpec.describe PluginRuntime::Services do
  around do |example|
    original = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    example.run
  ensure
    Rails.cache = original
  end

  before { allow(PluginRuntime).to receive(:enabled?).and_return(true) }

  def record(state:, endpoint: "http://git-mirror:8080")
    PluginRuntime::StatusCache.write(
      PluginRuntime::ServiceStatus.build(service: "git-mirror", plugin: "git_mirror", mode: "managed",
                                         state: state, endpoint: endpoint)
    )
  end

  describe ".endpoint_for" do
    it "hands out a running service's address" do
      record(state: "running")

      expect(described_class.endpoint_for("git-mirror")).to eq("http://git-mirror:8080")
    end

    # Pulling, starting and unhealthy all have an address, and none of them
    # can answer. Only a passed health check earns one.
    it "returns nil for a service that has not passed its health check" do
      %w[pulling starting unhealthy stopped error unavailable].each do |state|
        record(state: state)
        expect(described_class.endpoint_for("git-mirror")).to be_nil, "#{state} should not be handed out"
      end
    end

    it "returns nil for a service never reconciled" do
      expect(described_class.endpoint_for("git-mirror")).to be_nil
    end

    # Disabling the runtime has to take effect at once, not when each cached
    # entry happens to expire.
    it "returns nil while the plugin is disabled, even with a fresh healthy status" do
      record(state: "running")
      allow(PluginRuntime).to receive(:enabled?).and_return(false)

      expect(described_class.endpoint_for("git-mirror")).to be_nil
    end

    # The TTL is what makes a dead reconcile loop safe: stale "running"
    # entries expire and callers fall back instead of trusting an address
    # nobody has checked.
    it "stops handing out a service once its status is older than the TTL" do
      record(state: "running")

      travel(PluginRuntime::StatusCache::TTL + 1.second) do
        expect(described_class.endpoint_for("git-mirror")).to be_nil
      end
    end

    # It runs on request paths; it must never reach for the network.
    it "answers without contacting the runtime manager" do
      record(state: "running")
      expect(PluginRuntime::Client).not_to receive(:new)

      described_class.endpoint_for("git-mirror")
    end
  end

  describe ".driver" do
    it "is managed when the manager's address and token are both set" do
      config = PluginRuntime::Configuration.new("SYRUS_PLUGIN_RUNTIME_URL" => "http://plugin-runtime:8080",
                                                 "SYRUS_PLUGIN_RUNTIME_TOKEN" => "t")

      expect(described_class.driver(configuration: config)).to be_a(PluginRuntime::ManagedDriver)
    end

    # A URL without a token is a half-configured Compose install; falling back
    # to external keeps it from sending unauthenticated requests that fail.
    it "is external otherwise, including with a URL but no token" do
      [ {}, { "SYRUS_PLUGIN_RUNTIME_URL" => "http://plugin-runtime:8080" } ].each do |env|
        expect(described_class.driver(configuration: PluginRuntime::Configuration.new(env)))
          .to be_a(PluginRuntime::ExternalDriver)
      end
    end
  end
end
