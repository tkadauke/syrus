require "rails_helper"

RSpec.describe PluginRuntime::DesiredPrivilegedServices do
  let(:implementer) do
    Class.new do
      def self.privileged_service_name = "tailscale"
      def self.privileged_env = { "TS_AUTHKEY" => "tskey-abc" }
    end
  end

  def manifest(name, enabled:, provides: {})
    double("manifest", name: name, enabled?: enabled, provides: provides)
  end

  def with_manifests(*manifests)
    allow(Syrus::PluginRegistry).to receive(:all_plugins).and_return(manifests)
  end

  it "lists a first-party plugin's privileged service" do
    with_manifests(manifest("tailscale", enabled: true, provides: { described_class::POINT => implementer }))

    entry = described_class.all.sole
    expect(entry.name).to eq("tailscale")
    expect(entry.plugin).to eq("tailscale")
  end

  # The whole point of the allowlist: contributing the point is not enough by
  # itself. A plugin not named in FIRST_PARTY_PRIVILEGED_PLUGINS is ignored
  # even if it declares the point, unlike the generic plugin_runtime:service
  # point which any enabled plugin may use.
  it "ignores a contribution from a plugin outside FIRST_PARTY_PRIVILEGED_PLUGINS" do
    with_manifests(manifest("some_other_plugin", enabled: true, provides: { described_class::POINT => implementer }))

    expect(described_class.all).to be_empty
  end

  it "leaves out privileged services of disabled plugins" do
    with_manifests(manifest("tailscale", enabled: false, provides: { described_class::POINT => implementer }))

    expect(described_class.all).to be_empty
  end

  it "resolves providers named by string, as manifests declare them" do
    stub_const("RuntimeSpecTailscaleService", implementer)
    with_manifests(manifest("tailscale", enabled: true, provides: { described_class::POINT => "RuntimeSpecTailscaleService" }))

    expect(described_class.all.sole.provider).to eq(implementer)
  end

  it "skips a contribution that does not implement the privileged service contract" do
    with_manifests(manifest("tailscale", enabled: true, provides: { described_class::POINT => Class.new }))

    expect(described_class.all).to be_empty
  end
end
