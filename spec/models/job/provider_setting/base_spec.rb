require "rails_helper"

RSpec.describe Job::ProviderSetting::Base, :reset_plugin_registry do
  around do |example|
    Syrus::PluginRegistry.reset!
    example.run
    Syrus::PluginRegistry.reset!
  end

  let(:oracle_provider) do
    Class.new do
      include Syrus::Plugin::AgentProvider

      def self.provider_key = "oracle"
      def self.display_name = "Oracle"
    end
  end

  before do
    Syrus::PluginRegistry.register(:agent_provider, oracle_provider)
  end

  it "exposes default plus registered agent provider keys as settings" do
    expect(described_class.values).to eq(%w[default oracle])
  end

  it "resolves plugin-provided explicit provider settings without provider-specific core constants" do
    expect(described_class.for("oracle").resolve(nil)).to eq("oracle")
  end

  it "rejects unknown provider settings" do
    expect { described_class.for("missing") }
      .to raise_error(ArgumentError, /unknown job provider setting/)
  end
end
