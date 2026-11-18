require "rails_helper"
require "tmpdir"

RSpec.describe Syrus::PluginHostSurface::Scanner do
  def scan(source, public_apis: [], legacy_entries: {})
    Dir.mktmpdir do |directory|
      root = Pathname.new(directory)
      root.join("lib").mkpath
      root.join("lib/fixture.rb").write(source)
      surface = instance_double(Syrus::PluginHostSurface)
      allow(surface).to receive(:lookup) { |name| legacy_entries[name] }
      return described_class.new(root, surface:, apis: public_apis).call
    end
  end

  def api(name, since:)
    Syrus::Host::Api.new(name:, since:, summary: "Fixture API.", members: [])
  end

  it "classifies public, legacy, and unlisted core references with locations" do
    public_apis = [ api("Syrus::PluginApi", since: "0.1.16") ]
    legacy_entries = { "AgentRole" => Syrus::PluginHostSurface::Entry.new(name: "AgentRole") }
    result = scan("Syrus::PluginApi.enabled?\nAgentRole.call\nWorkflow.call\n", public_apis:, legacy_entries:)

    expect(result.public.first).to have_attributes(constant: "Syrus::PluginApi", path: "lib/fixture.rb", line: 1)
    expect(result.legacy.first).to have_attributes(constant: "AgentRole", line: 2)
    expect(result.unlisted.first).to have_attributes(constant: "Workflow", line: 3)
  end

  it "does not count constants in strings or comments" do
    result = scan("# Workflow.call\nmessage = 'AgentInvocation'\n")
    expect(result.findings).to be_empty
  end

  it "reports no references for a plugin using only its own constants" do
    result = scan("module Fixture; class Service; end; Service.call; end\n")
    expect(result.findings).to be_empty
  end

  it "derives the newest since version across public APIs" do
    public_apis = [
      api("Syrus::PluginApi", since: "0.1.16"),
      api("Syrus::Plugin::AgentProvider", since: "0.4.2")
    ]
    result = scan("Syrus::PluginApi.enabled?\nSyrus::Plugin::AgentProvider.call\n", public_apis:)
    expect(result.minimum_syrus_version).to eq("0.4.2")
  end

  it "reuses a scan when Ruby content and host contracts are unchanged" do
    Dir.mktmpdir do |directory|
      root = Pathname.new(directory)
      root.join("lib").mkpath
      root.join("lib/fixture.rb").write("Workflow.call\n")
      inventory = instance_double(Admin::PluginHostSurfaceInventory)
      allow(inventory).to receive(:references_for).and_return([])
      surface = instance_double(Syrus::PluginHostSurface)
      allow(surface).to receive(:entries).and_return([])
      store = ActiveSupport::Cache::MemoryStore.new
      allow(Rails).to receive(:cache).and_return(store)

      2.times { described_class.cached(root, surface:, inventory:) }
      expect(inventory).to have_received(:references_for).once
    end
  end

  it "invalidates the cache when public API declarations change" do
    with_cached_reference("Syrus::PluginApi") do |root, inventory, surface|
      first = described_class.cached(root, surface:, inventory:, apis: [])
      second = described_class.cached(root, surface:, inventory:, apis: [ api("Syrus::PluginApi", since: "0.2.0") ])

      expect(first.unlisted.map(&:constant)).to eq([ "Syrus::PluginApi" ])
      expect(second.public.map(&:constant)).to eq([ "Syrus::PluginApi" ])
      expect(second.minimum_syrus_version).to eq("0.2.0")
      expect(inventory).to have_received(:references_for).twice
    end
  end

  it "invalidates the cache when the legacy surface changes" do
    with_cached_reference("Workflow") do |root, inventory, surface|
      allow(surface).to receive(:entries).and_return([], [ Syrus::PluginHostSurface::Entry.new(name: "Workflow") ])
      allow(surface).to receive(:lookup).with("Workflow").and_return(nil, Syrus::PluginHostSurface::Entry.new(name: "Workflow"))

      first = described_class.cached(root, surface:, inventory:, apis: [])
      second = described_class.cached(root, surface:, inventory:, apis: [])

      expect(first.unlisted.map(&:constant)).to eq([ "Workflow" ])
      expect(second.legacy.map(&:constant)).to eq([ "Workflow" ])
      expect(inventory).to have_received(:references_for).twice
    end
  end

  def with_cached_reference(constant)
    Dir.mktmpdir do |directory|
      root = Pathname.new(directory)
      root.join("lib").mkpath
      root.join("lib/fixture.rb").write("#{constant}.call\n")
      inventory = instance_double(Admin::PluginHostSurfaceInventory)
      reference = Admin::PluginHostSurfaceInventory::Reference.new(
        constant:, plugin: "fixture", path: "lib/fixture.rb", line: 1
      )
      allow(inventory).to receive(:references_for).and_return([ reference ])
      surface = instance_double(Syrus::PluginHostSurface, entries: [])
      allow(surface).to receive(:lookup).and_return(nil)
      allow(Rails).to receive(:cache).and_return(ActiveSupport::Cache::MemoryStore.new)
      yield root, inventory, surface
    end
  end
end
