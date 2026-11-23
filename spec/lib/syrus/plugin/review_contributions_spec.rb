require "rails_helper"

RSpec.describe Syrus::Plugin::ReviewContributions, :reset_plugin_registry do
  before { described_class.restore_definition! }

  it "keeps the external reviewer capability and adds every review contribution with a legacy mapping" do
    definition = Syrus::Plugin::Family.fetch(:review)
    expect(definition.capabilities.keys).to include(:external_reviewer, *described_class::CAPABILITY_FOR_LEGACY.values)
    expect(definition.legacy_mappings.keys).to eq(described_class::CAPABILITY_FOR_LEGACY.keys)
    described_class::CAPABILITY_FOR_LEGACY.each_value do |capability|
      expect(definition.capabilities.fetch(capability)).to have_attributes(composition: :collect, absent: [], tier: :provisional)
    end
  end

  it "adapts legacy registrations into family dispatch for every point" do
    described_class::CAPABILITY_FOR_LEGACY.each do |point, capability|
      interface = Syrus::PluginRegistry::INTERFACE_FOR.fetch(point).call
      legacy = Class.new { include interface }
      Syrus::PluginRegistry.register(name: "legacy_#{point}", version: "1", provides: { point => legacy })

      expect(described_class.contributions(capability)).to include(legacy)
    end
  end

  it "expands family declarations for legacy bridge readers" do
    gate = Class.new
    provider = Class.new do
      define_singleton_method(:key) { "family_review" }
      define_singleton_method(:display_name) { "Family review" }
      define_singleton_method(:review_gates) { |_context| gate }
    end
    stub_const("FamilyReview", provider)
    Syrus::PluginRegistry.register(name: "family_review", version: "1", provides: {}, family_provides: [
      Syrus::Plugin::FamilyDeclaration.build(family: :review, provider: "FamilyReview", provisional: %i[review_gates])
    ])

    expect(Syrus::PluginRegistry.providers_for(:review_gate)).to include(gate)
    expect(described_class.contributions(:review_gates)).to include(gate)
  end

  it "does not let a failing gate provider disturb a healthy one, matching legacy gate behavior" do
    healthy = Class.new
    bad = Class.new do
      define_singleton_method(:key) { "bad_gate" }
      define_singleton_method(:display_name) { "Bad gate" }
      define_singleton_method(:review_gates) { |_context| raise "broken gate" }
    end
    good = Class.new do
      define_singleton_method(:key) { "good_gate" }
      define_singleton_method(:display_name) { "Good gate" }
      define_singleton_method(:review_gates) { |_context| healthy }
    end
    stub_const("BadGateProvider", bad)
    stub_const("GoodGateProvider", good)
    [ [ "bad_gate", "BadGateProvider" ], [ "good_gate", "GoodGateProvider" ] ].each do |name, constant|
      Syrus::PluginRegistry.register(name:, version: "1", provides: {}, family_provides: [
        Syrus::Plugin::FamilyDeclaration.build(family: :review, provider: constant, provisional: %i[review_gates])
      ])
    end

    expect(described_class.contributions(:review_gates)).to eq([ healthy ])
  end

  it "keeps gate semantics: a gate operation failure declines to no gates, and invalid definitions still raise" do
    failing = Class.new do
      include Syrus::Plugin::ReviewGate
      def self.review_gates = raise("broken gate operation")
    end
    allow(described_class).to receive(:contributions).with(:review_gates).and_return([ failing ])

    expect(Workflows::ReviewGateRegistry.ordered(:after_agent).map(&:key)).not_to include("broken")
    expect { Workflows::ReviewGateRegistry.definitions }.not_to raise_error

    invalid = Class.new do
      include Syrus::Plugin::ReviewGate
      def self.review_gates
        [ { key: "x", step_kind: "x_review", slot: "nowhere", enabled_resolver: ->(**) { true }, loop_budget: 1,
            handler_provider: "Fake", prompt_provider: "Fake", tool_provider: [ "t" ], verdict_artifact: "x_iterations" } ]
      end
    end
    allow(described_class).to receive(:contributions).with(:review_gates).and_return([ invalid ])
    expect { Workflows::ReviewGateRegistry.definitions }.to raise_error(Workflows::ReviewGateRegistry::InvalidContribution)
  end
end
