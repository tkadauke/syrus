require "rails_helper"
require "tmpdir"

RSpec.describe Syrus::PluginHostSurface::Scanner do
  def scan(source, entries: {})
    Dir.mktmpdir do |directory|
      root = Pathname.new(directory)
      root.join("lib").mkpath
      root.join("lib/fixture.rb").write(source)
      surface = instance_double(Syrus::PluginHostSurface)
      allow(surface).to receive(:lookup) { |name| entries[name] }
      return described_class.new(root, surface:).call
    end
  end

  def entry(name, tier:, since: nil)
    Syrus::PluginHostSurface::Entry.new(name:, tier:, since:, contract: nil, members: {})
  end

  it "classifies public, legacy, and unlisted core references with locations" do
    entries = {
      "AgentInvocation" => entry("AgentInvocation", tier: "public", since: "0.1.16"),
      "AgentRole" => entry("AgentRole", tier: "legacy")
    }
    result = scan("AgentInvocation.call\nAgentRole.call\nWorkflow.call\n", entries:)

    expect(result.public.first).to have_attributes(constant: "AgentInvocation", path: "lib/fixture.rb", line: 1)
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
    entries = {
      "AgentInvocation" => entry("AgentInvocation", tier: "public", since: "0.1.16"),
      "Workflow" => entry("Workflow", tier: "public", since: "0.4.2")
    }
    result = scan("AgentInvocation.call\nWorkflow.call\n", entries:)
    expect(result.minimum_syrus_version).to eq("0.4.2")
  end

  it "caches scans by the Ruby content hash" do
    Dir.mktmpdir do |directory|
      root = Pathname.new(directory)
      root.join("lib").mkpath
      root.join("lib/fixture.rb").write("Workflow.call\n")
      inventory = instance_double(Admin::PluginHostSurfaceInventory)
      allow(inventory).to receive(:references_for).and_return([])
      surface = instance_double(Syrus::PluginHostSurface)
      store = ActiveSupport::Cache::MemoryStore.new
      allow(Rails).to receive(:cache).and_return(store)

      2.times { described_class.cached(root, surface:, inventory:) }
      expect(inventory).to have_received(:references_for).once
    end
  end
end
