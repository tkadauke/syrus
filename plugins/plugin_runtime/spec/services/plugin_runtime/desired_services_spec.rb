require "rails_helper"

RSpec.describe PluginRuntime::DesiredServices do
  let(:implementer) do
    Class.new do
      def self.service_name = "git-mirror"
      def self.service_spec = {}
    end
  end

  def manifest(name, enabled:, provides: {})
    double("manifest", name: name, enabled?: enabled, provides: provides)
  end

  def with_manifests(*manifests)
    allow(Syrus::PluginRegistry).to receive(:all_plugins).and_return(manifests)
  end

  it "lists each enabled contributor's service with the plugin that owns it" do
    with_manifests(manifest("git_mirror", enabled: true, provides: { described_class::POINT => implementer }))

    entry = described_class.all.sole
    expect(entry.name).to eq("git-mirror")
    expect(entry.plugin).to eq("git_mirror")
  end

  # This is the whole of how disabling works: the reconciler removes what is
  # no longer in this set.
  it "leaves out services of disabled plugins" do
    with_manifests(manifest("git_mirror", enabled: false, provides: { described_class::POINT => implementer }))

    expect(described_class.all).to be_empty
  end

  it "resolves providers named by string, as manifests declare them" do
    stub_const("RuntimeSpecMirrorService", implementer)
    with_manifests(manifest("git_mirror", enabled: true, provides: { described_class::POINT => "RuntimeSpecMirrorService" }))

    expect(described_class.all.sole.provider).to eq(implementer)
  end

  it "skips a contribution that does not implement the contract" do
    with_manifests(manifest("broken", enabled: true, provides: { described_class::POINT => Class.new }))

    expect(described_class.all).to be_empty
  end

  # Two owners for one name would each replace the other's container every
  # tick. First claim wins, stably.
  it "keeps the first claim when two plugins claim one service name" do
    with_manifests(
      manifest("first", enabled: true, provides: { described_class::POINT => implementer }),
      manifest("second", enabled: true, provides: { described_class::POINT => implementer })
    )

    expect(described_class.all.map(&:plugin)).to eq([ "first" ])
  end
end
