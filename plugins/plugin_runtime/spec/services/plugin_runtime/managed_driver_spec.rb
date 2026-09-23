require "rails_helper"

RSpec.describe PluginRuntime::ManagedDriver do
  # Stands in for the runtime manager. Records what the driver asked for and
  # answers like the real API.
  let(:client) do
    Class.new do
      attr_reader :ensured, :ensured_privileged, :removed
      attr_accessor :running, :refuse, :unavailable

      def initialize
        @ensured = []
        @ensured_privileged = []
        @removed = []
        @running = []
      end

      def ensure_service(name, spec)
        raise PluginRuntime::Client::Unavailable, "connection refused" if unavailable
        raise PluginRuntime::Client::Refused, "image not in the allowlist" if refuse

        @ensured << [ name, spec ]
        { "service" => name, "state" => "running", "endpoint" => "http://#{name}:8080", "image" => spec["image"] }
      end

      def ensure_privileged_service(name, env)
        raise PluginRuntime::Client::Unavailable, "connection refused" if unavailable
        raise PluginRuntime::Client::Refused, "env key not allowed" if refuse

        @ensured_privileged << [ name, env ]
        { "service" => name, "state" => "running", "endpoint" => "http://#{name}:8080", "privileged" => true }
      end

      def list
        raise PluginRuntime::Client::Unavailable, "connection refused" if unavailable

        running.map { |name| { "service" => name } }
      end

      def remove(name, purge: false)
        @removed << [ name, purge ]
      end

      def status(name)
        { "service" => name, "state" => "stopped", "image" => "ghcr.io/tkadauke/x:1" }
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

  def privileged_provider(env = { "TS_AUTHKEY" => "tskey-abc" }, &block)
    Class.new do
      define_singleton_method(:privileged_service_name) { "tailscale" }
      if block
        define_singleton_method(:privileged_env, &block)
      else
        define_singleton_method(:privileged_env) { env }
      end
    end
  end

  def privileged_entry(name = "tailscale", plugin: "tailscale", env: { "TS_AUTHKEY" => "tskey-abc" }, &block)
    PluginRuntime::DesiredPrivilegedServices::Entry.new(name: name, plugin: plugin, provider: privileged_provider(env, &block))
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

  describe "privileged services" do
    it "ensures a privileged entry through the privileged lane, not the generic one" do
      driver.reconcile([], privileged: [ privileged_entry ])

      name, env = client.ensured_privileged.sole
      expect(name).to eq("tailscale")
      expect(env).to eq("TS_AUTHKEY" => "tskey-abc")
      expect(client.ensured).to be_empty
      status = PluginRuntime::StatusCache.read("tailscale")
      expect(status).to be_available
      expect(status.privileged).to be(true)
    end

    it "sends privileged env values as strings" do
      driver.reconcile([], privileged: [ privileged_entry("tailscale", env: { "TS_EXIT_NODE" => true }) ])

      expect(client.ensured_privileged.sole.last).to eq("TS_EXIT_NODE" => "true")
    end

    it "removes a privileged service nobody wants any more" do
      client.running = %w[tailscale]

      driver.reconcile([], privileged: [])

      expect(client.removed).to eq([ [ "tailscale", false ] ])
    end

    it "reports a refusal from the privileged lane instead of retrying silently" do
      client.refuse = true

      driver.reconcile([], privileged: [ privileged_entry ])

      status = PluginRuntime::StatusCache.read("tailscale")
      expect(status.state).to eq("error")
      expect(status.error).to include("refused by the runtime manager", "env key not allowed")
    end

    it "reports an error when the provider's privileged_env raises, without touching other services" do
      broken = privileged_entry { raise "TS_AUTHKEY is not configured" }

      driver.reconcile([ entry("git-mirror") ], privileged: [ broken ])

      expect(client.ensured.map(&:first)).to eq([ "git-mirror" ])
      status = PluginRuntime::StatusCache.read("tailscale")
      expect(status.state).to eq("error")
      expect(status.error).to include("could not build its privileged env", "TS_AUTHKEY is not configured")
    end

    it "ensure_now reaches the privileged lane for a privileged entry" do
      driver.ensure_now(privileged_entry)

      expect(client.ensured_privileged.map(&:first)).to eq([ "tailscale" ])
    end

    describe "held privileged services" do
      before { PluginRecord.find_or_create_by!(name: "plugin_runtime") }

      it "does not ensure a held privileged service, but keeps its status current" do
        PluginRuntime::Holds.hold!("tailscale")

        driver.reconcile([], privileged: [ privileged_entry ])

        expect(client.ensured_privileged).to be_empty
        expect(PluginRuntime::StatusCache.read("tailscale").state).to eq("stopped")
      end
    end
  end

  describe "services an operator stopped" do
    before { PluginRecord.find_or_create_by!(name: "plugin_runtime") }

    # Ensure starts a stopped container, so ensuring a held service would undo
    # the operator's Stop within a minute.
    it "does not ensure a held service, but keeps its status current" do
      PluginRuntime::Holds.hold!("git-mirror")

      driver.reconcile([ entry("git-mirror"), entry("search", plugin: "global_search") ])

      expect(client.ensured.map(&:first)).to eq([ "search" ])
      expect(PluginRuntime::StatusCache.read("git-mirror").state).to eq("stopped")
      expect(client.removed).to be_empty
    end

    it "forgets the hold once no plugin wants the service" do
      PluginRuntime::Holds.hold!("git-mirror")

      driver.reconcile([ entry("search", plugin: "global_search") ])

      expect(PluginRuntime::Holds.all).to be_empty
    end
  end
end
