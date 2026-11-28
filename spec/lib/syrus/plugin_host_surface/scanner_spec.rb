require "rails_helper"
require "tmpdir"

RSpec.describe Syrus::PluginHostSurface::Scanner do
  def scan(source, public_apis: {})
    Dir.mktmpdir do |directory|
      root = Pathname.new(directory)
      root.join("lib").mkpath
      root.join("lib/fixture.rb").write(source)
      surface = Syrus::PluginHostSurface.new
      apis = public_apis.map do |name, since|
        Syrus::Host::Api.new(name:, since:, summary: "Test API", members: [])
      end
      allow(Syrus::Host).to receive(:apis).and_return(apis)
      allow(Syrus::Host).to receive(:public?) do |name|
        apis.any? { |api| name == api.name || name.start_with?("#{api.name}::") }
      end
      return described_class.new(root, surface:).call
    end
  end

  it "classifies public and non-public core references with locations" do
    result = scan("Syrus::Host::Job.find(1)\nChatBridgeThread.call\nProviderAvailabilityPause.call\n",
      public_apis: { "Syrus::Host::Job" => "0.1.16" })

    expect(result.public.first).to have_attributes(constant: "Syrus::Host::Job", path: "lib/fixture.rb", line: 1)
    expect(result.unlisted).to contain_exactly(
      have_attributes(constant: "ChatBridgeThread", tier: "unlisted", line: 2),
      have_attributes(constant: "ProviderAvailabilityPause", tier: "unlisted", line: 3)
    )
  end

  it "does not count constants in strings or comments" do
    result = scan("# Workflow.call\nmessage = 'AgentInvocation'\n")
    expect(result.findings).to be_empty
  end

  it "reports no references for a plugin using only its own constants" do
    result = scan("module Fixture; class Service; end; Service.call; end\n")
    expect(result.findings).to be_empty
  end

  it "allows plugin interfaces registered through host aliases" do
    api = Syrus::Host.apis.find { |entry| entry.name == "Syrus::Host::PluginApi" }
    result = scan("module Fixture; extend Syrus::PluginApi; end\n", public_apis: { api.name => api.since })

    expect(result.unlisted).to be_empty
    expect(result.public.map(&:constant)).to eq([ "Syrus::PluginApi" ])
  end

  it "allows documented plugin interface modules" do
    result = scan("class Pages; include Syrus::Plugin::AdminPage; end\n")

    expect(result.public.map(&:constant)).to eq([ "Syrus::Plugin::AdminPage" ])
    expect(result.unlisted).to be_empty
  end

  it "derives the newest since version across public APIs" do
    apis = { "Syrus::Host::Job" => "0.1.16", "Syrus::Host::Workflow" => "0.4.2",
             "Syrus::Host::Record" => "0.3.0" }
    source = "include Syrus::Host::Job\nextend ::Syrus::Host::Workflow\nclass Model < Syrus::Host::Record; end\n"
    result = scan(source, public_apis: apis)
    expect(result.minimum_syrus_version).to eq("0.4.2")
  end

  it "resolves host APIs reached through a constant alias" do
    result = scan("HostApi = Syrus::Host\nHostApi::Job.find(1)\n",
      public_apis: { "Syrus::Host::Job" => "0.2.0" })

    expect(result.public.map(&:constant)).to include("Syrus::Host::Job")
    expect(result.minimum_syrus_version).to eq("0.2.0")
  end

  it "warns about dynamic internal core constant references" do
    result = scan("belongs_to :job, class_name: \"Job\"\n\"Workflow\".safe_constantize\n")

    expect(result.dynamic.map(&:constant)).to contain_exactly("Job", "Workflow")
    expect(result).to be_warnings
    expect(result).not_to be_violations
  end

  it "caches scans by the Ruby content hash" do
    Dir.mktmpdir do |directory|
      root = Pathname.new(directory)
      root.join("lib").mkpath
      root.join("lib/fixture.rb").write("Workflow.call\n")
      inventory = instance_double(Admin::PluginHostSurfaceInventory)
      allow(inventory).to receive(:references_for).and_return([])
      allow(inventory).to receive(:string_references_for).and_return([])
      surface = instance_double(Syrus::PluginHostSurface)
      store = ActiveSupport::Cache::MemoryStore.new
      allow(Rails).to receive(:cache).and_return(store)

      2.times { described_class.cached(root, surface:, inventory:) }
      expect(inventory).to have_received(:references_for).once
    end
  end
end
