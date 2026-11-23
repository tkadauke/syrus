require "rails_helper"

RSpec.describe Syrus::Plugin::ReviewContributions, :reset_plugin_registry do
  before { described_class.restore_definition! }

  it "keeps the external reviewer capability and adds every review contribution without a legacy bridge" do
    definition = Syrus::Plugin::Family.fetch(:review)
    expect(definition.capabilities.keys).to include(:external_reviewer, *described_class::CAPABILITIES)
    expect(definition).to be_migrated
    expect(definition.legacy_mappings).to be_empty
    described_class::CAPABILITIES.each do |capability|
      expect(definition.capabilities.fetch(capability)).to have_attributes(composition: :collect, absent: [], tier: :provisional)
    end
  end

  it "dispatches a family declaration for every contribution kind" do
    described_class::CAPABILITIES.each do |capability|
      contribution = Class.new
      register_family_review("family_#{capability}", capability, contribution)

      expect(described_class.contributions(capability)).to include(contribution)
    end
  end

  def register_family_review(name, capability, contribution)
    provider = Class.new do
      define_singleton_method(:key) { name }
      define_singleton_method(:display_name) { name }
      define_singleton_method(capability) { |_context| contribution }
    end
    constant = "#{name.camelize}Provider"
    stub_const(constant, provider)
    Syrus::PluginRegistry.register(default_enabled: true, disableable: true, experimental: false, requires_syrus: nil, name:, version: "1", provides: {}, family_provides: [
      Syrus::Plugin::FamilyDeclaration.build(family: :review, provider: constant, provisional: [ capability ])
    ])
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
      Syrus::PluginRegistry.register(default_enabled: true, disableable: true, experimental: false, requires_syrus: nil, name:, version: "1", provides: {}, family_provides: [
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
