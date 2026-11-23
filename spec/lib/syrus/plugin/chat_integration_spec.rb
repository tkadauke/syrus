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

  it "isolates a failing family contributor while retaining the healthy output" do
    bad = Class.new do
      def self.key = "bad"
      def self.display_name = "Bad"
      def self.payload_contributors(_context) = raise("broken")
    end
    good_contributor = Class.new
    good = Class.new do
      define_singleton_method(:key) { "good" }
      define_singleton_method(:display_name) { "Good" }
      define_singleton_method(:payload_contributors) { |_context| good_contributor }
    end
    stub_const("BadChatIntegration", bad)
    stub_const("GoodChatIntegration", good)
    [ [ "bad_chat", "BadChatIntegration" ], [ "good_chat", "GoodChatIntegration" ] ].each do |name, provider|
      Syrus::PluginRegistry.register(name:, version: "1", provides: {}, family_provides: [
        Syrus::Plugin::FamilyDeclaration.build(family: :chat_integration, provider:, provisional: %i[payload_contributors])
      ])
    end

    expect(described_class.contributions(:payload_contributors)).to include(good_contributor)
    expect(described_class.contributions(:payload_contributors)).not_to include(bad)
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
