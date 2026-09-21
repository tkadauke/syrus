require "rails_helper"

RSpec.describe PluginRuntime::ExternalDriver do
  around do |example|
    original = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    example.run
  ensure
    Rails.cache = original
  end

  let(:provider) do
    Class.new do
      def self.service_name = "git-mirror"
      def self.service_spec = { image: "ghcr.io/tkadauke/x:1", internal_port: 8080, healthcheck: { path: "/healthz" } }
    end
  end
  let(:entry) { PluginRuntime::DesiredServices::Entry.new(name: "git-mirror", plugin: "git_mirror", provider: provider) }

  def driver(env, probe: ->(_url) { nil })
    described_class.new(configuration: PluginRuntime::Configuration.new(env), probe: probe)
  end

  # On Kubernetes nothing is started for the operator; an unset address has to
  # say exactly which variable to set.
  it "reports an unconfigured service with the variable that would fix it" do
    driver({}).reconcile([ entry ])

    status = PluginRuntime::StatusCache.read("git-mirror")
    expect(status.state).to eq("unconfigured")
    expect(status.error).to include("SYRUS_PLUGIN_SERVICE_GIT_MIRROR_URL")
    expect(status).not_to be_available
  end

  it "hands out a configured service that passes its health check" do
    probed = []
    driver({ "SYRUS_PLUGIN_SERVICE_GIT_MIRROR_URL" => "http://git-mirror.syrus:8080/" },
           probe: ->(url) { probed << url; nil }).reconcile([ entry ])

    status = PluginRuntime::StatusCache.read("git-mirror")
    expect(probed).to eq([ "http://git-mirror.syrus:8080/healthz" ])
    expect(status).to be_available
    expect(status.endpoint).to eq("http://git-mirror.syrus:8080")
    expect(status.mode).to eq("external")
  end

  # Configured is not the same as working. A down service must degrade to the
  # caller's fallback, not fail every request that tries it.
  it "withholds a configured service that fails its health check" do
    driver({ "SYRUS_PLUGIN_SERVICE_GIT_MIRROR_URL" => "http://git-mirror.syrus:8080" },
           probe: ->(_url) { "health check returned 503" }).reconcile([ entry ])

    status = PluginRuntime::StatusCache.read("git-mirror")
    expect(status.state).to eq("unhealthy")
    expect(status).not_to be_available
  end
end
