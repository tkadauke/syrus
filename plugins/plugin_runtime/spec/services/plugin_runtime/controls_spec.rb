require "rails_helper"

RSpec.describe PluginRuntime::Controls do
  let(:configuration) { PluginRuntime::Configuration.new("SYRUS_PLUGIN_RUNTIME_URL" => "http://plugin-runtime:8080", "SYRUS_PLUGIN_RUNTIME_TOKEN" => "t" * 32) }
  let(:client) { instance_double(PluginRuntime::Client) }
  let(:controls) { described_class.new(configuration: configuration, client: client) }
  let(:provider) do
    Class.new do
      def self.service_name = "git-mirror"
      def self.service_spec = { image: "ghcr.io/tkadauke/syrus-plugin-git-mirror:1", internal_port: 8080 }
    end
  end
  let(:entry) { PluginRuntime::DesiredServices::Entry.new(name: "git-mirror", plugin: "git_mirror", provider: provider) }

  around do |example|
    original = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    example.run
  ensure
    Rails.cache = original
  end

  before do
    PluginRecord.find_or_create_by!(name: "plugin_runtime")
    allow(PluginRuntime::DesiredServices).to receive(:all).and_return([ entry ])
  end

  def status(state) = { "service" => "git-mirror", "state" => state, "image" => "ghcr.io/tkadauke/syrus-plugin-git-mirror:1" }

  it "stops a service and holds it so reconciling does not start it again" do
    allow(client).to receive(:stop).with("git-mirror").and_return(status("stopped"))

    result = controls.stop!("git-mirror")

    expect(result.state).to eq("stopped")
    expect(PluginRuntime::Holds).to be_held("git-mirror")
    expect(PluginRuntime::StatusCache.read("git-mirror").state).to eq("stopped")
  end

  it "starts a service by releasing the hold and ensuring it right away" do
    PluginRuntime::Holds.hold!("git-mirror")
    allow(client).to receive(:ensure_service).with("git-mirror", hash_including("plugin" => "git_mirror")).and_return(status("running"))

    expect(controls.start!("git-mirror").state).to eq("running")
    expect(PluginRuntime::Holds).not_to be_held("git-mirror")
  end

  it "restarts a service, and ensures it when it has no container" do
    PluginRuntime::Holds.hold!("git-mirror")
    allow(client).to receive(:restart).and_return(status("running"))
    expect(controls.restart!("git-mirror").state).to eq("running")
    expect(PluginRuntime::Holds).not_to be_held("git-mirror")

    allow(client).to receive(:restart).and_raise(PluginRuntime::Client::NotFound)
    allow(client).to receive(:ensure_service).and_return(status("pulling"))
    expect(controls.restart!("git-mirror").state).to eq("pulling")
  end

  it "reads logs with a bounded tail" do
    allow(client).to receive(:logs).with("git-mirror", tail: 5000).and_return("lines")

    expect(controls.logs("git-mirror", tail: 100_000)).to eq("lines")
  end

  it "refuses services no enabled plugin provides" do
    expect { controls.stop!("docker-in-docker") }.to raise_error(described_class::UnknownService)
  end

  # On Kubernetes an operator runs the services; Syrus must not act on them.
  it "refuses every action when services are managed outside Syrus" do
    external = described_class.new(configuration: PluginRuntime::Configuration.new({}), client: client)

    %i[stop! start! restart!].each do |action|
      expect { external.public_send(action, "git-mirror") }.to raise_error(described_class::NotManaged)
    end
  end
end
