require "rails_helper"

RSpec.describe Syrus::PluginRecommendations do
  let(:signals) { instance_double(Syrus::PluginSignals) }

  # Deliberately not the real plugin names. `register` replaces by name, so
  # registering "python" here would overwrite the block the Python manifest
  # installed at boot, and only a full app reload would put it back.
  after { %w[spec_alpha spec_beta].each { |name| described_class.deregister(name) } }

  def disabled_plugin(name)
    allow(Syrus::PluginRegistry).to receive(:all_plugins)
      .and_return([ instance_double(Syrus::Plugin::Manifest, name: name, enabled?: false) ])
  end

  it "recommends a disabled plugin whose signal fires, citing the evidence" do
    disabled_plugin("spec_alpha")
    described_class.register(plugin: "spec_alpha", reason: "Python repos get pytest detail", block: ->(_s) { %w[a/b c/d] })

    recommendation = described_class.call(signals: signals).sole

    expect(recommendation.plugin).to eq("spec_alpha")
    expect(recommendation.reason).to eq("Python repos get pytest detail")
    expect(recommendation.evidence_summary).to eq("a/b, c/d")
  end

  it "never recommends a plugin that is already enabled" do
    allow(Syrus::PluginRegistry).to receive(:all_plugins)
      .and_return([ instance_double(Syrus::Plugin::Manifest, name: "spec_alpha", enabled?: true) ])
    described_class.register(plugin: "spec_alpha", reason: "r", block: ->(_s) { %w[a/b] })

    expect(described_class.call(signals: signals)).to be_empty
  end

  it "stays silent when the signal returns nothing" do
    disabled_plugin("spec_alpha")
    described_class.register(plugin: "spec_alpha", reason: "r", block: ->(_s) { [] })

    expect(described_class.call(signals: signals)).to be_empty
  end

  it "treats a zero count as no signal rather than as evidence" do
    disabled_plugin("spec_alpha")
    described_class.register(plugin: "spec_alpha", reason: "r", block: ->(_s) { 0 })

    expect(described_class.call(signals: signals)).to be_empty
  end

  it "keeps a raising signal from costing the other plugins their recommendation" do
    allow(Syrus::PluginRegistry).to receive(:all_plugins).and_return([
      instance_double(Syrus::Plugin::Manifest, name: "spec_alpha", enabled?: false),
      instance_double(Syrus::Plugin::Manifest, name: "spec_beta", enabled?: false)
    ])
    described_class.register(plugin: "spec_alpha", reason: "r", block: ->(_s) { raise "boom" })
    described_class.register(plugin: "spec_beta", reason: "r", block: ->(_s) { 3 })

    expect(described_class.call(signals: signals).map(&:plugin)).to eq([ "spec_beta" ])
  end

  it "abbreviates long evidence instead of listing every repository" do
    recommendation = described_class::Recommendation.new(
      plugin: "ruby", reason: "r", evidence: %w[a/1 a/2 a/3 a/4 a/5]
    )

    expect(recommendation.evidence_summary).to eq("a/1, a/2, a/3 and 2 more")
  end

  describe "the declarations bundled plugins actually ship" do
    it "registers a suggestion for the language plugins" do
      expect(described_class.registered_plugin_names).to include("python", "go", "javascript", "ruby")
    end
  end
end
