require "rails_helper"

RSpec.describe PluginRuntime::ManagedDriver do
  # Stands in for the runtime manager. Records what the driver asked for and
  # answers like the real API.
  let(:client) do
    Class.new do
      attr_reader :ensured, :removed
      attr_accessor :running, :refuse, :unavailable

      def initialize
        @ensured = []
        @removed = []
        @running = []
      end

      def ensure_service(name, spec)
        raise PluginRuntime::Client::Unavailable, "connection refused" if unavailable
        raise PluginRuntime::Client::Refused, "image not in the allowlist" if refuse

        @ensured << [ name, spec ]
        { "service" => name, "state" => "running", "endpoint" => "http://#{name}:8080", "image" => spec["image"] }
      end

      def list
        raise PluginRuntime::Client::Unavailable, "connection refused" if unavailable

        running.map { |name| { "service" => name } }
      end

      def remove(name, purge: false)
        @removed << [ name, purge ]
      end
    end.new
  end

  let(:driver) { described_class.new(client: client) }

  around do |example|
    original = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    example.run
  ensure
    Rails.cache = original
  end

  def provider(name, spec = nil, &block)
    spec ||= { image: "ghcr.io/tkadauke/syrus-plugin-#{name}:abc", internal_port: 8080, env: { "PORT" => 8080 } }
    Class.new do
      define_singleton_method(:service_name) { name }
      if block
        define_singleton_method(:service_spec, &block)
      else
        define_singleton_method(:service_spec) { spec }
      end
    end
  end

  def entry(name, plugin: "git_mirror", &block)
    PluginRuntime::DesiredServices::Entry.new(name: name, plugin: plugin, provider: provider(name, &block))
  end

  it "ensures each desired service with its owning plugin and records the result" do
    driver.reconcile([ entry("git-mirror") ])

    name, spec = client.ensured.sole
    expect(name).to eq("git-mirror")
    expect(spec["plugin"]).to eq("git_mirror")
    expect(PluginRuntime::StatusCache.read("git-mirror")).to be_available
  end

  # The manager's env is map[string]string; a non-string value would be a 400
  # for a reason no plugin author would guess.
  it "sends env values as strings" do
    driver.reconcile([ entry("git-mirror") ])

    expect(client.ensured.sole.last["env"]).to eq("PORT" => "8080")
  end

  # Disabling a plugin drops its service from the desired set; this is what
  # actually stops the container.
  it "removes managed services nobody wants any more, keeping their volumes" do
    client.running = %w[git-mirror old-service]

    driver.reconcile([ entry("git-mirror") ])

    expect(client.removed).to eq([ [ "old-service", false ] ])
  end

  # A blip reaching the manager must not be read as "nothing is running, so
  # nothing is wanted" -- or worse, as licence to remove things.
  it "removes nothing and marks services unavailable when the manager cannot be reached" do
    client.running = %w[git-mirror other]
    client.unavailable = true

    driver.reconcile([ entry("git-mirror") ])

    expect(client.removed).to be_empty
    status = PluginRuntime::StatusCache.read("git-mirror")
    expect(status.state).to eq("unavailable")
    expect(status).not_to be_available
  end

  # A contributor whose spec raises is broken, but its running container is
  # still wanted. Tearing it down would turn a config typo into an outage.
  it "keeps a service whose spec failed to build, and reports why" do
    client.running = %w[git-mirror]
    broken = entry("git-mirror") { raise KeyError, "GIT_MIRROR_SECRET" }

    driver.reconcile([ broken ])

    expect(client.removed).to be_empty
    status = PluginRuntime::StatusCache.read("git-mirror")
    expect(status.state).to eq("error")
    expect(status.error).to include("could not build its service spec", "GIT_MIRROR_SECRET")
  end

  it "reports a policy refusal on the service instead of retrying silently" do
    client.refuse = true

    driver.reconcile([ entry("git-mirror") ])

    status = PluginRuntime::StatusCache.read("git-mirror")
    expect(status.state).to eq("error")
    expect(status.error).to include("refused by the runtime manager", "allowlist")
  end

  it "reconciles the other services when one of them fails" do
    driver.reconcile([ entry("broken") { raise "boom" }, entry("git-mirror") ])

    expect(client.ensured.map(&:first)).to eq([ "git-mirror" ])
  end
end
