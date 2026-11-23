require "rails_helper"

RSpec.describe Syrus::Plugin::ChatIntegration, :reset_plugin_registry do
  before { described_class.restore_definition! }

  it "defines every chat integration contract and legacy mapping" do
    definition = Syrus::Plugin::Family.fetch(:chat_integration)
    expect(definition.capabilities.keys).to eq(described_class::CAPABILITY_FOR_LEGACY.values)
    expect(definition.legacy_mappings.keys).to eq(described_class::CAPABILITY_FOR_LEGACY.keys)
  end

  it "adapts legacy registrations into family dispatch" do
    contributor = Class.new { include Syrus::Plugin::ChatPayloadContributor }
    Syrus::PluginRegistry.register(name: "legacy_chat", version: "1", provides: { chat_payload_contributor: contributor })

    expect(described_class.contributions(:payload_contributors)).to include(contributor)
  end

  it "expands array-valued family contributions for legacy callers" do
    first = Class.new
    second = Class.new
    provider = Class.new do
      define_singleton_method(:key) { "family_chat" }
      define_singleton_method(:display_name) { "Family chat" }
      define_singleton_method(:turn_finalizers) { |_context| [ first, second ] }
    end
    stub_const("FamilyChatIntegration", provider)
    Syrus::PluginRegistry.register(name: "family_chat", version: "1", provides: {}, family_provides: [
      Syrus::Plugin::FamilyDeclaration.build(
        family: :chat_integration, provider: "FamilyChatIntegration", provisional: %i[turn_finalizers]
      )
    ])

    expect(Syrus::PluginRegistry.providers_for(:chat_turn_finalizer)).to include(first, second)
  end

  it "isolates a failing family provider at every chat capability" do
    described_class::CAPABILITY_FOR_LEGACY.each_value do |capability|
      bad = Class.new do
        define_singleton_method(:key) { "bad_#{capability}" }
        define_singleton_method(:display_name) { "Bad #{capability}" }
        define_singleton_method(capability) { |_context| raise "broken #{capability}" }
      end
      healthy_contribution = Class.new
      good = Class.new do
        define_singleton_method(:key) { "good_#{capability}" }
        define_singleton_method(:display_name) { "Good #{capability}" }
        define_singleton_method(capability) { |_context| healthy_contribution }
      end
      bad_name = "Bad#{capability.to_s.camelize}ChatIntegration"
      good_name = "Good#{capability.to_s.camelize}ChatIntegration"
      stub_const(bad_name, bad)
      stub_const(good_name, good)
      [ [ "bad_#{capability}", bad_name ], [ "good_#{capability}", good_name ] ].each do |name, provider_name|
        Syrus::PluginRegistry.register(name:, version: "1", provides: {}, family_provides: [
          Syrus::Plugin::FamilyDeclaration.build(
            family: :chat_integration, provider: provider_name, provisional: [ capability ]
          )
        ])
      end

      expect(described_class.contributions(capability)).to include(healthy_contribution)
      expect(described_class.contributions(capability)).not_to include(bad)
    end
  end

  it "keeps empty chat-path dispatcher overhead below one millisecond per call" do
    allow(Syrus::PluginRegistry).to receive(:capability_providers).and_return([])
    20.times { described_class.contributions(:turn_orientations) }
    started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    1_000.times { described_class.contributions(:turn_orientations) }
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at

    expect(elapsed / 1_000).to be < 0.001
  end
end
